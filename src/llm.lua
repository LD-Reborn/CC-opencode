-- OpenAI-compatible chat completions client.
--
-- Mirrors opencode's OpenAI Chat protocol: `/chat/completions` on the trimmed
-- base URL, a bearer credential, and a body that omits empty fields. ComputerCraft
-- buffers whole responses, so a `stream: true` request is read in full and the SSE
-- frames are reassembled here.

local json = require("json")
local http = require("http")
local provider = require("provider")

local M = {}

M.FINISH = {
  stop = "stop",
  length = "length",
  content_filter = "content-filter",
  function_call = "tool-calls",
  tool_calls = "tool-calls",
}

local function headerValue(model, key, fallback)
  local headers = model.headers or {}
  local direct = headers[key]
  if direct then
    return direct
  end
  for name, value in pairs(headers) do
    if name:lower() == key:lower() then
      return value
    end
  end
  return fallback
end

--- Drop keys whose value is nil, json.null, or an empty array, as the protocol requires.
local function compact(table_)
  local out = {}
  for key, value in pairs(table_) do
    if value ~= nil and value ~= json.null then
      if type(value) ~= "table" or #value > 0 then
        out[key] = value
      end
    end
  end
  return out
end

--- Build the request body. Empty fields are omitted so we never send `tools: []`.
function M.body(request)
  local model = request.model
  local options = model.options or {}
  -- Per-request generation settings win over the provider defaults.
  local generation = request.generation or {}

  local body = compact({
    model = model.id,
    messages = request.messages or {},
    tools = request.tools and #request.tools > 0 and request.tools or nil,
    tool_choice = request.tool_choice,
    stream = request.stream and true or nil,
    max_tokens = generation.maxTokens or options.maxTokens,
    temperature = generation.temperature or options.temperature,
    top_p = generation.topP or options.topP,
    frequency_penalty = generation.frequencyPenalty,
    presence_penalty = generation.presencePenalty,
    seed = generation.seed,
    stop = generation.stop,
    reasoning_effort = options.reasoningEffort,
    store = options.store,
    prompt_cache_key = options.promptCacheKey,
  })

  if request.stream then
    body.stream_options = { include_usage = true }
  end
  return body
end

local function requestHeaders(model)
  local headers = {
    ["content-type"] = "application/json",
    ["accept"] = "text/event-stream",
  }
  if model.apiKey and model.apiKey ~= "" then
    headers["authorization"] = "Bearer " .. model.apiKey
  end
  for key, value in pairs(model.headers or {}) do
    headers[key:lower()] = value
  end
  headers["content-type"] = headerValue(model, "content-type", headers["content-type"])
  return headers
end

