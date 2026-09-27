-- Pattern matching: glob patterns and a regex-to-Lua translator.
--
-- ComputerCraft has no regex engine, so grep needs a translation layer. The
-- supported subset covers what models actually send in practice: literals,
-- character classes, the standard escapes, quantifiers, groups, alternation, and
-- anchors. Lua patterns have no upper-bounded repeat, so `{n,m}` is expanded into
-- `n` mandatory copies plus `m-n` optional ones.

local M = {}

--- Convert a glob pattern to a Lua pattern. `**` spans directory boundaries.
function M.globToPattern(glob)
  local out = { "^" }
  local index = 1
  while index <= #glob do
    local char = glob:sub(index, index)
    if char == "*" then
      if glob:sub(index, index + 1) == "**" then
        index = index + 1
        if glob:sub(index + 1, index + 1) == "/" then
          -- "**/" spans any number of directories, including none. A lazy
          -- any-character run covers both, and the separator is consumed with
          -- it; Lua has no quantifier for a group, so ".-/" is not expressible.
          out[#out + 1] = ".-"
          index = index + 1
        else
          out[#out + 1] = ".*"
        end
      else
        out[#out + 1] = "[^/]*"
      end
    elseif char == "?" then
      out[#out + 1] = "[^/]"
    elseif char == "[" then
      local close = glob:find("]", index + 2, true)
      if close then
        local body = glob:sub(index + 1, close - 1)
        if body:sub(1, 1) == "!" then
          body = "^" .. body:sub(2)
        end
        out[#out + 1] = "[" .. body .. "]"
        index = close
      else
        out[#out + 1] = "%["
      end
    else
      out[#out + 1] = char:gsub("([%^%$%(%)%%%.%[%]%+%-%*%?])", "%%%1")
    end
    index = index + 1
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

--- True when a path matches a glob pattern, used by the include filters.
function M.matchesGlob(path, glob)
  return M.find({ M.globToPattern(glob) }, path) ~= nil
end

--- Regex character classes. Lua's `%w` is letters and digits only, so `\w` needs
--- the underscore spelled out to match what a model means by a word character.
local CLASSES = {
  d = "%d",
  D = "%D",
  w = "[%w_]",
  W = "[^%w_]",
  s = "%s",
  S = "%S",
  l = "%l",
  u = "%u",
  p = "%p",
  P = "%P",
}

local function escapeLiteral(char)
  return char:gsub("([%^%$%(%)%%%.%[%]%+%-%*%?])", "%%%1")
end

--- Read a `[...]` class starting at `i`, returning its text and the next index.
local function readClass(body, i)
  local close = body:find("]", i + 1, true)
  if not close then
    return nil, i + 1
  end
  local inner = body:sub(i + 1, close - 1)
  if inner:sub(1, 1) == "!" then
    inner = "^" .. inner:sub(2)
  end
  return "[" .. inner .. "]", close + 1
end

--- Read a `{...}` quantifier, returning the min/max counts and the next index.
local function readRepeat(body, i)
  local close = body:find("}", i, true)
  if not close then
    return nil, nil, i + 1
  end
  local inner = body:sub(i + 1, close - 1)
  local min, max = inner:match("^(%d*),(%d*)$")
  if not min then
    return nil, nil, i + 1
  end
  min = min == "" and 0 or tonumber(min)
  max = max == "" and math.huge or tonumber(max)
  if max < min then
    return nil, nil, i + 1
  end
  return min, max, close + 1
end

--- Expand an atom and a quantifier into plain Lua pattern fragments.
local function expand(atom, min, max)
  if min == 0 and max == math.huge then
    return atom .. "*"
  end
  if min == 1 and max == math.huge then
    return atom .. "+"
  end
  if min == 0 and max == 1 then
    return atom .. "?"
  end
  local out = {}
  for _ = 1, min do
    out[#out + 1] = atom
  end
  for _ = min + 1, math.min(max, min + 8) do
    out[#out + 1] = atom .. "?"
  end
  return table.concat(out)
end

--- True when `text` is a single translatable atom, i.e. something a Lua
--- quantifier can be attached to.
local function isSingleAtom(text)
  return #text == 1 or (text:sub(1, 1) == "[" and text:sub(-1) == "]")
end

--- Split a translated fragment into everything but its last atom and that atom
-- with any quantifier stripped, so a new quantifier can be attached to it.
local function splitLastAtom(text)
  local body = text
  while body ~= "" do
    local last = body:sub(-1)
    if last == "*" or last == "+" or last == "?" then
      body = body:sub(1, -2)
    else
      break
    end
  end
  if body:sub(-1) == "]" then
    local head = body:match("^(.*)%[")
    if head then
      return head, body:sub(#head + 1)
    end
  end
  if body:sub(-2, -2) == "%" then
    return body:sub(1, -3), body:sub(-2)
  end
  return body:sub(1, -2), body:sub(-1)
end

--- Apply a quantifier to a translated fragment, re-attaching it to the last atom
-- when the fragment is more than one atom long.
local function quantify(text, min, max)
  if min == 1 and max == 1 then
    return text
  end
  if isSingleAtom(text) then
    return expand(text, min, max)
  end
  local head, atom = splitLastAtom(text)
  return head .. expand(atom, min, max)
end

--- Index of the ')' that closes the group opened at `i`, or nil.
local function findCloseParen(body, i)
  local depth, inClass = 0, false
  local index = i
  while index <= #body do
    local char = body:sub(index, index)
    if char == "\\" then
      index = index + 2
    elseif inClass then
      if char == "]" then
        inClass = false
      end
      index = index + 1
    elseif char == "[" then
      inClass = true
      index = index + 1
    elseif char == "(" then
      depth = depth + 1
      index = index + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        return index
      end
      index = index + 1
    else
      index = index + 1
    end
  end
  return nil
end

--- Read a `(...)` group starting at `i`, returning its body and the next index.
--
-- Handles the group prefixes models emit: capturing, `?:`, `?<name>`, inline
-- flags, and lookaround, which is dropped along with its body because Lua has
-- no lookaround.
local function readGroup(body, i)
  local index = i + 1
  if body:sub(index, index) == "?" then
    local second = body:sub(index + 1, index + 1)
    if second == ":" then
      index = index + 2
    elseif second == "<" then
      local third = body:sub(index + 2, index + 2)
      if third == "=" or third == "!" then
        local close = findCloseParen(body, index + 2)
        return close and "" or nil, close and close + 1 or #body + 1
      end
      local close = body:find(">", index + 2, true)
      index = close and close + 1 or index + 2
    else
      -- Inline flags: "(?i)" drops the flag, "(?i:...)" keeps the body.
      local close = body:find(")", index + 1, true)
      local colon = body:find(":", index + 1, true)
      if close and (not colon or close < colon) then
        return "", close + 1
      end
      if colon then
        index = colon + 1
      else
        return "", #body + 1
      end
    end
  end

  local close = findCloseParen(body, i)
  if not close then
    return nil, #body + 1
  end
  return body:sub(index, close - 1), close + 1
end

--- Translate one alternative (no top-level `|`) into a Lua pattern.
--
-- Groups are transparent: their body is inlined. A quantifier after a group
-- attaches to the group's own text when that text is a single atom, which covers
-- the common `(\w+)` case, and to its last atom otherwise. Lua patterns cannot
-- repeat a group, so `(ab)+` is an approximation of `X+` for multi-character
-- groups.
local function translateBody(body)
  local out = {}
  local index = 1

  while index <= #body do
    local char = body:sub(index, index)
    local atom, nextIndex

    -- Anchors only mean anything at the very ends. Anywhere else they are
    -- literals, and a quantifier must never be attached to one. An anchor
    -- emits its character and leaves `atom` unset, so no quantifier is applied.
    if char == "^" and index == 1 then
      out[#out + 1] = "^"
      nextIndex = 2
    elseif char == "$" and index == #body then
      out[#out + 1] = "$"
      nextIndex = #body + 1
    elseif char == "\\" then
      local escape = body:sub(index + 1, index + 1)
      atom = CLASSES[escape] or ("%" .. escape)
      nextIndex = index + 2
    elseif char == "[" then
      local text, after = readClass(body, index)
      if not text then
        atom, nextIndex = "%[", index + 1
      else
        atom, nextIndex = text, after
      end
    elseif char == "(" then
      local inner, after = readGroup(body, index)
      if inner == nil then
        atom, nextIndex = "%(", index + 1
      else
        local min, max = 1, 1
        local quantifier = body:sub(after, after)
        if quantifier == "*" or quantifier == "+" or quantifier == "?" then
          min = quantifier == "+" and 1 or 0
          max = quantifier == "?" and 1 or math.huge
          after = after + 1
        elseif quantifier == "{" then
          local repeatMin, repeatMax, afterRepeat = readRepeat(body, after)
          if repeatMin then
            min, max = repeatMin, repeatMax
            after = afterRepeat
          end
        end
        out[#out + 1] = quantify(translateBody(inner), min, max)

        -- A trailing '?' makes the group's quantifier lazy, which Lua has no syntax for.
        if body:sub(after, after) == "?" then
          after = after + 1
        end
        nextIndex = after
      end
    elseif char == "." then
      atom, nextIndex = ".", index + 1
    elseif char == "{" then
      local min, max, after = readRepeat(body, index)
      if min then
        for _ = 1, math.min(min, 8) do
          out[#out + 1] = "."
        end
        nextIndex = after
        if max > min then
          out[#out + 1] = ".*"
        end
      else
        atom, nextIndex = "%{", index + 1
      end
    elseif char == ")" then
      atom, nextIndex = "%)", index + 1
    else
      atom, nextIndex = escapeLiteral(char), index + 1
    end

    if atom then
      -- No quantifier means exactly one occurrence, not one-or-more.
      local min, max = 1, 1
      local quantifier = body:sub(nextIndex, nextIndex)
      if quantifier == "*" or quantifier == "+" or quantifier == "?" then
        min = quantifier == "+" and 1 or 0
        max = quantifier == "?" and 1 or math.huge
        nextIndex = nextIndex + 1
      elseif quantifier == "{" then
        local repeatMin, repeatMax, after = readRepeat(body, nextIndex)
        if repeatMin then
          min, max = repeatMin, repeatMax
          nextIndex = after
        end
      end
      out[#out + 1] = expand(atom, min, max)

      -- A trailing '?' makes the quantifier lazy, which Lua has no syntax for.
      if body:sub(nextIndex, nextIndex) == "?" then
        nextIndex = nextIndex + 1
      end
    end

    index = nextIndex
  end

  return table.concat(out)
end

--- Split a regex on top-level `|`, ignoring separators inside groups or classes.
local function splitAlternatives(regex)
  local parts, current = {}, {}
  local depth, inClass = 0, false
  local index = 1
  while index <= #regex do
    local char = regex:sub(index, index)
    if char == "\\" then
      current[#current + 1] = char .. regex:sub(index + 1, index + 1)
      index = index + 2
    elseif char == "[" then
      inClass = true
      current[#current + 1] = char
      index = index + 1
    elseif char == "]" then
      inClass = false
      current[#current + 1] = char
      index = index + 1
    elseif char == "(" and not inClass then
      depth = depth + 1
      current[#current + 1] = char
      index = index + 1
    elseif char == ")" and not inClass then
      depth = depth - 1
      current[#current + 1] = char
      index = index + 1
    elseif char == "|" and not inClass and depth == 0 then
      parts[#parts + 1] = table.concat(current)
      current = {}
      index = index + 1
    else
      current[#current + 1] = char
      index = index + 1
    end
  end
  parts[#parts + 1] = table.concat(current)
  return parts
end

--- Compile a regex into a list of Lua patterns, one per top-level alternative,
--- anchored so a match means the whole alternative matched.
-- Invalid patterns are skipped rather than raised, so a bad regex still greps.
function M.compile(regex)
  local out = {}
  for _, alternative in ipairs(splitAlternatives(regex or "")) do
    local translated = translateBody(alternative)
    if translated:sub(1, 1) ~= "^" then
      translated = "^" .. translated
    end
    if translated:sub(-1) ~= "$" then
      translated = translated .. "$"
    end
    if pcall(string.find, "", translated) then
      out[#out + 1] = translated
    end
  end
  return out
end

--- Compile without adding anchors, for substring searches within a line. Anchors
--- the regex wrote itself are still honoured.
function M.compilePartial(regex)
  local out = {}
  for _, alternative in ipairs(splitAlternatives(regex or "")) do
    local translated = translateBody(alternative)
    if pcall(string.find, "", translated) then
      out[#out + 1] = translated
    end
  end
  return out
end

--- Locate a match, returning start and end byte offsets, or nil.
function M.find(patterns, subject)
  for _, pattern in ipairs(patterns) do
    local ok, start, finish = pcall(string.find, subject, pattern)
    if ok and start then
      return start, finish
    end
  end
  return nil
end

--- True when any pattern matches anywhere in `subject`.
function M.test(patterns, subject)
  return M.find(patterns, subject) ~= nil
end

return M
