-- llm: the OpenAI-compatible chat client.
--
-- Two paths matter: a buffered non-streamed response, and a `stream: true`
-- request whose SSE frames are reassembled. Both must land in the same shape,
-- because the agent loop cannot tell them apart.

return function(t, mock)
  local llm = require("llm")

  t.suite("llm")

  local function model(overrides)
    local resolved = {
      id = "gpt-4o",
      providerID = "openai",
      name = "GPT-4o",
      base = "https://api.openai.com/v1",
      apiKey = "sk-test",
      options = {},
      limit = { context = 128000, output = 4096 },
    }
    for key, value in pairs(overrides or {}) do
      resolved[key] = value
    end
    return resolved
  end

  local function lastBody()
    return require("json").decode(mock.requests[#mock.requests].body)
  end

  -- Request body: empty fields are omitted so we never send `tools: []`.

  local body = llm.body({ model = model(), messages = { { role = "user", content = "hi" } } })
  t.eq(body.model, "gpt-4o", "the model id goes on the wire")
  t.eq(#body.messages, 1, "the message list is passed through")
  t.eq(body.tools, nil, "an empty tool list is omitted entirely")
  t.eq(body.stream, nil, "streaming is omitted when it was not asked for")
  t.eq(body.max_tokens, nil, "no token cap is invented")

  t.eq(llm.body({ model = model(), messages = {}, tools = { { type = "function" } } }).tools[1].type, "function", "a real tool list is sent")
  t.eq(llm.body({ model = model(), messages = {}, stream = true }).stream, true, "streaming is sent when asked for")
  t.eq(llm.body({ model = model(), messages = {}, stream = true }).stream_options.include_usage, true, "a streamed request asks for usage")

  local generated = llm.body({
    model = model({ options = { maxTokens = 999, temperature = 0.1 } }),
    messages = {},
    generation = { temperature = 0.9, topP = 0.5, maxTokens = 42, seed = 7, stop = { "END" }, frequencyPenalty = 0.2 },
  })
  t.eq(generated.temperature, 0.9, "a per-request temperature beats the provider default")
  t.eq(generated.top_p, 0.5, "top_p is translated to snake_case")
  t.eq(generated.max_tokens, 42, "a per-request token cap beats the provider default")
  t.eq(generated.seed, 7, "a seed is sent when given")
  t.eq(generated.stop[1], "END", "stop sequences are sent")
  t.eq(generated.frequency_penalty, 0.2, "frequency_penalty is sent when given")
  t.eq(llm.body({ model = model({ options = { temperature = 0.1 } }), messages = {} }).temperature, 0.1, "the provider default applies when no override is given")

  -- A non-streamed response.

  mock.setup()
  mock.respondJson({
    choices = { { message = { content = "hello" }, finish_reason = "stop" } },
    usage = { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15 },
  })
  local result = assert(llm.chat({ model = model(), messages = { { role = "user", content = "hi" } } }))
  t.eq(result.content, "hello", "the assistant text is extracted")
  t.eq(result.reasoning, "", "a missing reasoning field is an empty string, not nil")
  t.eq(#result.toolCalls, 0, "a response with no tool calls has an empty list")
  t.eq(result.finish, "stop", "a plain stop is mapped through")
  t.eq(result.usage.input, 10, "prompt tokens become input")
  t.eq(result.usage.output, 5, "completion tokens become output")
  t.eq(result.usage.total, 15, "total tokens are passed through")
  t.eq(result.usage.cacheWrite, 0, "cache writes are always zero: CC sends no cache-control")
  t.ok(result.raw, "the decoded provider response is kept for debugging")

  local sent = mock.requests[#mock.requests]
  t.eq(sent.url, "https://api.openai.com/v1/chat/completions", "the chat completions path is used")
  t.eq(sent.headers["authorization"], "Bearer sk-test", "the credential is sent as a bearer token")
  t.eq(sent.headers["content-type"], "application/json", "the content type is set")
  t.eq(sent.method, "POST", "chat completions is a POST")

  -- Content of null, which some providers send for a pure tool call, must not
  -- become the string "null".

  mock.setup()
  mock.respondJson({ choices = { { message = { content = nil }, finish_reason = "tool_calls" } } })
  local nullContent = assert(llm.chat({ model = model(), messages = {} }))
  t.eq(nullContent.content, "", "a null content field is an empty string, not \"null\"")

  -- Tool calls, non-streamed.

  mock.setup()
  mock.respondJson({
    choices = {
      {
        message = {
          content = nil,
          tool_calls = {
            { id = "call_1", ["function"] = { name = "read", arguments = '{"path":"a.txt"}' } },
            { id = "call_2", ["function"] = { name = "write", arguments = "{}" } },
          },
        },
        finish_reason = "tool_calls",
      },
    },
  })
  local withTools = assert(llm.chat({ model = model(), messages = {} }))
  t.eq(#withTools.toolCalls, 2, "every tool call is kept, in order")
  t.eq(withTools.toolCalls[1].id, "call_1", "the tool call id is kept")
  t.eq(withTools.toolCalls[1].name, "read", "the tool name is unwrapped from `function`")
  t.eq(withTools.toolCalls[1].arguments, '{"path":"a.txt"}', "the arguments stay a JSON string for later decoding")
  t.eq(withTools.finish, "tool-calls", "tool_calls is mapped to tool-calls")

  -- Many OpenAI-compatible servers say "stop" even when they emitted calls.

  mock.setup()
  mock.respondJson({
    choices = {
      {
        message = { content = "", tool_calls = { { id = "c", ["function"] = { name = "bash", arguments = "{}" } } } },
        finish_reason = "stop",
      },
    },
  })
  t.eq(assert(llm.chat({ model = model(), messages = {} })).finish, "tool-calls", "a stop with tool calls is corrected to tool-calls")

  mock.setup()
  mock.respondJson({ choices = { { message = { content = "" }, finish_reason = "stop" } } })
  local seen = {}
  t.eq(assert(llm.chat({ model = model(), messages = {} }, {
    onDelta = function(text) seen[#seen + 1] = text end,
  })).content, "", "an empty message is fine")
  t.eq(#seen, 0, "onDelta is not called for empty content")

  -- Usage with cache and reasoning details.

  mock.setup()
  mock.respondJson({
    choices = { { message = { content = "x" }, finish_reason = "stop" } },
    usage = {
      prompt_tokens = 100,
      completion_tokens = 20,
      prompt_tokens_details = { cached_tokens = 80 },
      completion_tokens_details = { reasoning_tokens = 15 },
    },
  })
  local usage = assert(llm.chat({ model = model(), messages = {} })).usage
  t.eq(usage.cacheRead, 80, "cached prompt tokens are reported")
  t.eq(usage.reasoning, 15, "reasoning tokens are reported")
  t.eq(usage.total, 120, "a total is derived when the provider omits one")

  -- Streaming: buffered on CC, then reassembled here.

  mock.setup()
  mock.respond(table.concat({
    'data: {"choices":[{"delta":{"content":"He"}}]}\n',
    'data: {"choices":[{"delta":{"content":"llo"}}]}\n',
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n',
    'data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1}}\n',
    "data: [DONE]\n",
  }, "\n"))
  local deltas = {}
  local streamed = assert(llm.chat({ model = model(), messages = {}, stream = true }, {
    onDelta = function(text) deltas[#deltas + 1] = text end,
  }))
  t.eq(streamed.content, "Hello", "streamed deltas are concatenated in order")
  t.eq(#deltas, 2, "onDelta fires once per content delta")
  t.eq(deltas[1], "He", "the first delta is the first frame")
  t.eq(streamed.finish, "stop", "the finish reason is taken from the last frame with choices")
  t.eq(streamed.usage.input, 3, "usage arrives in its own trailing frame")
  t.eq(lastBody().stream, true, "the request really did ask for a stream")

  mock.setup()
  mock.respond(table.concat({
    'data: {"choices":[{"delta":{"reasoning_content":"think"}}]}\n',
    'data: {"choices":[{"delta":{"content":"ans"}}]}\n',
    "data: [DONE]\n",
  }, "\n"))
  local reasoned = assert(llm.chat({ model = model(), messages = {}, stream = true }))
  t.eq(reasoned.reasoning, "think", "streamed reasoning content is kept separate from the answer")
  t.eq(reasoned.content, "ans", "streamed content is unaffected by reasoning frames")

  -- Streamed tool calls arrive in fragments and must be reassembled per index.

  mock.setup()
  mock.respond(table.concat({
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"re","arguments":"{\\"pa"}}]}}]}\n',
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"ad","arguments":"th\\":\\"x\\"}"}}]}}]}\n',
    'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"bash","arguments":"{\\"co"}}]}}]}\n',
    'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"mmand\\":\\"ls\\"}"}}]}}]}\n',
    'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n',
    "data: [DONE]\n",
  }, "\n"))
  local streamedCalls = assert(llm.chat({ model = model(), messages = {}, stream = true }))
  t.eq(#streamedCalls.toolCalls, 2, "two interleaved tool calls are tracked separately")
  t.eq(streamedCalls.toolCalls[1].id, "call_a", "the id is taken from the first fragment")
  t.eq(streamedCalls.toolCalls[1].name, "read", "a fragmented name is rejoined")
  t.eq(streamedCalls.toolCalls[1].arguments, '{"path":"x"}', "fragmented arguments are rejoined")
  t.eq(streamedCalls.toolCalls[2].name, "bash", "the second call is not confused with the first")
  t.eq(streamedCalls.toolCalls[2].arguments, '{"command":"ls"}', "the second call's arguments are rejoined")
  t.eq(streamedCalls.finish, "tool-calls", "a streamed tool call is a tool call")

  -- Headers: model-level overrides and extra headers.

  mock.setup()
  mock.respondJson({ choices = { { message = { content = "" }, finish_reason = "stop" } } })
  assert(llm.chat({ model = model({ headers = { ["HTTP-Referer"] = "cc", ["X-Title"] = "CC-opencode" } }), messages = {} }))
  local headers = mock.requests[#mock.requests].headers
  t.eq(headers["http-referer"], "cc", "a model header is sent, lowercased")
  t.eq(headers["x-title"], "CC-opencode", "a second model header is sent too")

  mock.setup()
  mock.respondJson({ choices = { { message = { content = "" }, finish_reason = "stop" } } })
  assert(llm.chat({ model = model({ headers = { ["Content-Type"] = "application/json; charset=utf-8" } }), messages = {} }))
  t.eq(mock.requests[#mock.requests].headers["content-type"], "application/json; charset=utf-8", "a header override wins case-insensitively")

  mock.setup()
  mock.respondJson({ choices = { { message = { content = "" }, finish_reason = "stop" } } })
  assert(llm.chat({ model = model({ apiKey = "" }), messages = {} }))
  t.eq(mock.requests[#mock.requests].headers["authorization"], nil, "no authorization header is sent when there is no key")

  -- Failures

  mock.setup()
  mock.respond({ status = 401, body = '{"error":{"message":"Invalid API key"}}' })
  local unauthorized, unauthorizedMessage = llm.chat({ model = model(), messages = {} })
  t.eq(unauthorized, nil, "a rejected request is an error")
  t.contains(unauthorizedMessage, "Invalid API key", "the provider's message is passed through")

  mock.setup()
  mock.respondJson({ choices = {} })
  local empty, emptyMessage = llm.chat({ model = model(), messages = {} })
  t.eq(empty, nil, "a response with no choices is an error")
  t.contains(emptyMessage, "no choices", "an empty response says so")

  mock.setup()
  mock.failWith("Network unreachable")
  local unreachable = llm.chat({ model = model(), messages = {} })
  t.eq(unreachable, nil, "a transport failure is an error")

  -- parseArguments

  t.eq(llm.parseArguments('{"path":"a","limit":5}').path, "a", "a JSON object is decoded")
  t.eq(llm.parseArguments('{"path":null}').path, nil, "explicit nulls are dropped so they do not look like values")
  t.eq(#llm.parseArguments(""), 0, "empty arguments are an empty table, not an error")
  t.eq(#llm.parseArguments(nil), 0, "absent arguments are an empty table")
  t.eq(llm.parseArguments("{oops"), nil, "malformed arguments are an error")
  t.contains(select(2, llm.parseArguments("{oops")), "byte 2", "malformed arguments say where they failed")
  t.eq(llm.parseArguments('"a string"'), nil, "arguments that are not an object are an error")
  t.eq(llm.parseArguments({ path = "already" }).path, "already", "already-decoded arguments pass through")
end
