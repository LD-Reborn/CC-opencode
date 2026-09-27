-- Small helpers shared across CC-opencode modules.

local M = {}

local sequence = 0

--- Monotonic, human-readable id with a prefix, e.g. "msg_3f2a1b".
function M.id(prefix)
  sequence = sequence + 1
  return string.format("%s_%06x", prefix, os.time() * 4096 + sequence)
end

--- Split a string on newlines, keeping no trailing empty field for a final newline.
function M.lines(s)
  local out = {}
  if not s or s == "" then
    return out
  end
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  return out
end

function M.join(lines, separator)
  return table.concat(lines, separator or "\n")
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.startswith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.endswith(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

--- Translate a shell glob to a Lua pattern: `*` is "anything", `?` is one character.
local function globToPattern(glob)
  return (glob:gsub("([%^%$%(%)%%%.%[%]%+%-%?%*])", function(char)
    if char == "*" then
      return ".*"
    end
    if char == "?" then
      return "."
    end
    return "%" .. char
  end))
end

--- Wildcard match for permission patterns, ported from opencode's `Wildcard.match`.
--
-- A pattern that ends in " *" matches both the bare command and the command with
-- arguments, so `"ls *"` allows `ls`, `ls -la`, and `ls foo bar` but not
-- `lstmeval`. Everywhere else `*` is plain "anything", which is why `"ls*"`
-- deliberately also matches `lstmeval`.
function M.wildcard(value, pattern)
  if pattern == "*" then
    return true
  end
  value = value:gsub("\\", "/")
  pattern = pattern:gsub("\\", "/")

  if string.find(value, "^" .. globToPattern(pattern) .. "$") then
    return true
  end

  -- A pattern ending in " *" also matches the command with no arguments at all,
  -- so "ls *" allows "ls" as well as "ls -la".
  if M.endswith(pattern, " *") then
    return string.find(value, "^" .. globToPattern(pattern:sub(1, -3)) .. "$") ~= nil
  end
  return false
end

--- Case-insensitive "does one string contain the other", used for read's did-you-mean.
function M.fuzzyContains(a, b)
  return a:lower():find(b:lower(), 1, true) ~= nil
end

function M.copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

--- Recursive copy. Config loading merges into a copy of the defaults, so a
--- shallow copy would let one loaded config rewrite the defaults for every later
--- load in the same process.
function M.deepCopy(t)
  if type(t) ~= "table" then
    return t
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = M.deepCopy(v)
  end
  return out
end

--- Count entries in a table without #, which is undefined for sparse arrays.
function M.count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

--- Yield to the ComputerCraft event loop for `seconds`, keeping the terminal responsive.
function M.sleep(seconds)
  if os.sleep then
    return os.sleep(seconds)
  end
  -- Newer CC builds expose os.sleep; on the rest, block on our own timer.
  os.pullEvent("timer", os.startTimer(seconds))
end

--- #s characters starting at `i` (1-indexed).
function M.substr(s, i, length)
  return string.sub(s, i, i + (length or 1) - 1)
end

--- Human readable byte count, e.g. 51200 -> "50 KB".
function M.byteLabel(bytes)
  if bytes % (1024 * 1024) == 0 then
    return string.format("%d MB", bytes / (1024 * 1024))
  end
  if bytes % 1024 == 0 then
    return string.format("%d KB", bytes / 1024)
  end
  return string.format("%d bytes", bytes)
end

--- Break text into lines no wider than `width`, preferring to break at a space.
--
-- ComputerCraft's `write` does not wrap: anything past the right edge is not
-- merely ugly, it is discarded, and the rest of the line does not appear on the
-- next row. A computer's terminal is 51 columns, which is narrower than a url
-- and narrower than most error messages, so without this the interesting end of
-- a long line is exactly the part that never arrives.
--
-- A hard cut is the fallback rather than the rule. Most messages have a space
-- near the margin, and breaking there keeps the first line readable instead of
-- ending it mid-word.
function M.wrap(text, width)
  width = math.max(8, math.floor(tonumber(width) or 51))
  local lines = {}
  -- The trailing newline guarantees the last paragraph is seen, so text without
  -- one is not silently dropped.
  for paragraph in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local rest = paragraph
      while #rest > width do
        -- The last space at or before the margin. `.*` is greedy, so this finds
        -- the last one rather than the first.
        local space = rest:sub(1, width + 1):match("^.*()%s")
        local take
        if space and space >= math.floor(width / 2) then
          take = space - 1 -- stop before the space, and let the next line have it
        else
          -- No space, or one so early that breaking there would leave a scrap of
          -- a line. Either way, fill this one and keep the progress.
          take = width
        end
        lines[#lines + 1] = rest:sub(1, take)
        rest = (rest:sub(take + 1):gsub("^%s+", ""))
      end
      lines[#lines + 1] = rest
    end
  end
  return lines
end

return M
