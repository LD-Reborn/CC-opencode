-- The `edit` tool: exact string replacement.
--
-- Ports the replacer chain from opencode's edit tool. A model rarely produces a
-- byte-exact match because of indentation or line-ending drift, so the chain
-- widens the search progressively rather than failing on the first mismatch. Each
-- replacer yields candidate spans; a candidate is only accepted when it is unique
-- (unless replaceAll is set), which is what turns an ambiguous edit into an error
-- instead of a wrong write.

local env = require("environment")
local util = require("util")
local registry = require("tool/registry")

local DESCRIPTION = [[Performs exact string replacements in files.

Usage:
- You must have read the file at least once in this conversation before editing, so
  that the content you pass in matches what is really there.
- When copying text out of Read output, keep the exact indentation that appears after
  the `N: ` line-number prefix. Never include the prefix itself in oldString or
  newString.
- Prefer editing an existing file over rewriting it. Do not create new files unless
  explicitly required.
- The edit FAILS if oldString is not found, with "Could not find oldString in the file".
- The edit FAILS if oldString appears more than once, telling you to add surrounding
  context or to set replaceAll.
- Use replaceAll for renaming a symbol across a file.]]

--- Byte offsets of every occurrence of `search` in `content`.
local function occurrences(content, search)
  local positions = {}
  if search == "" then
    return positions
  end
  local from = 1
  while true do
    local start = content:find(search, from, true)
    if not start then
      return positions
    end
    positions[#positions + 1] = start
    from = start + 1
  end
end

--- Refuse a fuzzy match that would swallow much more of the file than was asked for.
local function isDisproportionate(search, oldString)
  local oldLines = #util.lines(oldString)
  local searchLines = #util.lines(search)
  if searchLines >= math.max(oldLines + 3, oldLines * 2) then
    return true
  end
  if oldLines == 1 then
    return false
  end
  return #util.trim(search) > math.max(#util.trim(oldString) + 500, #util.trim(oldString) * 4)
end

--- Spans where `needle`'s lines match `haystack`'s lines, comparing trimmed text.
-- Returns a list of `{ start, finish }` byte ranges into `haystack`.
local function matchByTrimmedLine(haystack, needle)
  local haystackLines = util.lines(haystack)
  local needleLines = util.lines(needle)
  local spans = {}
  if #needleLines == 0 or #haystackLines < #needleLines then
    return spans
  end

  local offsets, running = {}, 1
  for _, line in ipairs(haystackLines) do
    offsets[#offsets + 1] = running
    running = running + #line + 1
  end

  for index = 1, #haystackLines - #needleLines + 1 do
    local matched = true
    for offset = 1, #needleLines do
      if util.trim(haystackLines[index + offset - 1]) ~= util.trim(needleLines[offset]) then
        matched = false
        break
      end
    end
    if matched then
      local start = offsets[index]
      local last = index + #needleLines - 1
      local finish = offsets[last] + #haystackLines[last] - 1
      spans[#spans + 1] = { start = start, finish = finish }
    end
  end
  return spans
end

--- Collapse whitespace runs, returning the collapsed text and a map back to the original.
local function collapseWhitespace(text)
  local out, map = {}, {}
  local index, count = 1, 0
  while index <= #text do
    local char = text:sub(index, index)
    if char:match("%s") then
      while index <= #text and text:sub(index, index):match("%s") do
        index = index + 1
      end
      out[#out + 1] = " "
      count = count + 1
      map[count] = index - 1
    else
      out[#out + 1] = char
      count = count + 1
      map[count] = index
      index = index + 1
    end
  end
  return table.concat(out), map
end

local function stripIndent(text)
  local lines = util.lines(text)
  local shortest = nil
  for _, line in ipairs(lines) do
    local stripped = line:match("^%s*")
    if #line > #stripped and (not shortest or #stripped < #shortest) then
      shortest = #stripped
    end
  end
  if not shortest or shortest == 0 then
    return text
  end
  local out = {}
  for _, line in ipairs(lines) do
    out[#out + 1] = line:sub(math.min(shortest + 1, #line + 1))
  end
  return table.concat(out, "\n")
end

--- Candidate spans to try, in widening order of leniency.
local function candidates(content, oldString)
  local out = {}

  for _, position in ipairs(occurrences(content, oldString)) do
    out[#out + 1] = content:sub(position, position + #oldString - 1)
  end

  for _, span in ipairs(matchByTrimmedLine(content, oldString)) do
    out[#out + 1] = content:sub(span.start, span.finish)
  end

  local collapsedOld = stripIndent(oldString)
  if collapsedOld ~= oldString then
    for _, span in ipairs(matchByTrimmedLine(content, collapsedOld)) do
      out[#out + 1] = content:sub(span.start, span.finish)
    end
  end

  local collapsedContent, map = collapseWhitespace(content)
  local collapsedNeedle = collapseWhitespace(oldString)
  local at = collapsedContent:find(collapsedNeedle, 1, true)
  if at and at > 1 then
    local start = map[at] or 1
    local finish = map[at + #collapsedNeedle - 1] or #content
    if finish >= start then
      out[#out + 1] = content:sub(start, math.min(finish, #content))
    end
  end

  return out
end

--- Replace every occurrence of `search`, treating both sides as plain text.
local function gsubLiteral(content, search, replacement)
  local escaped = search:gsub("([^%w])", "%%%1")
  local out = content:gsub(escaped, function()
    return replacement
  end)
  return out
end

--- Apply the replacement, raising a model-readable message on ambiguity.
local function replace(content, oldString, newString, replaceAll)
  if oldString == newString then
    error("No changes to apply: oldString and newString are identical.", 0)
  end
  if util.trim(oldString) == "" then
    error(
      "oldString cannot be empty when editing an existing file. Provide the exact text to replace, or use write for an intentional full-file replacement.",
      0
    )
  end

  local found, ambiguous = false, false
  for _, search in ipairs(candidates(content, oldString)) do
    local positions = occurrences(content, search)
    if #positions > 0 then
      found = true
      if isDisproportionate(search, oldString) then
        error(
          "Refusing replacement because the matched span is much larger than oldString. Re-read the file and provide the full exact oldString for the intended replacement.",
          0
        )
      end
      if replaceAll then
        return gsubLiteral(content, search, newString)
      end
      if #positions == 1 then
        local start = positions[1]
        return content:sub(1, start - 1) .. newString .. content:sub(start + #search)
      end
      ambiguous = true
    end
  end

  if ambiguous then
    error("Found multiple matches for oldString. Provide more surrounding lines in oldString to identify the correct match.", 0)
  end
  error("Could not find oldString in the file. It must match exactly, including whitespace, indentation, and line endings.", 0)
end

registry.define({
  id = "edit",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      filePath = { type = "string", description = "The path of the file to modify" },
      oldString = { type = "string", description = "The text to replace" },
      newString = { type = "string", description = "The text to replace it with. Must differ from oldString." },
      replaceAll = { type = "boolean", description = "Replace every occurrence of oldString. Defaults to false." },
    },
    required = { "filePath", "oldString", "newString" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local path = env.resolve(args.filePath, ctx.cwd)
    local oldString, newString = args.oldString, args.newString
    if type(oldString) ~= "string" or type(newString) ~= "string" then
      error("The oldString and newString arguments are required and must be strings.", 0)
    end
    if oldString == newString then
      error("No changes to apply: oldString and newString are identical.", 0)
    end
    if env.isDir(path) then
      error("Path is a directory, not a file: " .. path, 0)
    end
    if not util.startswith(path, ctx.root) then
      registry.guard(ctx, "external_directory", { path }, { path }, "editing outside " .. ctx.root)
    end

    if not env.exists(path) then
      if util.trim(oldString) ~= "" then
        error("File " .. path .. " not found", 0)
      end
      registry.guard(ctx, "edit", { path }, { path }, "create " .. path)
      if not env.mkdirs(env.dirname(path)) then
        error("Could not create the directory " .. env.dirname(path), 0)
      end
      env.write(path, newString)
      return { title = "Created " .. path, metadata = { path = path, created = true },
        output = "Created file successfully: " .. path }
    end

    registry.guard(ctx, "edit", { path }, { path }, "edit " .. path)

    local content = env.read(path) or ""
    local bom = ""
    if content:sub(1, 3) == "\239\187\191" then
      bom = "\239\187\191"
      content = content:sub(4)
    end

    local ending = content:find("\r\n", 1, true) and "\r\n" or "\n"
    local normalize = function(text)
      return (text:gsub("\r\n", "\n"):gsub("\n", ending))
    end

    local updated = replace(content, normalize(oldString), normalize(newString), args.replaceAll and true or false)
    if not env.write(path, bom .. updated) then
      error("Could not write " .. path, 0)
    end

    return {
      title = "Edited " .. path,
      metadata = { path = path, created = false },
      output = "Edit applied successfully.",
    }
  end,
})

return true
