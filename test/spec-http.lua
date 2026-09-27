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

  -- The argument shape, which is not a style choice.
  --
  -- CC picks its form from the type of the *first* argument. Given a string it
  -- takes the legacy positional signature, where argument 2 is the POST body; a
  -- table there is refused with "bad argument #2 (string expected, got table)"
  -- and the request never leaves the computer. So `http.request(url, { method =
  -- ... })` fails on real hardware while passing any mock that does not check its
  -- arguments, which is exactly what this one used to be — so a program that
  -- could not make a single request had a green suite.
  --
  -- These call CC's entry point rather than the library's: the library pcalls and
  -- retries, so going through it would report the refusal three times over and
  -- quietly eat the queued responses the rest of this spec depends on.

  mock.setup()
  local refused, refusal = pcall(_G.http.request, "https://api.x.com/v1/chat/completions", { method = "GET" })
  t.ok(not refused, "a url followed by an options table is refused, as CC refuses it")
  t.contains(tostring(refusal), "bad argument #2", "with the same complaint CC makes")
  t.contains(tostring(refusal), "string expected, got table", "and the same wording")
  t.eq(countRequests(), 0, "and the request is not recorded, having never been made")

  local handle = _G.http.request({ url = "https://api.x.com/v1/chat/completions", method = "GET", timeout = 5 })
  t.ok(handle, "a url inside the options table is what CC wants")
  handle.close()
  t.eq(lastRequest().url, "https://api.x.com/v1/chat/completions", "and the url is read out of it")
  t.eq(lastRequest().timeout, 5, "with the timeout alongside")
end
