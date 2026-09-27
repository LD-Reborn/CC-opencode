-- http: retries, backoff, SSE frame extraction, and error messages.
--
-- The mocked `os.sleep` accumulates into `mock.sleeps`, so backoff can be
-- asserted without the suite actually waiting.

return function(t, mock)
  local http = require("http")
  local json = require("json")

  t.suite("http")

  local function lastRequest()
    return mock.requests[#mock.requests]
  end

  local function countRequests()
    return #mock.requests
  end

  -- A successful request passes options straight through.

  local before = countRequests()
  mock.respond({ status = 200, headers = { ["content-type"] = "application/json" }, body = '{"ok":true}' })
  local response = assert(http.request("https://api.x.com/v1/chat/completions", {
    method = "POST",
    headers = { ["content-type"] = "application/json" },
    body = "{}",
    timeout = 12,
  }))
  t.eq(response.status, 200, "the status is reported")
  t.eq(response.body, '{"ok":true}', "the whole body is buffered")
  t.eq(response.headers["content-type"], "application/json", "response headers are available")
  t.eq(countRequests() - before, 1, "a 2xx response is not retried")

  local sent = lastRequest()
  t.eq(sent.url, "https://api.x.com/v1/chat/completions", "the url is passed to CC")
  t.eq(sent.method, "POST", "the method is passed to CC")
  t.eq(sent.body, "{}", "the body is passed to CC")
  t.eq(sent.headers["content-type"], "application/json", "request headers are passed to CC")

  -- The request is one table, and that is not a style choice. Covered at the end
  -- of this spec, where it can make its own requests without disturbing the
  -- relative counts the assertions above rely on.
  t.eq(sent.timeout, 12, "the timeout is passed to CC")

  -- A non-2xx response is returned, not raised, so callers can read the body.

  mock.respond({ status = 400, body = '{"error":{"message":"bad model"}}' })
  local bad = assert(http.request("https://api.x.com/v1/chat/completions"))
  t.eq(bad.status, 400, "a 400 is returned to the caller")
  t.eq(countRequests() - before, 2, "a 400 is not retried")

  -- Retryable statuses are retried until they stop being retryable.

  mock.setup()
  before = countRequests()
  mock.respond({ status = 429, body = "slow down" })
  mock.respond({ status = 503, body = "unavailable" })
  mock.respond({ status = 200, body = '{"ok":true}' })
  local recovered = assert(http.request("https://api.x.com/v1/chat/completions"))
  t.eq(recovered.status, 200, "a retry that succeeds is returned")
  t.eq(countRequests() - before, 3, "429 then 503 then 200 is three attempts")
  t.ok(mock.sleeps > 0, "a backoff is slept between attempts")

  mock.setup()
  before = countRequests()
  mock.respond({ status = 503, body = "down" })
  mock.respond({ status = 503, body = "down" })
  mock.respond({ status = 503, body = "down" })
  local exhausted = http.request("https://api.x.com/v1/chat/completions")
  t.eq(exhausted.status, 503, "the last retryable response is returned once attempts run out")
  t.eq(countRequests() - before, http.MAX_ATTEMPTS, "the attempt budget is respected")

  mock.setup()
  before = countRequests()
  mock.respond({ status = 429, body = "wait" })
  mock.respond({ status = 200, body = "{}" })
  http.request("https://api.x.com/v1/chat/completions", { attempts = 1 })
  t.eq(countRequests() - before, 1, "an explicit attempt budget of 1 makes exactly one attempt")

  -- Retry-After is honoured instead of the exponential schedule.

  mock.setup()
  mock.sleeps = 0
  mock.respond({ status = 429, headers = { ["retry-after-ms"] = "2500" }, body = "wait" })
  mock.respond({ status = 200, body = "{}" })
  assert(http.request("https://api.x.com/v1/chat/completions"))
  t.eq(mock.sleeps, 2.5, "retry-after-ms is converted from milliseconds")

  -- Transport failures are retried too, and reported once the budget is spent.

  mock.setup()
  before = countRequests()
  mock.failWith("connection refused")
  mock.failWith("connection refused")
  mock.failWith("connection refused")
  local unreachable, message = http.request("https://api.x.com/v1/chat/completions")
  t.eq(unreachable, nil, "an unreachable host is an error, not a response")
  t.contains(message, "could not reach", "an unreachable host says so")
  t.contains(message, "https://api.x.com/v1/chat/completions", "an unreachable host names the url")
  t.eq(countRequests() - before, http.MAX_ATTEMPTS, "a transport failure is retried")

  -- A host the server's allowlist refuses is not a transport failure: the
  -- answer cannot change, and the fix is a config file rather than a retry.

  do
    for _, reason in ipairs({ "Domain not permitted", "domain is not permitted", "Error: Domain Not Permitted: x" }) do
      mock.setup()
      before = countRequests()
      mock.failWith(reason)
      local blocked, blockedMessage = http.request("https://forge.example/raw/main/init.lua")
      t.eq(blocked, nil, "a refused host is an error: " .. reason)
      t.eq(countRequests() - before, 1, "and is not retried: " .. reason)
      t.contains(blockedMessage, "allowlist", "it says the allowlist is the problem: " .. reason)
      t.contains(blockedMessage, "forge.example", "it names the host: " .. reason)
      t.contains(blockedMessage, "computercraft-server.toml", "and the file to edit: " .. reason)
      t.contains(blockedMessage, "$private", "and the rule that refuses a host on a lan: " .. reason)
    end
  end

  do
    -- A transport failure that merely mentions a domain is still retried; the
    -- match is on the refusal, not on the word.
    mock.setup()
    before = countRequests()
    mock.failWith("connection refused: could not reach host")
    mock.failWith("connection refused: could not reach host")
    mock.failWith("connection refused: could not reach host")
    local response, message = http.request("https://api.x.com/v1/chat/completions")
    t.eq(response, nil, "an unreachable host is still an error")
    t.contains(message, "could not reach", "and still says so")
    t.eq(countRequests() - before, http.MAX_ATTEMPTS, "and is still retried")
  end

  -- A cap on the response size keeps a runaway body out of memory.

  mock.setup()
  mock.respond({ status = 200, body = string.rep("x", 500) })
  local capped = assert(http.request("https://api.x.com/v1/chat/completions", { maxBytes = 100 }))
  t.eq(#capped.body, 100, "the body is truncated at maxBytes")

  -- SSE frames

  local frames = http.parseSse("data: {\"a\":1}\n\ndata: {\"b\":2}\n\ndata: [DONE]\n\n")
  t.eq(#frames, 2, "the terminal [DONE] frame is dropped")
  t.eq(frames[1], '{"a":1}', "the first frame is the payload after `data:`")
  t.eq(frames[2], '{"b":2}', "frames keep their order")

  t.eq(#http.parseSse("data: {\"a\":1}\r\n"), 1, "CRLF line endings are handled")
  t.eq(http.parseSse("data: {\"a\":1}\r\n")[1], '{"a":1}', "the carriage return is stripped from a frame")
  t.eq(#http.parseSse(""), 0, "an empty body has no frames")
  t.eq(#http.parseSse(nil), 0, "a nil body has no frames")
  t.eq(#http.parseSse("event: ping\n\n"), 0, "non-data events are ignored")

  -- Error messages

  t.eq(
    http.errorMessage({ status = 401, body = '{"error":{"message":"Invalid API key"}}' }),
    "HTTP 401: Invalid API key",
    "a nested provider error is unwrapped"
  )
  t.eq(
    http.errorMessage({ status = 429, body = '{"error":"slow down"}' }),
    "HTTP 429: slow down",
    "a string provider error is unwrapped"
  )
  t.eq(
    http.errorMessage({ status = 502, body = "  <html>bad gateway</html>  " }),
    "HTTP 502: <html>bad gateway</html>",
    "a non-JSON body is trimmed and used as-is"
  )
  t.eq(
    http.errorMessage({ status = 500, body = "" }),
    "HTTP 500: (empty response body)",
    "an empty body still produces a message"
  )
  t.eq(
    #http.errorMessage({ status = 500, body = string.rep("z", 900) }),
    #"HTTP 500: " + 400 + 3,
    "a huge body is cut to 400 characters plus an ellipsis"
  )

  -- postJson

  mock.setup()
  mock.respondJson({ choices = { { message = { content = "hi" } } } })
  local posted = assert(http.postJson("https://api.x.com/v1/chat/completions", { model = "m" }))
  t.eq(posted.data.choices[1].message.content, "hi", "the decoded body is attached as `data`")
  t.eq(json.decode(lastRequest().body).model, "m", "the payload is JSON encoded onto the wire")

  mock.setup()
  mock.respond({ status = 200, body = "not json at all" })
  local undecodable, decodeMessage = http.postJson("https://api.x.com/v1/chat/completions", {})
  t.eq(undecodable, nil, "an undecodable body is an error")
  t.contains(decodeMessage, "could not parse", "an undecodable body says why")

  mock.setup()
  mock.respond({ status = 422, body = '{"error":{"message":"too many tokens"}}' })
  local rejected, rejectMessage = http.postJson("https://api.x.com/v1/chat/completions", {})
  t.eq(rejected, nil, "a 4xx is an error for postJson")
  t.contains(rejectMessage, "too many tokens", "the provider's own message survives")

  mock.setup()
  mock.respond({ status = 200, body = '{"raw":true}' })
  http.postJson("https://api.x.com/v1/chat/completions", nil, { raw = '{"already":"encoded"}' })
  t.eq(lastRequest().body, '{"already":"encoded"}', "a raw body bypasses the encoder")

  -- Which function to call, and with what. Neither is a style choice, and each
  -- reads as though the other one were meant.
  --
  -- `http.request` is asynchronous. It starts the request, returns immediately,
  -- and delivers the response later as an `http_success` event; its own source
  -- calls the return value "for legacy reasons" and undocumented. It is a
  -- boolean, so `handle.getResponseCode()` raises "attempt to index local
  -- 'handle' (a boolean value)" and nothing is ever fetched. `http.get` and
  -- `http.post` are the synchronous wrappers around that identical call, and
  -- that wrapper is the whole difference.
  --
  -- Every form dispatches on the type of its *first* argument. A string puts it
  -- in the legacy positional signature, where argument 2 is the body and must be
  -- a string, so `http.request(url, { method = "GET" })` is refused with "bad
  -- argument #2 (string expected, got table)".
  --
  -- The mock used to accept any of this and hand back a handle regardless, so a
  -- program that could not make a single request on a computer had a green suite.
  -- It reproduces both refusals now, and these assertions are what keep it
  -- honest: relax the mock again and they fail, rather than the program quietly
  -- breaking on hardware.
  --
  -- They call CC's entry point rather than the library's, because the library
  -- pcalls and retries -- going through it would report a refusal three times
  -- over and quietly eat the queued responses the rest of this spec depends on.

  -- A 4xx arrives as the third return value, not as an error string.
  --
  -- `http.get` answers `nil, message`, and behind them the failing response
  -- whenever the server said anything at all. On a computer that message is a bare
  -- reason phrase -- "Too Many Requests" -- so the status has to be read off the
  -- response instead. Read the message and a provider error loses both its code
  -- and the body carrying the explanation, which is the one thing worth showing.

  do
    mock.respond({ status = 429, headers = { ["retry-after"] = "7" }, body = '{"error":{"message":"slow down"}}' })
    local response = http.request("https://api.x.com/v1/chat/completions", { attempts = 1 })
    t.ok(response, "a 429 is a response, not a failure")
    t.eq(response.status, 429, "whose status comes off the response handle")
    t.eq(response.headers["retry-after"], "7", "carrying the header a backoff needs")
    t.eq(http.errorMessage(response), "HTTP 429: slow down", "so the message is the provider's, not a reason phrase")
  end

  -- A throw is our bug, not the network's.
  --
  -- `pcall` is here for CC checking the table it was handed, and everything it
  -- checks is ours: the method, the timeout's type, the url. Retrying that three
  -- times would spend three requests to learn the same thing, so it is reported
  -- as what it is rather than dressed up as a network fault.

  do
    mock.setup()
    local before = countRequests()
    local bad, why = http.request("https://api.x.com/v1/chat/completions", { method = "GET WITH SPACES" })
    t.eq(bad, nil, "a method CC will not accept is an error")
    t.contains(why, "internal error", "reported as a bug in the request")
    t.contains(why, "Invalid HTTP method", "keeping CC's own complaint")
    t.notContains(why, "could not reach", "and not claiming the host was at fault")
    t.eq(countRequests() - before, 0, "and no request was made at all, let alone three")
  end

  mock.setup()

  do
    local started = _G.http.request({ url = "https://api.x.com/v1/chat/completions", method = "GET" })
    t.eq(type(started), "boolean", "http.request answers with a boolean, being asynchronous")
    t.eq(started, true, "true, meaning the request was started rather than finished")
  end

  do
    local refused, refusal = pcall(_G.http.request, "https://api.x.com/v1/chat/completions", { method = "GET" })
    t.ok(not refused, "a url followed by an options table is refused, as CC refuses it")
    t.contains(tostring(refusal), "bad argument #2", "with the same complaint CC makes")
    t.contains(tostring(refusal), "string expected, got table", "and the same wording")
  end

  do
    local handle = _G.http.get({ url = "https://api.x.com/v1/chat/completions", method = "GET", timeout = 5 })
    t.eq(type(handle), "table", "http.get answers with a response")
    t.eq(handle.getResponseCode(), 200, "which is readable")
    handle.close()
    t.eq(lastRequest().url, "https://api.x.com/v1/chat/completions", "the url comes out of the table")
    t.eq(lastRequest().timeout, 5, "with the timeout alongside")
  end

  do
    -- `get` refuses a body and `post` allows one, which is why the library picks
    -- its entry point from the presence of a body rather than from the method.
    local refused, refusal = pcall(_G.http.get, { url = "https://api.x.com/", body = "{}" })
    t.ok(not refused, "http.get refuses a body")
    t.contains(tostring(refusal), "bad field 'body'", "by naming the field")

    local handle = _G.http.post({ url = "https://api.x.com/", method = "GET", body = "{}", timeout = 5 })
    t.ok(handle, "http.post accepts one")
    handle.close()
    t.eq(lastRequest().body, "{}", "and sends it")
    t.eq(lastRequest().method, "GET", "with the method taken from the table, not the function name")
  end
end
