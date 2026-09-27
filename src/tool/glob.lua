-- The `glob` tool: find files by name pattern.

local env = require("environment")
local util = require("util")
local pattern = require("pattern")
local registry = require("tool/registry")

local LIMIT = 100

local DESCRIPTION = [[Fast file pattern matching that works with any codebase size.
- Supports glob patterns such as "**/*.lua" or "/src/**/*.ts"
- Returns matching file paths
- Use this when you need to find files by name
- Issue several speculative glob calls in one message when you are unsure of the
  layout; each is cheap compared to the context a full listing would cost.]]

registry.define({
  id = "glob",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "The glob pattern to match against file paths" },
      path = { type = "string", description = "The directory to search. Defaults to the session working directory." },
      limit = { type = "number", description = "Maximum number of results. Defaults to 100." },
    },
    required = { "pattern" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local glob = args.pattern
    if type(glob) ~= "string" or glob == "" then
      error("The pattern argument is required.", 0)
    end
    local root = args.path and env.resolve(args.path, ctx.cwd) or ctx.cwd
    local limit = math.min(tonumber(args.limit) or LIMIT, LIMIT)

    local compiled = pattern.globToPattern(util.startswith(glob, "/") and glob:sub(2) or glob)
    local matches = {}
    local total = 0

    env.walk(root, {
      onFile = function(path)
        local relative = path:sub(#root + 1)
        relative = util.startswith(relative, "/") and relative:sub(2) or relative
        if pattern.find({ compiled }, relative) then
          total = total + 1
          if #matches < limit then
            matches[#matches + 1] = path
          end
        end
      end,
    })

    table.sort(matches)
    if #matches == 0 then
      return { title = glob, metadata = { count = 0 }, output = "No files found" }
    end

    local output = table.concat(matches, "\n")
    if total > limit then
      output = output
        .. string.format(
          "\n\n(Results are truncated: showing the first %d of %d results. Use a more specific path or pattern.)",
          limit, total
        )
    end

    return { title = glob, metadata = { count = total }, output = output }
  end,
})

return true
