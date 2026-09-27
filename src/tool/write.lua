-- The `write` tool: create or overwrite a file.

local env = require("environment")
local util = require("util")
local registry = require("tool/registry")

local DESCRIPTION = [[Writes a file to the filesystem.

Usage:
- This tool overwrites the existing file at the provided path.
- Prefer editing an existing file over rewriting it; use the Edit tool for changes
  to part of a file.
- Parent directories are created automatically.
- Do not proactively create documentation files (*.md) or README files. Only create
  documentation when explicitly requested.
- Only use emojis if the user explicitly requests it.
- Text files are written as UTF-8 with \n line endings. A byte order mark already
  present in the file is preserved.]]

registry.define({
  id = "write",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      filePath = { type = "string", description = "The path of the file to write" },
      content = { type = "string", description = "The content to write to the file" },
    },
    required = { "filePath", "content" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local path = env.resolve(args.filePath, ctx.cwd)
    local content = args.content
    if type(content) ~= "string" then
      error("The content argument is required and must be a string.", 0)
    end
    if env.isDir(path) then
      error("Path is a directory, not a file: " .. path, 0)
    end
    if not util.startswith(path, ctx.root) then
      registry.guard(ctx, "external_directory", { path }, { path }, "writing outside " .. ctx.root)
    end
    registry.guard(ctx, "edit", { path }, { path }, "write " .. path)

    local existed = env.exists(path)
    local bom = ""
    if existed then
      local existing = env.readLimited(path, 3) or ""
      if existing:sub(1, 3) == "\239\187\191" then
        bom = "\239\187\191"
      end
    end

    if not env.mkdirs(env.dirname(path)) then
      error("Could not create the directory " .. env.dirname(path), 0)
    end
    if not env.write(path, bom .. content) then
      error("Could not write " .. path, 0)
    end

    local action = existed and "Updated" or "Created"
    return {
      title = action .. " " .. path,
      metadata = { path = path, created = not existed },
      output = string.format("%s file successfully: %s (%d bytes)", action, path, #bom + #content),
    }
  end,
})

return true
