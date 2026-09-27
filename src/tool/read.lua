-- The `read` tool: file contents or a directory listing.

local env = require("environment")
local util = require("util")
local registry = require("tool/registry")

local DEFAULT_LIMIT = 2000
local MAX_LINE_LENGTH = 2000
local MAX_BYTES = 50 * 1024
local SAMPLE_BYTES = 4096

local DESCRIPTION = [[Read a file or directory from the filesystem. If the path does not exist, an error is returned.

Usage:
- The filePath parameter should be an absolute path. Relative paths resolve against
  the session working directory.
- By default, this tool returns up to 2000 lines from the start of the file.
- The offset parameter is the line number to start from (1-indexed).
- To read later sections, call this tool again with a larger offset.
- Use the grep tool to find specific content in large files or files with long lines.
- If you are unsure of the correct file path, use the glob tool to look up filenames.
- Contents are returned with each line prefixed by its line number as `<line>: <content>`.
  For example, a file containing "foo" returns "1: foo". For directories, entries are
  returned one per line, with a trailing `/` for subdirectories.
- Any line longer than 2000 characters is truncated.
- Read a larger window rather than many small slices; each call costs context.]]

local BINARY_EXTENSIONS = {
  zip = true, tar = true, gz = true, bz2 = true, xz = true, ["7z"] = true,
  exe = true, dll = true, so = true, class = true, jar = true, war = true,
  doc = true, docx = true, xls = true, xlsx = true, ppt = true, pptx = true,
  odt = true, ods = true, odp = true, bin = true, dat = true, obj = true,
  o = true, a = true, lib = true, wasm = true, pyc = true, pyo = true,
  png = true, jpg = true, jpeg = true, gif = true, webp = true, pdf = true,
  nbt = true, wav = true, ogg = true,
}

--- Extension-based first, then a content sample: a NUL byte or a high ratio of
--- non-printable bytes means we should not hand this to the model as text.
local function isBinary(path, sample)
  local extension = path:match("%.([%w]+)$")
  if extension and BINARY_EXTENSIONS[extension:lower()] then
    return true
  end
  if not sample or #sample == 0 then
    return false
  end
  if sample:find("\0", 1, true) then
    return true
  end
  local printable = 0
  for index = 1, #sample do
    local byte = sample:byte(index)
    if byte == 9 or byte == 10 or byte == 13 or (byte >= 32 and byte < 127) or byte >= 128 then
      printable = printable + 1
    end
  end
  return printable / #sample < 0.7
end

--- Suggest up to three sibling names that resemble the missing file's basename.
local function didYouMean(path)
  local directory = env.dirname(path)
  local base = env.basename(path)
  local suggestions = {}
  for _, name in ipairs(env.listDir(directory)) do
    if util.fuzzyContains(name, base) or util.fuzzyContains(base, name) then
      suggestions[#suggestions + 1] = env.combine(directory, name)
      if #suggestions == 3 then
        break
      end
    end
  end
  return suggestions
end

local function listDirectory(path, args)
  local names = env.listDir(path)
  local offset = math.max(1, tonumber(args.offset) or 1)
  local limit = tonumber(args.limit) or DEFAULT_LIMIT
  local start = offset - 1

  local entries = {}
  for index, name in ipairs(names) do
    if index > start and #entries < limit then
      local full = env.combine(path, name)
      entries[#entries + 1] = (env.isDir(full) and name .. "/" or name)
    end
  end

  local shown = #entries
  local more = start + shown < #names
  local footer = more
      and string.format(
        "\n(Showing %d of %d entries. Use 'offset' parameter to read beyond entry %d)",
        shown, #names, offset + shown
      )
    or string.format("\n(%d entries)", #names)

  return {
    title = path,
    metadata = { count = #names },
    output = table.concat({ "<path>" .. path .. "</path>", "<type>directory</type>", "<entries>",
      table.concat(entries, "\n"), footer, "</entries>" }, "\n"),
  }
end

registry.define({
  id = "read",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      filePath = { type = "string", description = "The path to the file or directory to read" },
      offset = { type = "number", description = "The line number to start reading from (1-indexed)" },
      limit = { type = "number", description = "The maximum number of lines to read (defaults to 2000)" },
    },
    required = { "filePath" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local path = env.resolve(args.filePath, ctx.cwd)
    if not util.startswith(path, ctx.root) then
      registry.guard(ctx, "external_directory", { path }, { path }, "reading outside " .. ctx.root)
    end
    registry.guard(ctx, "read", { path }, { path })

    if env.isDir(path) then
      return listDirectory(path, args)
    end
    if not env.exists(path) then
      local suggestions = didYouMean(path)
      if #suggestions > 0 then
        error(string.format("File not found: %s\n\nDid you mean one of these?\n%s", path, table.concat(suggestions, "\n")), 0)
      end
      error("File not found: " .. path, 0)
    end

    local content, cut = env.readLimited(path, MAX_BYTES)
    if isBinary(path, content:sub(1, SAMPLE_BYTES)) then
      error("Cannot read binary file: " .. path, 0)
    end

    local lines = util.lines(content)
    local count = #lines
    local offset = math.max(1, tonumber(args.offset) or 1)
    local limit = tonumber(args.limit) or DEFAULT_LIMIT

    if count < offset and not (count == 0 and offset == 1) then
      error(string.format("Offset %d is out of range for this file (%d lines)", offset, count), 0)
    end

    local body = {}
    local bytes = 0
    local index = offset
    while index <= count and #body < limit do
      local line = lines[index]
      if bytes + #line > MAX_BYTES then
        cut = true
        break
      end
      if #line > MAX_LINE_LENGTH then
        line = line:sub(1, MAX_LINE_LENGTH) .. string.format("... (line truncated to %d chars)", MAX_LINE_LENGTH)
      end
      bytes = bytes + #line
      body[#body + 1] = string.format("%d: %s", index, line)
      index = index + 1
    end

    local last = index - 1
    local footer
    if cut then
      footer = string.format(
        "\n\n(Output capped at %s. Showing lines %d-%d. Use offset=%d to continue.)",
        util.byteLabel(MAX_BYTES), offset, last, last + 1
      )
    elseif last < count then
      footer = string.format(
        "\n\n(Showing lines %d-%d of %d. Use offset=%d to continue.)",
        offset, last, count, last + 1
      )
    else
      footer = string.format("\n\n(End of file - total %d lines)", count)
    end

    return {
      title = path,
      metadata = { lines = count },
      output = string.format("<path>%s</path>\n<type>file</type>\n<content>\n%s%s\n</content>",
        path, table.concat(body, "\n"), footer),
    }
  end,
})

return true
