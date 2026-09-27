-- HTTP with retries, built on ComputerCraft's `http.request`.
--
-- CC's request is a blocking read of the whole body, so there is no incremental
-- streaming here. Requests that ask for `stream = true` are buffered and then
-- reassembled from SSE frames by the LLM client.

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
-- is returned as a normal response so callers can read the provider's error
-- body; only transport failures and exhausted retries become errors.
function M.request(url, options)
  options = options or {}
  local attempts = options.attempts or M.MAX_ATTEMPTS
  local lastError = "no attempt was made"

  for attempt = 1, attempts do
    local ok, handle = pcall(http.request, url, {
      method = options.method or "GET",
      headers = options.headers,
      body = options.body,
      timeout = options.timeout or M.DEFAULT_TIMEOUT,
    })

    if ok and handle then
      local status = handle.getResponseCode and handle.getResponseCode() or 200
      local headers = handle.getResponseHeaders and handle.getResponseHeaders() or {}
      local response = { status = status, headers = headers, body = readHandle(handle, options.maxBytes) }
      if not (M.RETRYABLE[status] and attempt < attempts) then
        return response
      end
      lastError = "HTTP " .. status
      if attempt < attempts then
        util.sleep(backoff(attempt, headers))
      end
    else
      if isBlockedHost(handle) then
        -- Fail now rather than twice more: the answer cannot change, and the
        -- backoff would turn a missing config line into a ten second wait.
        return nil, blockedMessage(url)
      end
      lastError = "could not reach " .. url .. " (" .. tostring(handle) .. ")"
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
