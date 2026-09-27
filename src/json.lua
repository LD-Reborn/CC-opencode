-- JSON encoder/decoder for CC-opencode.
-- Written by hand rather than using textutils so that null is a distinct value
-- (an assistant message with `content: null` is meaningful) and encoding is
-- deterministic, which cache keys rely on.

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY_MT = { __isarray = true }

--- Mark a table so it encodes as a JSON array even when empty.
function M.array(t)
  return setmetatable(t or {}, ARRAY_MT)
end

--- True when `v` is the sentinel produced for a JSON `null`.
function M.isNull(v)
  return v == M.null
end

--- Replace every `json.null` inside a table with nil, so the result only holds
-- keys the encoder will emit.
function M.dropNulls(t)
  if type(t) ~= "table" then return t end
  for k, v in pairs(t) do
    if v == M.null then
      t[k] = nil
    elseif type(v) == "table" then
      M.dropNulls(v)
    end
  end
  return t
end

local ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local UNESCAPES = {
  ['"'] = '"',
  ['\\'] = '\\',
  ['/'] = '/',
  b = '\b',
  f = '\f',
  n = '\n',
  r = '\r',
  t = '\t',
}

for char, escape in pairs(ESCAPES) do
  UNESCAPES[escape] = char
end

local function encodeString(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(char)
    return ESCAPES[char] or string.format('\\u%04x', char:byte())
  end) .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("Cannot encode " .. tostring(n) .. " as JSON")
  end
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return string.format("%.14g", n)
end

--- Scan a table to decide array vs object, returning the highest array index.
--
-- A table is an array when every key is a positive integer. Holes are kept, and
-- encode them as null, because a model that sent `["a", null, "b"]` must get the
-- same array back. An empty table is ambiguous and encodes as an object unless it
-- was marked with `json.array`.
local function arrayLength(t)
  if getmetatable(t) == ARRAY_MT then
    return #t
  end
  local length = 0
  local keys = 0
  for key in pairs(t) do
    keys = keys + 1
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil
    end
    if key > length then
      length = key
    end
  end
  if keys == 0 then
    return nil
  end
  return length
