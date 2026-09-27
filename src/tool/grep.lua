-- The `grep` tool: search file contents.
--
-- CC has no regex engine, so patterns go through the translator in
-- `src/pattern.lua`, which supports the subset models normally send.

local env = require("environment")
local util = require("util")
local pattern = require("pattern")
local registry = require("tool/registry")

local LIMIT = 100
local SKIP_DIRECTORIES = {
  [".git"] = true, [".svn"] = true, ["node_modules"] = true, [".cache"] = true,
  ["opencode"] = true, [".Trash"] = true, ["__pycache__"] = true,
}

local DESCRIPTION = [[Fast content search that works with any codebase size.
- Searches file contents using a regular expression
- Filter which files are searched with the include parameter, e.g. "*.lua" or "*.md"
- Returns file paths with line numbers and the matching lines
- Use this when you need to find code containing a specific pattern
- Run several independent searches in one message rather than guessing a single
  broad pattern; each search is cheap compared to the context a full read would cost.]]

--- True when `path` should be searched, per the include filter.
local function included(path, includes)
  if not includes then
    return true
  end
  for _, include in ipairs(includes) do
    if pattern.matchesGlob(path, include) or pattern.matchesGlob(env.basename(path), include) then
      return true
    end
  end
  return false
end

--- Split a comma separated include filter into glob patterns.
local function parseIncludes(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local out = {}
  for piece in raw:gmatch("[^,]+") do
    local trimmed = util.trim(piece)
    if trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return #out > 0 and out or nil
end

registry.define({
  id = "grep",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "The regular expression to search for" },
      path = { type = "string", description = "The directory to search. Defaults to the session working directory." },
      include = { type = "string", description = "Comma separated glob patterns limiting which files are searched, e.g. \"*.lua\"" },
      limit = { type = "number", description = "Maximum number of matching lines to return. Defaults to 100." },
    },
    required = { "pattern" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local regex = args.pattern
    if type(regex) ~= "string" or regex == "" then
      error("The pattern argument is required.", 0)
    end
    local root = args.path and env.resolve(args.path, ctx.cwd) or ctx.cwd
    local limit = math.min(tonumber(args.limit) or LIMIT, LIMIT)
    local includes = parseIncludes(args.include)
    local compiled = pattern.compilePartial(regex)

    if #compiled == 0 then
      error("The pattern could not be compiled: " .. regex, 0)
    end

    local hits, total = {}, 0
    local truncated = false

    env.walk(root, {
      onDir = function(path)
        local name = env.basename(path)
        if name == ".git" or SKIP_DIRECTORIES[name] then
          return false
        end
        return true
      end,
      onFile = function(path)
        if truncated or not included(path, includes) then
          return
        end
        local content = env.readLimited(path, 512 * 1024)
        if not content then
          return
        end
        local matched = {}
        for number, line in ipairs(util.lines(content)) do
          if pattern.find(compiled, line) then
            total = total + 1
            if #hits < limit then
              matched[#matched + 1] = string.format("  Line %d: %s", number, util.trim(line))
            else
              truncated = true
            end
          end
        end
        if #matched > 0 then
          hits[#hits + 1] = { path = path, lines = matched }
        end
      end,
    })

    if #hits == 0 then
      return { title = regex, metadata = { count = 0 }, output = "No matches found" }
    end

    local blocks = {}
    for _, hit in ipairs(hits) do
      blocks[#blocks + 1] = hit.path .. ":\n" .. table.concat(hit.lines, "\n")
    end

    local header = truncated
        and string.format("Found %d matches (showing the first %d, more are available)", total, limit)
      or string.format("Found %d matches", total)
    local output = header .. "\n\n" .. table.concat(blocks, "\n\n")
    if truncated then
      output = output .. "\n\n(Results are truncated. Use a more specific pattern or path.)"
    end

    return { title = regex, metadata = { count = total }, output = output }
  end,
})

return true
