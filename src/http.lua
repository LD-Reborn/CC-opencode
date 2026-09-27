-- HTTP with retries, built on ComputerCraft's synchronous `http.get`/`http.post`.
--
-- There is no incremental streaming here, and the reason is the shape of CC's
-- api rather than a choice. The response handle only exists once the whole
-- response has arrived, so there is nothing to hand on as it comes in. A request
-- that asks for `stream = true` is therefore buffered and then reassembled from
-- SSE frames by the LLM client; what that costs is the wait, since the terminal
-- stays quiet until the last byte lands.

local json = require("json")
local util = require("util")

local M = {}

M.DEFAULT_TIMEOUT = 60
M.RETRYABLE = { [408] = true, [409] = true, [429] = true, [500] = true, [502] = true, [503] = true, [504] = true, [529] = true }
M.MAX_ATTEMPTS = 3
M.BASE_DELAY = 1
M.MAX_DELAY = 16

--- Split a `data:` payload stream into its individual SSE frame strings.
function M.parseSse(body)
  local frames = {}
  for frame in (body or ""):gmatch("data:%s*([^\n]*)\n") do
    frame = frame:gsub("\r$", "")
    if frame ~= "" and frame ~= "[DONE]" then
      frames[#frames + 1] = frame
    end
  end
  return frames
end

--- Read a CC handle to completion, capping the result at `maxBytes`.
local function readHandle(handle, maxBytes)
  local body = handle.readAll and handle.readAll() or handle.read("*a")
  handle.close()
  if not maxBytes or #body <= maxBytes then
    return body or ""
  end
  return body:sub(1, maxBytes)
end

--- Whether a thrown error is the server refusing the host outright.
--
-- ComputerCraft keeps an allowlist of hosts a computer may reach, and a host
-- that is not on it is refused before any request is made. That is a different
-- kind of failure from a network fault: it is not transient, it is not the
-- caller's doing, and no amount of retrying will change the answer. The wording
-- has changed between CC versions, so both parts are matched rather than the
-- whole phrase.
local function isBlockedHost(reason)
  local lower = tostring(reason):lower()
  return lower:find("domain", 1, true) ~= nil and lower:find("not permitted", 1, true) ~= nil
end

--- What to tell someone whose host is not on the allowlist.
--
-- The bare CC error names the symptom and nothing else, and the thing that has
-- to change is a config file on the server rather than anything the caller can
-- do, so naming the file is the difference between a fixable problem and a
-- mysterious one.
local function blockedMessage(url)
  local host = url:match("^https?://([^/]+)") or url
  return "the server's http allowlist does not permit " .. host
    .. "\n  it needs an entry in serverconfig/computercraft-server.toml, as"
    .. "\n  [[http.rules]] with host = \"" .. host .. "\" and action = \"allow\","
    .. "\n  then a server restart. A host on your own network is refused by the"
    .. "\n  default $private deny rule whatever its name, so check that too."
end

--- Case-insensitive header lookup; CC normalises header names but not reliably.
local function lookup(headers, name)
  if not headers then
    return nil
  end
  local direct = headers[name]
  if direct then
    return direct
  end
  local lowered = name:lower()
  for key, value in pairs(headers) do
    if key:lower() == lowered then
      return value
    end
  end
  return nil
end

--- Seconds to wait before retrying, honouring Retry-After when the server sent it.
local function backoff(attempt, headers)
  local retryAfter = lookup(headers, "retry-after-ms") or lookup(headers, "retry-after")
  if retryAfter then
    local ms = tonumber(retryAfter)
    if ms then
      return math.min(60, ms / 1000)
    end
    local date = tonumber(retryAfter)
    if date and date > os.time() then
      return math.min(60, date - os.time())
    end
  end
  return math.min(M.MAX_DELAY, M.BASE_DELAY * 2 ^ (attempt - 1)) * (0.75 + math.random() * 0.5)
end

--- Perform a request, retrying 429 and 5xx responses.
--
-- Returns `response` on success, or `nil, message` on failure. A non-2xx status
-- is returned as a normal response so callers can read the provider's error body;
-- only transport failures, exhausted retries, and a request table CC refuses
-- become errors.
function M.request(url, options)
  options = options or {}
  local attempts = options.attempts or M.MAX_ATTEMPTS
  local lastError = "no attempt was made"

  for attempt = 1, attempts do
    -- `http.get` or `http.post`, never `http.request`.
    --
    -- `http.request` is the asynchronous half of CC's API: it starts the request,
    -- returns immediately, and delivers the response later as an `http_success`
    -- event. Its own source describes the return value as "for legacy reasons"
    -- and undocumented. It is a boolean, so reading a response out of it raises
    -- "attempt to index local 'handle' (a boolean value)" and nothing is ever
    -- fetched. The synchronous pair wraps that identical call in an `os.pullEvent`
    -- loop, and that loop is the whole difference.
    --
    -- `get` refuses a body and `post` allows one, so the entry point follows the
    -- presence of a body rather than the other way round. A body-less DELETE goes
    -- through `get`, which passes `method` on to the socket regardless.
    --
    -- The url goes *inside* the table, which is the documented options form.
    -- CC dispatches on the type of the first argument, and a string puts it in the
    -- legacy positional signature, where argument 2 is the body and must be a
    -- string -- so a table in second place is refused outright with "bad argument
    -- #2 (string expected, got table)".
    --
    -- The keys are spelled out rather than merged from `options` because a nil
    -- value is not the same as an absent key: `headers = nil` through a table
    -- constructor drops the key, but a caller that built the options table itself
    -- cannot be relied on to have done the same.
    local request = {
      url = url,
      method = options.method or "GET",
      timeout = options.timeout or M.DEFAULT_TIMEOUT,
    }
    if options.headers then
      request.headers = options.headers
    end
    if options.body then
      request.body = options.body
    end
    local ok, handle, reason, failed = pcall(request.body and http.post or http.get, request)

    if not ok then
      -- A throw here is CC checking the shape of the table, which is our bug and
      -- not the network's: an unusable method, a timeout that is not a number.
      -- Retrying it three times would spend three requests to learn the same
      -- thing, so say what it is instead of dressing it up as a network fault.
      return nil, "internal error: " .. tostring(handle)
    end

    -- A 2xx comes back as the first value. A 4xx or 5xx comes back as the third,
    -- with the message in the second, and both are real responses worth reading:
    -- a provider's own error text exists only in that body, and a 429's
    -- Retry-After header only with it. Only a transport failure has neither.
    local answer = handle or failed
    if answer then
      local status = answer.getResponseCode and answer.getResponseCode() or 200
      local headers = answer.getResponseHeaders and answer.getResponseHeaders() or {}
      local response = { status = status, headers = headers, body = readHandle(answer, options.maxBytes) }
      if not (M.RETRYABLE[status] and attempt < attempts) then
        return response
      end
      lastError = "HTTP " .. status
      if attempt < attempts then
        util.sleep(backoff(attempt, headers))
      end
    else
      -- The socket failed and nothing answered. This is also where a host missing
      -- from the server's allowlist lands, since CC refuses it before the request
      -- is ever made -- so the wording is checked here as well as on a throw.
      if isBlockedHost(reason) then
        -- Fail now rather than twice more: the answer cannot change, and the
        -- backoff would turn a missing config line into a ten second wait.
        return nil, blockedMessage(url)
      end
      lastError = "could not reach " .. url .. " (" .. tostring(reason) .. ")"
      if attempt < attempts then
        util.sleep(backoff(attempt, nil))
      end
    end
  end

  return nil, lastError
end

--- Best-effort extraction of a human readable message from a failed response.
function M.errorMessage(response)
  local body = response.body or ""
  local decoded = json.decode(body)
  if type(decoded) == "table" then
    local message = decoded.error
    if type(message) == "table" then
      message = message.message
    end
    if type(message) == "string" and message ~= "" then
      return "HTTP " .. response.status .. ": " .. message
    end
  end
  local trimmed = util.trim(body)
  if trimmed == "" then
    trimmed = "(empty response body)"
  end
  if #trimmed > 400 then
    trimmed = trimmed:sub(1, 400) .. "..."
  end
  return "HTTP " .. response.status .. ": " .. trimmed
end

--- POST a JSON body. Returns a response table with `data` holding the decode.
--
-- `options.decode = false` leaves `data` unset, for callers that expect an
-- event stream rather than a JSON document.
function M.postJson(url, payload, options)
  options = options or {}
  local response, err = M.request(url, {
    method = "POST",
    headers = options.headers,
    body = options.raw or json.encode(payload),
    timeout = options.timeout,
    attempts = options.attempts,
    maxBytes = options.maxBytes,
  })
  if not response then
    return nil, err
  end
  if response.status < 200 or response.status >= 300 then
    return nil, M.errorMessage(response)
  end

  if options.decode == false then
    return response
  end
  response.data = json.decode(response.body or "")
  if not response.data then
    return nil, "could not parse the response as JSON: " .. tostring(response.body):sub(1, 200)
  end
  return response
end

return M
