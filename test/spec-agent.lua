-- The agent loop, end to end against the mocked provider.
--
-- The responses are queued in the order the loop will consume them, so each test
-- reads as the turn-by-turn story it is testing: a tool call, the tool result fed
-- back, then the final answer.

return function(t, mock)
  local agent = require("agent")
  local session = require("session")
  local registry = require("tool/registry")
  local permission = require("permission")
  local json = require("json")
  local env = require("environment")

  t.suite("agent")

  registry.load()

  local model = {
    id = "gpt-4o",
    providerID = "openai",
    name = "GPT-4o",
    base = "https://api.openai.com/v1",
    apiKey = "sk-test",
    options = {},
    limit = { context = 128000, output = 4096 },
  }

  --- A provider turn that calls tools.
  local function toolTurn(calls, finish)
    return {
      status = 200,
      body = json.encode({
        choices = { { message = { content = "", tool_calls = calls }, finish_reason = finish or "tool_calls" } },
        usage = { prompt_tokens = 10, completion_tokens = 5 },
      }),
    }
  end

  --- A provider turn that just answers.
  local function textTurn(content, finish)
    return {
      status = 200,
      body = json.encode({
        choices = { { message = { content = content }, finish_reason = finish or "stop" } },
        usage = { prompt_tokens = 10, completion_tokens = 5 },
      }),
    }
  end

  local function call(name, arguments)
    return { id = "call_" .. name, ["function"] = { name = name, arguments = arguments } }
  end

  local function context(options)
    local ctx = mock.context(options)
    ctx.model = options and options.model or model
    return ctx
  end

  local function sentMessages(index)
    return json.decode(mock.requests[(index or #mock.requests)].body).messages
  end

  local function sentBody(index)
    return json.decode(mock.requests[(index or #mock.requests)].body)
  end

  -- A turn that needs no tools ends after one request.

  mock.setup()
  env.write(mock.root .. "/hello.txt", "hi")
  mock.respond(textTurn("Hello there."))
  local current = session.new()
  session.addUser(current, "say hi")
  local events = {}
  local answer = agent.run(context({ session = current, on = function(event) events[#events + 1] = event.type end }))

  t.eq(session.messageText(answer), "Hello there.", "the assistant text is stored on the message")
  t.eq(#mock.requests, 1, "a turn with no tool calls makes exactly one request")
  t.eq(#current.messages, 2, "the session holds the user message and the assistant reply")
  t.eq(events[1], "step", "a step event comes first")
  t.eq(events[2], "text", "the answer is reported as a text event")
  t.eq(events[3], "step_end", "the step is closed by a step_end event")

  local messages = sentMessages()
  t.eq(messages[1].role, "system", "a system message leads the conversation")
  t.contains(messages[1].content, "opencode", "the system prompt identifies the agent")
  t.contains(messages[1].content, "openai/gpt-4o", "the environment block names the exact model")
  t.contains(messages[1].content, "Available tools: bash, read", "the system prompt lists the tools")
  t.eq(messages[2].role, "user", "the user message follows")
  t.eq(messages[2].content, "say hi", "the user text is sent verbatim")
  t.ok(#sentBody().tools > 0, "the tool schemas are sent with the request")
  t.eq(sentBody().tools[1]["function"].name, "bash", "the first tool schema is bash")

  -- A tool call runs the tool, feeds the result back, and then the model answers.

  mock.setup()
  env.write(mock.root .. "/hello.txt", "hi")
  mock.respond(toolTurn({ call("read", '{"filePath":"/' .. mock.root:gsub("^/", "") .. '/hello.txt"}') }))
  mock.respond(textTurn("The file says hi."))
  current = session.new()
  session.addUser(current, "what does hello.txt say")
  answer = agent.run(context({ session = current }))

  t.eq(#mock.requests, 2, "a tool call costs one extra request")
  t.eq(session.messageText(answer), "The file says hi.", "the final answer is the second turn's text")

  local toolPart = current.messages[2].parts[#current.messages[2].parts - 1]
  t.eq(toolPart.type, "tool", "the assistant message records the tool call")
  t.eq(toolPart.tool, "read", "the tool is named")
  t.eq(toolPart.state.status, "completed", "the tool completed")
  t.contains(toolPart.state.output, "1: hi", "the tool output is stored on the part")

  local second = sentMessages(2)
  t.eq(second[3].role, "assistant", "the assistant turn is replayed to the model")
  t.eq(second[3].tool_calls[1]["function"].name, "read", "the tool call is replayed with its arguments")
  t.eq(json.decode(second[3].tool_calls[1]["function"].arguments).filePath, mock.root .. "/hello.txt", "the arguments round-trip through JSON")
  t.eq(second[4].role, "tool", "the tool result comes back as a tool message")
  t.eq(second[4].tool_call_id, "call_read", "the tool message references the call id")
  t.contains(second[4].content, "1: hi", "the tool result carries the output the tool produced")

  -- A pure tool call has a null content on the wire, never the string "null".

  t.eq(#json.encode(json.null) > 0, true, "null encodes to something")
  mock.setup()
  env.write(mock.root .. "/hello.txt", "hi")
  mock.respond(toolTurn({ call("read", '{"filePath":"hello.txt"}') }))
  mock.respond(textTurn("done"))
  current = session.new()
  session.addUser(current, "read it")
  agent.run(context({ session = current }))
  t.contains(mock.requests[2].body, '"content":null', "a tool-only assistant turn sends a JSON null content")

  -- Several tool calls in one turn all run, in order, and all come back.

  mock.setup()
  env.write(mock.root .. "/a.txt", "A")
  env.write(mock.root .. "/b.txt", "B")
  mock.respond(toolTurn({ call("read", '{"filePath":"a.txt"}'), call("read", '{"filePath":"b.txt"}') }))
  mock.respond(textTurn("both read"))
  current = session.new()
  session.addUser(current, "read both")
  agent.run(context({ session = current }))
  local toolParts = {}
  for _, part in ipairs(current.messages[2].parts) do
    if part.type == "tool" then
      toolParts[#toolParts + 1] = part
    end
  end
  t.eq(#toolParts, 2, "both tool calls are recorded")
  t.contains(toolParts[1].state.output, "1: A", "the first call read its file")
  t.contains(toolParts[2].state.output, "1: B", "the second call read its file")
  local results = 0
  for _, message in ipairs(sentMessages(2)) do
    if message.role == "tool" then
      results = results + 1
    end
  end
  t.eq(results, 2, "both results are sent back")

  -- A failing tool becomes an error the model can read and recover from.

  mock.setup()
  mock.respond(toolTurn({ call("read", '{"filePath":"missing.txt"}') }))
  mock.respond(textTurn("That file does not exist."))
  current = session.new()
  session.addUser(current, "read a missing file")
  answer = agent.run(context({ session = current }))
  local failure = current.messages[2].parts[2]
  t.eq(failure.state.status, "error", "a failed tool is recorded as an error")
  t.contains(failure.state.output == nil and failure.state.error or failure.state.error, "File not found", "the error text is kept")
  t.contains(sentMessages(2)[4].content, "Error: ", "the model is told the tool failed")
  t.eq(session.messageText(answer), "That file does not exist.", "the model can still answer after a tool failure")

  -- Malformed arguments never reach the tool.

  mock.setup()
  mock.respond(toolTurn({ call("read", "{not json") }))
  mock.respond(textTurn("sorry"))
  current = session.new()
  session.addUser(current, "read something")
  agent.run(context({ session = current }))
  local bad = current.messages[2].parts[2]
  t.eq(bad.state.status, "error", "malformed arguments fail the tool call")
  t.contains(bad.state.error, "invalid arguments", "the error explains the arguments were the problem")
  t.contains(bad.state.error, "schema", "the error points at the schema")

  -- An unknown tool is reported, not crashed on.

  mock.setup()
  mock.respond(toolTurn({ call("teleport", "{}") }))
  mock.respond(textTurn("never mind"))
  current = session.new()
  session.addUser(current, "teleport me")
  agent.run(context({ session = current }))
  t.contains(current.messages[2].parts[2].state.error, "Unknown tool 'teleport'", "an unknown tool is a tool error")

  -- The step budget stops a model that keeps asking for tools, and the last
  -- request is the one that forbids tool calls so it summarises instead.

  mock.setup()
  env.write(mock.root .. "/loop.txt", "x")
  for _ = 1, 4 do
    mock.respond(toolTurn({ call("read", '{"filePath":"loop.txt"}') }))
  end
  current = session.new()
  session.addUser(current, "loop forever")
  local capped, capMessage = agent.run(context({ session = current, config = require("config").load(mock.root, { agent = { build = { steps = 3 } } }) }))
  t.contains(capMessage, "maximum of 3 steps", "the step budget is reported")
  t.eq(#current.messages, 4, "the session kept every turn it did take")
  t.eq(sentBody(3).tool_choice, "none", "the final step forbids tool calls")
  t.contains(sentMessages(3)[#sentMessages(3)].content, "MAXIMUM STEPS REACHED", "the final step carries the warning trailer")
  t.ok(capped ~= nil, "the last message is returned even when the budget runs out")

  -- A model that says "stop" while asking for tools is still treated as done only
  -- once the calls have been answered, so the loop continues.

  mock.setup()
  env.write(mock.root .. "/once.txt", "x")
  mock.respond(toolTurn({ call("read", '{"filePath":"once.txt"}') }, "stop"))
  mock.respond(textTurn("all done"))
  current = session.new()
  session.addUser(current, "read once")
  answer = agent.run(context({ session = current }))
  t.eq(#mock.requests, 2, "a 'stop' finish that emitted tool calls still gets its results answered")
  t.eq(answer.finish, "stop", "the final message records the real finish reason")

  -- A doom loop: the same call three times in a row with identical arguments is
  -- stopped, so the model has to change its approach.

  local function toolPartsOf(current)
    local out = {}
    for _, message in ipairs(current.messages) do
      for _, part in ipairs(message.parts) do
        if part.type == "tool" then
          out[#out + 1] = part
        end
      end
    end
    return out
  end

  mock.setup()
  env.write(mock.root .. "/doom.txt", "x")
  mock.respond(toolTurn({ call("read", '{"filePath":"doom.txt"}') }))
  mock.respond(toolTurn({ call("read", '{"filePath":"doom.txt"}') }))
  mock.respond(toolTurn({ call("read", '{"filePath":"doom.txt"}') }))
  mock.respond(textTurn("I will stop repeating myself."))
  current = session.new()
  session.addUser(current, "read doom")
  agent.run(context({
    session = current,
    permission = {
      { permission = "*", pattern = "*", action = "allow" },
      { permission = "doom_loop", pattern = "*", action = "deny" },
    },
  }))
  local repeated = toolPartsOf(current)
  t.eq(#repeated, 3, "all three repeated calls are recorded")
  t.eq(repeated[1].state.status, "completed", "the first repeat is allowed")
  t.eq(repeated[2].state.status, "completed", "the second repeat is still within the threshold")
  t.eq(repeated[3].state.status, "error", "the third identical call is stopped")
  t.contains(repeated[3].state.error, "repeated with identical arguments", "the stop explains itself")
  t.contains(repeated[3].state.error, "different approach", "the stop tells the model what to do")

  -- Two identical calls then a different one is not a doom loop.

  mock.setup()
  env.write(mock.root .. "/a.txt", "A")
  env.write(mock.root .. "/b.txt", "B")
  mock.respond(toolTurn({ call("read", '{"filePath":"a.txt"}') }))
  mock.respond(toolTurn({ call("read", '{"filePath":"a.txt"}') }))
  mock.respond(toolTurn({ call("read", '{"filePath":"b.txt"}') }))
  mock.respond(textTurn("ok"))
  current = session.new()
  session.addUser(current, "read a then b")
  agent.run(context({ session = current }))
  t.eq(current.messages[2].parts[2].state.status, "completed", "two repeats in a row are within the threshold")
  t.eq(current.messages[3].parts[2].state.status, "completed", "a different call resets the history")

  -- A denied permission stops the run rather than letting the model retry.

  mock.setup()
  env.write(mock.root .. "/secret.txt", "x")
  mock.respond(toolTurn({ call("read", '{"filePath":"secret.txt"}') }))
  mock.respond(textTurn("understood"))
  current = session.new()
  session.addUser(current, "read the secret")
  local denied = agent.run(context({
    session = current,
    permission = { { permission = "read", pattern = "*", action = "deny" } },
  }))
  t.contains(current.messages[2].parts[2].state.error, "Permission denied", "the denial is reported to the model")
  t.eq(#mock.requests, 1, "a denial ends the run instead of looping back to the model")
  t.ok(denied ~= nil, "the message is still returned")

  -- Ruleset evaluation: the last matching rule wins, and no match means ask.

  local ruleset = {
    { permission = "read", pattern = "*.txt", action = "allow" },
    { permission = "read", pattern = "*.env", action = "deny" },
  }
  t.eq(permission.evaluate("read", "/x/a.txt", ruleset).action, "allow", "a matching allow rule is used")
  t.eq(permission.evaluate("read", "/x/a.env", ruleset).action, "deny", "a later matching rule overrides an earlier one")
  t.eq(permission.evaluate("write", "/x/a.txt", ruleset).action, "ask", "an unmatched permission falls back to ask")
  t.eq(permission.evaluateAll("read", { "/x/a.txt", "/x/b.md" }, ruleset), "ask", "one ask among many is enough to ask")
  t.eq(permission.evaluateAll("read", { "/x/a.txt" }, ruleset), "allow", "all allowed means allowed")
  t.eq(permission.evaluateAll("read", { "/x/a.env", "/x/b.md" }, ruleset), "deny", "one deny beats any number of asks")
  t.eq(permission.evaluate("read", "anything", { { "read", "*", "allow" } }).action, "allow", "a positional rule entry is understood")
  t.eq(permission.evaluate("read", "anything", {}).action, "ask", "an empty ruleset asks")

  -- Approving "always" appends to the session so later calls are silent.

  --- The monitor to ask on, with the operator's reply waiting on the terminal.
  --
  -- CC's `read` is a global reading from the terminal, not a method on the screen
  -- being drawn on, so the reply is queued on a screen the mock treats as the
  -- terminal. Building a bare table with a `readLine` on it would be the old
  -- fiction again, and it would pass whether or not the program asked correctly.
  local function answering(reply)
    return mock.screen({ reply })
  end

  mock.setup()
  env.write(mock.root .. "/quiet.txt", "x")
  current = session.new()
  _G.term = {}
  local askSession = session.new()
  local first = registry.execute("read", { filePath = mock.root .. "/quiet.txt" }, mock.context({ session = askSession, monitor = answering("a"), permission = {} }))
  t.eq(first.status, "completed", "approving runs the tool")
  t.eq(#askSession.permission, 1, "an always-approval is remembered on the session")
  -- Read through `or {}` because an approval that was never asked for leaves
  -- nothing here, and indexing that aborts the whole run on the first failure
  -- instead of saying which expectation broke. That is the shape this bug took:
  -- the prompt got nothing, denied in silence, and the tool never ran.
  local remembered = askSession.permission[1] or {}
  t.eq(remembered.action, "allow", "the remembered rule allows")
  t.eq(remembered.pattern, mock.root .. "/quiet.txt", "the remembered rule names what was approved")

  mock.setup()
  _G.term = {}
  local rejected = registry.execute("read", { filePath = mock.root .. "/quiet.txt" }, mock.context({ session = session.new(), monitor = answering("n"), permission = {} }))
  t.eq(rejected.status, "denied", "answering no denies the call")
  t.contains(rejected.error, "Permission denied", "a denial says so")

  mock.setup()
  _G.term = {}
  local feedback = registry.execute("read", { filePath = mock.root .. "/quiet.txt" }, mock.context({ session = session.new(), monitor = answering("use the glob tool instead"), permission = {} }))
  t.eq(feedback.status, "denied", "a typed explanation denies the call")
  t.contains(feedback.error, "use the glob tool instead", "the explanation is passed back so the model can adapt")

  -- With no terminal there is nobody to ask, so the safe answer is no.
  mock.setup()
  _G.term = nil
  local unattended = registry.execute("read", { filePath = mock.root .. "/quiet.txt" }, mock.context({ session = session.new(), monitor = answering("a"), permission = {} }))
  t.eq(unattended.status, "denied", "without a terminal a call needing approval is denied")

  -- Aborting stops the loop and says so.

  mock.setup()
  current = session.new()
  session.addUser(current, "go")
  mock.respond(textTurn("never reached"))
  local abortedMessage, abortReason = agent.run(context({ session = current, aborted = function() return true end }))
  t.eq(abortedMessage, nil, "an aborted run returns nothing")
  t.eq(abortReason, "aborted", "an aborted run says why it stopped")
  t.eq(#mock.requests, 0, "an aborted run makes no request")

  -- Aborting part way through ends the run after the step in flight.

  mock.setup()
  env.write(mock.root .. "/x.txt", "x")
  current = session.new()
  session.addUser(current, "go")
  mock.respond(toolTurn({ call("read", '{"filePath":"x.txt"}') }))
  mock.respond(textTurn("unreachable"))
  local toolFinished = false
  local partial, partialReason = agent.run(context({
    session = current,
    on = function(event)
      if event.type == "tool_end" then
        toolFinished = true
      end
    end,
    aborted = function()
      return toolFinished
    end,
  }))
  t.eq(partialReason, "aborted", "aborting after a tool ends the run")
  t.eq(#mock.requests, 1, "the run does not ask the model again after an abort")
  t.ok(partial ~= nil, "the message in flight is returned when the run is aborted")

  -- A provider failure ends the run with the error, and the message records it.

  mock.setup()
  current = session.new()
  session.addUser(current, "go")
  mock.failWith("connection refused")
  mock.failWith("connection refused")
  mock.failWith("connection refused")
  local failed, failMessage = agent.run(context({ session = current }))
  t.contains(failMessage, "could not reach", "a provider failure is reported")
  t.eq(failed.error ~= nil, true, "the failed message records the error")
  t.eq(failed.parts[#failed.parts].reason, "error", "the step is finished with an error reason")
  t.eq(#current.messages, 2, "no further turns are attempted after a failure")

  -- Streaming feeds text through as it arrives rather than all at the end.

  mock.setup()
  current = session.new()
  session.addUser(current, "stream please")
  mock.respond("data: {\"choices\":[{\"delta\":{\"content\":\"str\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"eam\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n")
  local deltas = {}
  local streamed = agent.run(context({
    session = current,
    stream = true,
    on = function(event)
      if event.type == "text" then
        deltas[#deltas + 1] = event.delta
      end
    end,
  }))
  t.eq(#deltas, 2, "each delta is reported as it arrives")
  t.eq(session.messageText(streamed), "stream", "the deltas are accumulated into the message")

  -- The step budget comes from config, per agent.

  local configured = require("config").load(mock.root, { agent = { plan = { steps = 7 } } })
  t.eq((configured.agent.plan).steps, 7, "a configured step budget is kept")
  t.eq((configured.agent.build).steps, 25, "an unconfigured agent keeps the default")

  -- isTurnComplete is what decides whether there is anything left to do.

  local fresh = session.new()
  session.addUser(fresh, "hi")
  t.eq(agent.hasPendingWork(fresh), true, "a user message with no reply is pending work")
  mock.setup()
  mock.respond(textTurn("hello"))
  agent.run(context({ session = fresh }))
  t.eq(agent.hasPendingWork(fresh), false, "a finished turn is not pending work")

  -- A follow-up question on the same session gets its own turn, with the earlier
  -- exchange still in context.

  mock.respond(textTurn("the second answer"))
  session.addUser(fresh, "and now the second question")
  local followUp = agent.run(context({ session = fresh }))
  t.eq(#mock.requests, 2, "a second question makes a second request")
  t.eq(session.messageText(followUp), "the second answer", "the second turn is the answer")
  local replayed = sentMessages(2)
  t.eq(replayed[2].content, "hi", "the first question is still in context")
  t.eq(replayed[3].content, "hello", "the first answer is still in context")
  t.eq(replayed[4].content, "and now the second question", "the new question is last")
  t.eq(#fresh.messages, 4, "both turns are stored")

  -- Session persistence round-trips through JSON.

  mock.setup()
  current = session.new("A title")
  session.addUser(current, "remember this")
  mock.respond(textTurn("noted"))
  agent.run(context({ session = current }))
  local path = session.save(current)
  t.ok(path ~= nil, "a session is saved")
  t.contains(path, "opencode/session", "sessions are stored under the opencode directory")
  local reloaded = session.load(current.id)
  t.eq(reloaded.id, current.id, "the reloaded session keeps its id")
  t.eq(session.messageText(reloaded.messages[2]), "noted", "the reloaded session keeps the assistant text")
  t.eq(session.load("ses_nothing"), nil, "loading an unknown session is nil rather than an error")
  t.ok(#session.list() > 0, "a saved session is listed")

  -- Title generation is best-effort: a failure is silent, a success is trimmed.

  mock.setup()
  mock.respond(textTurn('  "Fix the build"  '))
  t.eq(agent.title(context({ smallModel = model }), "the build is broken"), "Fix the build", "a generated title is trimmed of quotes and spaces")
  mock.setup()
  mock.failWith("nope")
  mock.failWith("nope")
  mock.failWith("nope")
  t.eq(agent.title(context({ smallModel = model }), "the build is broken"), nil, "a title failure is silent")
  t.eq(agent.title(context({}), "the build is broken"), nil, "no small model means no title")
  t.eq(agent.title(context({ smallModel = model }), "hi"), nil, "an unusably short prompt is not sent")

  -- Compaction: a conversation that no longer fits is replaced by a summary
  -- written by the small model, keeping the turn in progress.

  --- A model whose context window is small enough that a short conversation
  --- already fills it, so the threshold is easy to cross deliberately.
  local tinyModel = {
    id = "tiny",
    providerID = "openai",
    name = "Tiny",
    base = "https://api.openai.com/v1",
    apiKey = "sk-test",
    options = {},
    limit = { context = 300, output = 128 },
  }

  local function compactingConfig(settings)
    local current = require("config").load(mock.root)
    for key, value in pairs(settings or {}) do
      current.compaction[key] = value
    end
    return current
  end

  --- Three finished exchanges plus a question that has not been answered.
  local function longSession()
    local s = session.new()
    for index = 1, 3 do
      session.addUser(s, "question " .. index)
      local reply = session.addAssistant(s, model)
      session.addText(reply, "answer " .. index)
      session.finishStep(reply, "stop", nil)
    end
    session.addUser(s, "the fourth question")
    return s
  end

  mock.setup()
  local long = longSession()
  mock.respond(textTurn("the user asked three things and got three answers"))
  local summary = agent.compact(context({
    session = long,
    model = tinyModel,
    smallModel = model,
    config = compactingConfig({ reserved = 0 }),
  }))
  t.eq(summary, "the user asked three things and got three answers", "compaction returns the summary it wrote")
  t.eq(#mock.requests, 1, "compaction makes exactly one request")
  t.eq(#long.messages, 3, "the older messages are replaced by the summary")
  t.eq(long.messages[1].summary, true, "the summary is marked as one")
  t.eq(
    session.text(long.messages[1]),
    "Summary of the conversation so far:\n\nthe user asked three things and got three answers",
    "the summary leads the conversation and says what it is"
  )
  t.eq(session.text(long.messages[2]), "answer 3", "the newest assistant message is kept")
  t.eq(session.text(long.messages[3]), "the fourth question", "the newest user message is kept, so the turn can continue")
  t.ok(agent.hasPendingWork(long), "the unanswered question is still pending after compaction")

  local asked = sentBody(1)
  t.eq(asked.model, model.id, "the small model writes the summary")
  t.eq(asked.max_tokens, agent.COMPACT_MAX_TOKENS, "the summary is capped so it is shorter than what it replaces")
  t.eq(asked.messages[1].role, "system", "the compaction prompt leads the summary request")
  t.contains(asked.messages[2].content, "question 1", "the transcript covers the dropped messages")
  t.contains(asked.messages[2].content, "question 3", "the transcript reaches the last dropped message")
  t.notContains(asked.messages[2].content, "the fourth question", "the turn in progress is not summarised away")

  -- A conversation that fits is left alone.

  mock.setup()
  local short = session.new()
  session.addUser(short, "a short question")
  session.addText(session.addAssistant(short, model), "a short answer")
  short.messages[2].finish = "stop"
  t.eq(agent.compact(context({ session = short, model = model, smallModel = model })), nil, "a conversation under the limit is not compacted")
  t.eq(#mock.requests, 0, "and no request is made to find that out")

  -- The three ways compaction declines to happen.

  mock.setup()
  local untouched = longSession()
  t.eq(
    agent.compact(context({ session = untouched, model = tinyModel, smallModel = model, config = compactingConfig({ auto = false }) })),
    nil,
    "compaction.auto = false turns it off"
  )
  t.eq(
    agent.compact(context({ session = untouched, model = tinyModel, config = compactingConfig({ reserved = 0 }) })),
    nil,
    "no small model means no summary can be written"
  )
  t.eq(#mock.requests, 0, "neither of the two costs a request")
  t.eq(#untouched.messages, 7, "and neither changes the conversation")

  -- There is nothing to summarise until there is a second message to drop, so
  -- the first turn of a session is never compacted no matter how long it is.

  mock.setup()
  local firstTurn = session.new()
  session.addUser(firstTurn, string.rep("a very long first question ", 40))
  t.eq(
    agent.compact(context({ session = firstTurn, model = tinyModel, smallModel = model, config = compactingConfig({ reserved = 0 }) })),
    nil,
    "a conversation with no history to summarise is left alone"
  )
  t.eq(#firstTurn.messages, 1, "and the question is still there")
  t.eq(#mock.requests, 0, "with nothing spent finding that out")

  -- A failed summary leaves the conversation exactly as it was, so the next
  -- request fails with the provider's own size error rather than losing history.

  mock.setup()
  local failing = longSession()
  mock.failWith("no")
  mock.failWith("no")
  mock.failWith("no")
  local seen = {}
  t.eq(
    agent.compact(context({
      session = failing,
      model = tinyModel,
      smallModel = model,
      config = compactingConfig({ reserved = 0 }),
      on = function(event) seen[#seen + 1] = event end,
    })),
    nil,
    "a summary that never arrives means no compaction"
  )
  t.eq(#failing.messages, 7, "the conversation is untouched")
  t.contains(tostring(seen[1].message), "could not compact", "the failure is reported")
  t.eq(seen[1].type, "error", "as an error event")

  -- The loop compacts and then carries on with the turn.

  mock.setup()
  local looping = longSession()
  mock.respond(textTurn("earlier: three questions, three answers"))
  mock.respond(textTurn("the answer to the fourth question"))
  local trace = {}
  local done = agent.run(context({
    session = looping,
    model = tinyModel,
    smallModel = model,
    config = compactingConfig({ reserved = 0 }),
    on = function(event) trace[#trace + 1] = event.type end,
  }))
  t.eq(#mock.requests, 2, "the run summarises, then answers")
  t.eq(session.messageText(done), "the answer to the fourth question", "the turn still finishes")
  local replayedSummary = sentMessages(2)
  t.eq(
    replayedSummary[2].content,
    "Summary of the conversation so far:\n\nearlier: three questions, three answers",
    "the summary is what the next request sees, in place of the messages it replaced"
  )
  t.eq(replayedSummary[#replayedSummary].content, "the fourth question", "the pending question is still last")
  local compacted = false
  for _, kind in ipairs(trace) do
    compacted = compacted or kind == "compacted"
  end
  t.eq(compacted, true, "the run says out loud that it compacted")
end
