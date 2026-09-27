-- The agent loop.
--
-- One iteration is one provider turn: lower the session into OpenAI wire
-- messages, call the model, run whatever tools it asked for, append the results,
-- and repeat until the model stops calling tools. The loop mirrors opencode's
-- `runLoop`, including the max-steps guard and the doom-loop check that stops a
-- model from repeating the same failing call forever.

local json = require("json")
local util = require("util")
local llm = require("llm")
local prompt = require("prompt")
local session = require("session")
local registry = require("tool/registry")
local permission = require("permission")
local config = require("config")
local provider = require("provider")

local M = {}

local DOOM_LOOP_THRESHOLD = 3
local DEFAULT_STEPS = 25

M.COMPACT_MAX_TOKENS = 1024

--- Resolve the step budget for an agent from config, then the built-in defaults.
local function maxStepsFor(configValue, agent)
  local configured = (configValue.agent or {})[agent]
  if configured and configured.steps then
    return configured.steps
  end
  local fallback = (config.DEFAULTS.agent or {})[agent]
  return fallback and fallback.steps or DEFAULT_STEPS
end

--- Concatenate the text parts of a message.
local function textOf(message)
  local parts = {}
  for _, part in ipairs(message.parts or {}) do
    if part.type == "text" then
      parts[#parts + 1] = part.text
    end
  end
  return table.concat(parts)
end

--- Lower one assistant message and its tool results into wire messages.
local function lowerAssistant(message, out)
  local text = textOf(message)
  local reasoning = ""
  local toolParts = {}
  for _, part in ipairs(message.parts or {}) do
    if part.type == "reasoning" then
      reasoning = reasoning .. part.text
    elseif part.type == "tool" then
      toolParts[#toolParts + 1] = part
    end
  end

  if text == "" and reasoning == "" and #toolParts == 0 then
    return
  end

  local wire = { role = "assistant", content = text ~= "" and text or json.null }
  if reasoning ~= "" then
    wire.reasoning_content = reasoning
  end
  if #toolParts > 0 then
    wire.tool_calls = {}
    for index, part in ipairs(toolParts) do
      wire.tool_calls[index] = {
        id = part.callID,
        type = "function",
        ["function"] = { name = part.tool, arguments = json.encode(part.state.input or {}) },
      }
    end
  end
  out[#out + 1] = wire

  for _, part in ipairs(toolParts) do
    local content
    if part.state.status == "completed" then
      content = part.state.output
    elseif part.state.status == "error" then
      content = "Error: " .. (part.state.error or "the tool failed")
    else
      content = "Error: the tool was interrupted before it finished"
    end
    out[#out + 1] = { role = "tool", tool_call_id = part.callID, content = content }
  end
end

--- Build the full OpenAI wire message list for a request.
function M.lower(current, system, trailer)
  local messages = {}
  if system and system ~= "" then
    messages[1] = { role = "system", content = system }
  end
  for _, message in ipairs(current.messages) do
    if message.role == "user" then
      messages[#messages + 1] = { role = "user", content = textOf(message) }
    else
      lowerAssistant(message, messages)
    end
  end
  if trailer then
    messages[#messages + 1] = { role = "assistant", content = trailer }
  end
  return messages
end

--- True when the newest assistant turn left work for the model to pick up.
function M.hasPendingWork(current)
  return not session.isTurnComplete(current)
end

--- Raise unless the operator wants the repeated call to continue.
local function doomLoopCheck(ctx, part, history)
  history[#history + 1] = part.tool .. ":" .. json.encode(part.state.input or {})
  if #history < DOOM_LOOP_THRESHOLD then
    return
  end
  for index = #history - DOOM_LOOP_THRESHOLD + 2, #history - 1 do
    if history[index] ~= history[#history] then
      return
    end
  end

  local decision = permission.ask({
    permission = "doom_loop",
    patterns = { part.tool },
    always = { part.tool },
    ruleset = ctx.permission,
    session = ctx.session,
    monitor = ctx.monitor,
    title = string.format(
      "The same %s call has run %d times in a row with identical arguments. Continue?",
      part.tool,
      DOOM_LOOP_THRESHOLD
    ),
  })
  if decision == permission.ALLOW then
    return
  end
  error(
    "The same " .. part.tool .. " call was repeated with identical arguments, so it was stopped. "
      .. "Change the arguments or take a different approach.",
    0
  )
end

--- Run every tool the model asked for in this turn, appending results.
local function runTools(ctx, message, calls, history)
  for _, call in ipairs(calls) do
    if ctx.aborted() then
      return
    end

    local part = session.addToolPart(message, call)

    local arguments, parseError = llm.parseArguments(call.arguments)
    if parseError then
      session.failTool(part, "The " .. call.name .. " tool was called with invalid arguments: " .. parseError
        .. ". Rewrite the input so it matches the tool's schema.")
      ctx.on({ type = "tool_start", part = part })
      ctx.on({ type = "tool_end", part = part })
    else
      -- The start event goes out once the arguments are on the part, so a
      -- listener can say what the model is about to do rather than just naming
      -- the tool.
      session.startTool(part, arguments)
      ctx.on({ type = "tool_start", part = part })
      local outcome = registry.execute(call.name, arguments, ctx)
      if outcome.status == "completed" then
        session.completeTool(part, outcome)
      else
        session.failTool(part, outcome.error)
        if outcome.status == "denied" then
          ctx.blocked = true
        end
      end

      if part.state.status == "completed" then
        local ok, err = pcall(doomLoopCheck, ctx, part, history)
        if not ok then
          session.failTool(part, tostring(err))
        end
      end

      ctx.on({ type = "tool_end", part = part })
    end
  end
end

--- Run the agent loop until the model stops calling tools.
--
-- `ctx` supplies: session, config, model, agent, root, cwd, permission, enabled
-- (tool toggles), monitor, on (event sink), and aborted (a predicate).
function M.run(ctx, options)
  options = options or {}
  local current = ctx.session
  local maxSteps = maxStepsFor(ctx.config, ctx.agent)
  local step = 0
  local history = {}

  while true do
    if ctx.aborted() then
      ctx.on({ type = "aborted" })
      return nil, "aborted"
    end
    if not M.hasPendingWork(current) then
      break
    end

    step = step + 1
    if step > maxSteps then
      return session.latestAssistantMessage(current),
        string.format("reached the maximum of %d steps for agent '%s'", maxSteps, ctx.agent)
    end

    local isLastStep = step == maxSteps
    ctx.on({ type = "step", step = step, max = maxSteps })

    -- Once per step, before the request is built, so the request that would have
    -- been too large never goes out.
    local summary = M.compact(ctx)
    if summary then
      ctx.on({ type = "compacted", text = summary })
    end

    local message = session.addAssistant(current, ctx.model)
    local system = prompt.system(ctx.config, ctx.agent, ctx.model, ctx.enabled)
    local messages = M.lower(current, system, isLastStep and prompt.MAX_STEPS or nil)

    local tools = {}
    for _, tool in ipairs(registry.list(ctx.enabled)) do
      tools[#tools + 1] = registry.toWire(tool)
    end

    local textPart
    local onDelta = nil
    if ctx.stream then
      onDelta = function(delta)
        if not textPart then
          textPart = session.addText(message, "")
        end
        textPart.text = textPart.text .. delta
        ctx.on({ type = "text", delta = delta })
      end
    end

    local result, err = llm.chat({
      model = ctx.model,
      messages = messages,
      tools = #tools > 0 and tools or nil,
      tool_choice = isLastStep and "none" or nil,
      stream = ctx.stream and true or false,
    }, { timeout = ctx.timeout, onDelta = onDelta })

    if not result then
      message.parts[#message.parts + 1] = { type = "step-finish", reason = "error" }
      message.time.completed = os.time()
      message.error = err
      ctx.on({ type = "error", message = err })
      return message, err
    end

    if not textPart and result.content ~= "" then
      session.addText(message, result.content)
      ctx.on({ type = "text", delta = result.content })
    end
    if result.reasoning ~= "" then
      session.addReasoning(message, result.reasoning)
      ctx.on({ type = "reasoning", text = result.reasoning })
    end

    runTools(ctx, message, result.toolCalls, history)
    session.finishStep(message, result.finish, result.usage)
    ctx.on({ type = "step_end", message = message })

    if options.onStepEnd then
      options.onStepEnd(message)
    end
    if ctx.aborted() then
      ctx.on({ type = "aborted" })
      return message, "aborted"
    end
    if ctx.blocked then
      return message
    end
    if result.finish ~= "tool-calls" then
      break
    end
  end

  return session.latestAssistantMessage(current)
end

--- Ask the small model for a session title. Failures are silent.
function M.title(ctx, text)
  if not ctx.smallModel or not text or #text < 4 then
    return nil
  end
  local result = llm.chat({
    model = ctx.smallModel,
    messages = {
      { role = "system", content = prompt.TITLE },
      { role = "user", content = text },
    },
    generation = { maxTokens = 24 },
  }, { timeout = 20 })
  if not result or not result.content then
    return nil
  end
  return util.trim(result.content:gsub("[\"'`]", ""))
end

-- Compaction
--
-- Every turn resends the whole conversation, so a long session eventually asks
-- for more than a ComputerCraft computer can hold in one request. Compaction
-- replaces the older messages with a summary written by the small model, which
-- is what keeps a session usable past a few dozen turns.

--- Roughly how many bytes the conversation occupies.
--
-- An estimate is enough to decide when to compact, and this is cheap: it adds up
-- strings that are already in memory. Encoding every message to JSON on every
-- step would cost more than the compaction it is trying to avoid.
local function conversationBytes(current)
  local total = 0
  for _, message in ipairs(current.messages or {}) do
    -- Room for the envelope: role, ids, timestamps, usage.
    total = total + 96
    for _, part in ipairs(message.parts or {}) do
      if type(part.text) == "string" then
        total = total + #part.text
      elseif part.type == "tool" then
        local state = part.state or {}
        total = total + 96
        for _, key in ipairs({ "output", "error" }) do
          if type(state[key]) == "string" then
            total = total + #state[key]
          end
        end
      end
    end
  end
  return total
end

--- The first message of the conversation that must be kept.
--
-- Compaction drops messages from the front, and the newest user and assistant
-- messages are what tell the loop whether the turn is finished
-- (`session.isTurnComplete`), so the cut has to be in front of both.
local function keepFromIndex(current)
  local latestUser, latestAssistant
  for index = #current.messages, 1, -1 do
    if not latestUser and current.messages[index].role == "user" then
      latestUser = index
    elseif not latestAssistant and current.messages[index].role == "assistant" then
      latestAssistant = index
    end
  end
  local first = latestUser or latestAssistant
  if latestUser and latestAssistant then
    first = math.min(latestUser, latestAssistant)
  end
  return first
end

--- Replace the older part of the conversation with a one-message summary.
--
-- Returns the summary, or nil when there was nothing to do: the conversation
-- still fits, compaction is switched off, there is no small model to write the
-- summary, or the summary request failed. A failure leaves the conversation
-- exactly as it was, so the next request fails with the provider's own size
-- error rather than a silently truncated history.
function M.compact(ctx)
  local settings = ctx.config.compaction or {}
  if settings.auto == false or not ctx.smallModel then
    return nil
  end
  local limit = (ctx.model and ctx.model.limit and ctx.model.limit.context)
    or provider.DEFAULT_LIMIT.context
  local reserved = settings.reserved or config.DEFAULTS.compaction.reserved
  if conversationBytes(ctx.session) + reserved < limit then
    return nil
  end

  local current = ctx.session
  local cut = keepFromIndex(current)
  if not cut or cut < 2 then
    -- Nothing older than the current turn: there is no history to summarise, and
    -- dropping the turn itself would lose the question.
    return nil
  end

  local older = {}
  for index = 1, cut - 1 do
    older[#older + 1] = current.messages[index]
  end
  local transcript = json.encode(M.lower({ messages = older }, nil, nil), "  ")

  local result, err = llm.chat({
    model = ctx.smallModel,
    messages = {
      { role = "system", content = prompt.COMPACTION },
      { role = "user", content = transcript },
    },
    generation = { maxTokens = M.COMPACT_MAX_TOKENS },
  }, { timeout = 30 })
  if not result or not result.content or util.trim(result.content) == "" then
    ctx.on({ type = "error", message = "could not compact the conversation: " .. tostring(err or "the model said nothing") })
    return nil
  end

  for index = #older, 1, -1 do
    table.remove(current.messages, index)
  end
  table.insert(current.messages, 1, {
    id = util.id("msg"),
    role = "user",
    time = { created = os.time() },
    summary = true,
    parts = { { type = "text", text = "Summary of the conversation so far:\n\n" .. util.trim(result.content) } },
  })
  return result.content
end

return M