end

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function encodeInto(value, out, indent, depth)
  local kind = type(value)

  if value == nil or value == M.null then
    out[#out + 1] = "null"
    return
  end
  if kind == "boolean" then
    out[#out + 1] = tostring(value)
    return
  end
  if kind == "number" then
    out[#out + 1] = encodeNumber(value)
    return
  end
  if kind == "string" then
    out[#out + 1] = encodeString(value)
    return
  end
  if kind ~= "table" then
    error("Cannot encode " .. kind .. " as JSON")
  end
  if depth > 64 then
    error("JSON nesting is too deep")
  end

  local newline, pad, innerPad = "", "", ""
  if indent then
    newline = "\n"
    pad = string.rep(indent, depth)
    innerPad = string.rep(indent, depth + 1)
  end

  local length = arrayLength(value)
  if length then
    if length == 0 then
      out[#out + 1] = "[]"
      return
    end
    out[#out + 1] = "[" .. newline
    for i = 1, length do
      out[#out + 1] = innerPad
      encodeInto(value[i], out, indent, depth + 1)
      out[#out + 1] = i < length and ("," .. newline) or newline
    end
    out[#out + 1] = pad .. "]"
    return
  end

  local keys = sortedKeys(value)
  if #keys == 0 then
    out[#out + 1] = "{}"
    return
  end
  out[#out + 1] = "{" .. newline
  for i = 1, #keys do
    local key = keys[i]
    out[#out + 1] = innerPad .. encodeString(tostring(key)) .. ":" .. (indent and " " or "")
    encodeInto(value[key], out, indent, depth + 1)
    out[#out + 1] = i < #keys and ("," .. newline) or newline
  end
  out[#out + 1] = pad .. "}"
end

--- Encode a Lua value as JSON. Pass `indent` for pretty output.
function M.encode(value, indent)
  local out = {}
  local ok, err = pcall(encodeInto, value, out, indent, 0)
  if not ok then
    return nil, err
  end
  return table.concat(out)
end

local function utf8Encode(code)
  if code < 0x80 then
    return string.char(code)
  end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  if code < 0x10000 then
    return string.char(
      0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40,
      0x80 + code % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40,
    0x80 + code % 0x40
  )
end

local function decodeString(s, i)
  local out = {}
  i = i + 1
  while true do
    local char = s:sub(i, i)
    if char == "" then
      return nil, "unterminated string"
    end
    if char == '"' then
      return table.concat(out), i + 1
    end
    if char == "\\" then
      local escape = s:sub(i + 1, i + 1)
      local literal = UNESCAPES[escape]
      if literal then
        out[#out + 1] = literal
        i = i + 2
      elseif escape == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        if not code then
          return nil, "invalid unicode escape at byte " .. i
        end
        i = i + 6
        if code >= 0xD800 and code <= 0xDBFF then
          -- A high surrogate is only half a character; pair it with the low one
          -- that follows, if there is one.
          local low = tonumber(s:sub(i + 2, i + 5), 16)
          if s:sub(i, i) == "\\" and s:sub(i + 1, i + 1) == "u" and low and low >= 0xDC00 and low <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = utf8Encode(code)
      else
        return nil, "invalid escape at byte " .. i
      end
    else
      local stop = s:find('["\\]', i) or #s + 1
      out[#out + 1] = s:sub(i, stop - 1)
      i = stop
    end
  end
end

local WHITESPACE = { [" "] = true, ["\t"] = true, ["\n"] = true, ["\r"] = true }

local decodeValue

local function skipWhitespace(s, i)
  while WHITESPACE[s:sub(i, i)] do
    i = i + 1
  end
  return i
end

local function decodeObject(s, i, depth)
  local out = {}
  i = skipWhitespace(s, i + 1)
  if s:sub(i, i) == "}" then
    return out, i + 1
  end
  while true do
    if s:sub(i, i) ~= '"' then
      return nil, "expected object key at byte " .. i
    end
    local key, next_i = decodeString(s, i)
    if not key then
      return nil, next_i
    end
    i = skipWhitespace(s, next_i)
    if s:sub(i, i) ~= ":" then
      return nil, "expected ':' at byte " .. i
    end
    local value, next_i = decodeValue(s, skipWhitespace(s, i + 1), depth + 1)
    if value == nil then
      return nil, next_i
    end
    out[key] = value
    i = skipWhitespace(s, next_i)
    local char = s:sub(i, i)
    if char == "," then
      i = skipWhitespace(s, i + 1)
    elseif char == "}" then
      return out, i + 1
    else
      return nil, "expected ',' or '}' at byte " .. i
    end
  end
end

local function decodeArray(s, i, depth)
  local out = M.array({})
  i = skipWhitespace(s, i + 1)
  if s:sub(i, i) == "]" then
    return out, i + 1
  end
  while true do
    local value, next_i = decodeValue(s, skipWhitespace(s, i), depth + 1)
    if value == nil then
      return nil, next_i
    end
    out[#out + 1] = value
    i = skipWhitespace(s, next_i)
    local char = s:sub(i, i)
    if char == "," then
      i = i + 1
    elseif char == "]" then
      return out, i + 1
    else
      return nil, "expected ',' or ']' at byte " .. i
    end
  end
end

local LITERALS = {
  { "true", true, 4 },
  { "false", false, 5 },
  { "null", M.null, 4 },
}

decodeValue = function(s, i, depth)
  if depth > 64 then
    return nil, "JSON nesting is too deep"
  end
  local char = s:sub(i, i)
  if char == "{" then
    return decodeObject(s, i, depth)
  end
  if char == "[" then
    return decodeArray(s, i, depth)
  end
  if char == '"' then
    return decodeString(s, i)
  end
  for _, literal in ipairs(LITERALS) do
    if s:sub(i, i + literal[3] - 1) == literal[1] then
      return literal[2], i + literal[3]
    end
  end
  local numberStart = s:find("^%-?%d+", i)
  if not numberStart then
    return nil, "unexpected character at byte " .. i
  end
  local finish = s:find("[^%d%.eE%+%-]", numberStart) or (#s + 1)
  local text = s:sub(numberStart, finish - 1)
  local number = tonumber(text)
  if not number then
    return nil, "invalid number '" .. text .. "'"
  end
  return number, finish
end

--- Decode a JSON string. Returns `nil, message` on failure.
function M.decode(s)
  if type(s) ~= "string" then
    return nil, "expected a string, got " .. type(s)
  end
  local start = skipWhitespace(s, 1)
  if start > #s then
    return nil, "empty input"
  end
  local value, i = decodeValue(s, start, 0)
  if value == nil then
    return nil, i
  end
  i = skipWhitespace(s, i)
  if i <= #s then
    return nil, "trailing content at byte " .. i
  end
  return value
end

return M