--- Collapse streamed deltas into the same shape the non-streamed path returns.
local function fromStream(response, onDelta)
  onDelta = onDelta or function() end
  local content, reasoning = {}, {}
  local toolCalls = {}
  local finish, usage

  for _, frame in ipairs(http.parseSse(response.body)) do
    local event = json.decode(frame)
    if type(event) == "table" then
      if event.usage and type(event.usage) == "table" then
        usage = event.usage
      end
      local choice = (event.choices or {})[1]
      if type(choice) == "table" then
        if type(choice.finish_reason) == "string" then
          finish = choice.finish_reason
        end
        local delta = choice.delta
        if type(delta) == "table" then
          if type(delta.reasoning_content) == "string" then
            reasoning[#reasoning + 1] = delta.reasoning_content
          end
          if type(delta.content) == "string" then
            content[#content + 1] = delta.content
            onDelta(delta.content)
          end
          for _, call in ipairs(delta.tool_calls or {}) do
            local index = call.index or (#toolCalls)
            local entry = toolCalls[index + 1] or { name = "", arguments = "" }
            if type(call.id) == "string" and call.id ~= "" then
              entry.id = call.id
            end
            if type(call["function"]) == "table" then
              if type(call["function"].name) == "string" and call["function"].name ~= "" then
                entry.name = entry.name .. call["function"].name
              end
              if type(call["function"].arguments) == "string" then
                entry.arguments = entry.arguments .. call["function"].arguments
              end
            end
            toolCalls[index + 1] = entry
          end
        end
      end
    end
  end

  return { content = table.concat(content), reasoning = table.concat(reasoning), toolCalls = toolCalls, finish = finish, usage = usage }
end

--- Normalise a non-streamed choice.
local function fromChoice(choice, usage)
  local message = choice.message
  local toolCalls = {}
  for index, call in ipairs(message.tool_calls or {}) do
    toolCalls[index] = {
      id = call.id,
      name = (call["function"] or {}).name,
      arguments = (call["function"] or {}).arguments or "",
    }
  end
  return {
    content = type(message.content) == "string" and message.content or "",
    reasoning = type(message.reasoning_content) == "string" and message.reasoning_content or "",
    toolCalls = toolCalls,
    finish = choice.finish_reason,
    usage = usage,
  }
end

--- Map the provider's finish_reason, mirroring opencode's translation table.
local function mapFinish(reason, hasToolCalls)
  local mapped = M.FINISH[reason or ""]
  if not mapped then
    return "unknown"
  end
  -- Many OpenAI-compatible servers report "stop" even when they emitted tool calls.
  if mapped == "stop" and hasToolCalls then
    return "tool-calls"
  end
  return mapped
end

--- Translate provider usage into the project's token shape.
local function mapUsage(usage)
  if type(usage) ~= "table" then
    return nil
  end
  local input = usage.prompt_tokens or 0
  local output = usage.completion_tokens or 0
  local cached = (usage.prompt_tokens_details or {}).cached_tokens
  local reasoning = (usage.completion_tokens_details or {}).reasoning_tokens
  return {
    input = input,
    output = output,
    reasoning = reasoning or 0,
    cacheRead = cached or 0,
    cacheWrite = 0,
    total = usage.total_tokens or (input + output),
  }
end

--- Run one chat completion.
--
-- `request.messages` is a list of already-lowered OpenAI wire messages, `request.tools`
-- a list of `{ type = "function", function = { name, description, parameters } }`.
-- `options.onDelta` streams text when the request asked for `stream`.
--
-- Returns a normalized result table, or `nil, message` on failure.
function M.chat(request, options)
  options = options or {}
  local model = request.model
  local stream = request.stream and true or false

  local response, err = http.postJson(provider.url(model, "/chat/completions"), M.body(request), {
    headers = requestHeaders(model),
    timeout = options.timeout or (model.options or {}).timeout or http.DEFAULT_TIMEOUT,
    maxBytes = options.maxBytes or 8 * 1024 * 1024,
    -- A streamed body is an event stream, not a JSON document, so it is left
    -- undecoded here and split into frames by `fromStream`.
    decode = not stream,
  })
  if not response then
    return nil, err
  end

  local result
  if stream then
    result = fromStream(response, options.onDelta)
  else
    local choice = (response.data.choices or {})[1]
    if type(choice) ~= "table" or type(choice.message) ~= "table" then
      return nil, "the response contained no choices"
    end
    result = fromChoice(choice, response.data.usage)
    if options.onDelta and #result.content > 0 then
      options.onDelta(result.content)
    end
  end

  result.finish = mapFinish(result.finish, #result.toolCalls > 0)
  result.usage = mapUsage(result.usage)
  result.raw = response.data
  return result
end

--- Decode the JSON arguments string a model attached to a tool call.
function M.parseArguments(raw)
  if raw == nil or raw == "" then
    return {}
  end
  if type(raw) == "table" then
    return json.dropNulls(raw)
  end
  local decoded, err = json.decode(raw)
  if type(decoded) ~= "table" then
    return nil, err or "arguments were not a JSON object"
  end
  return json.dropNulls(decoded)
end

return M
