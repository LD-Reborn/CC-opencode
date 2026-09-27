-- Tool output truncation.
--
-- Mirrors opencode: output over the line or byte limit is written to
-- `opencode/tool-output/` and the model gets a preview plus a pointer to the full
-- text. Direction matters — shell output is a tail so the most recent lines stay
-- visible, everything else is a head.

local env = require("environment")
local util = require("util")

local M = {}

M.MAX_LINES = 2000
M.MAX_BYTES = 50 * 1024

function M.directory()
  return env.combine(env.cwd(), "opencode", "tool-output")
end

--- Write `text` to the truncation directory and return the file path.
function M.write(text)
  local path = env.combine(M.directory(), util.id("tool") .. ".txt")
  if not env.mkdirs(M.directory()) then
    return nil
  end
  if env.write(path, text) then
    return path
  end
  return nil
end

--- Keep the first `maxLines` lines / `maxBytes` bytes of `text`.
local function head(text, maxLines, maxBytes)
  local kept, bytes = {}, 0
  for index, line in ipairs(util.lines(text)) do
    if index > maxLines then
      return table.concat(kept, "\n"), index - 1, "lines"
    end
    local size = #line + 1
    if bytes + size > maxBytes then
      return table.concat(kept, "\n"), nil, "bytes"
    end
    bytes = bytes + size
    kept[#kept + 1] = line
  end
  return text, nil, nil
end

--- Keep the last `maxLines` lines / `maxBytes` bytes of `text`.
local function tail(text, maxLines, maxBytes)
  local lines = util.lines(text)
  local kept, bytes = {}, 0
  for index = #lines, 1, -1 do
    if #kept >= maxLines then
      return table.concat(kept, "\n"), index, "lines"
    end
    local size = #lines[index] + 1
    if bytes + size > maxBytes then
      return table.concat(kept, "\n"), nil, "bytes"
    end
    bytes = bytes + size
    table.insert(kept, 1, lines[index])
  end
  return text, nil, nil
end

--- Clamp `text` to the limits, saving the full output when it does not fit.
--
-- Returns `text` unchanged, or the preview followed by a note naming the file
-- that holds the complete output.
function M.output(text, options)
  options = options or {}
  local maxLines = options.maxLines or M.MAX_LINES
  local maxBytes = options.maxBytes or M.MAX_BYTES
  local direction = options.direction or "head"

  if #text <= maxBytes and #util.lines(text) <= maxLines + 1 then
    return text
  end

  -- A single `and ... or ...` expression would collapse to one value, so the
  -- branch is chosen first and the result is unpacked separately.
  local preview, removed, unit
  if direction == "tail" then
    preview, removed, unit = tail(text, maxLines, maxBytes)
  else
    preview, removed, unit = head(text, maxLines, maxBytes)
  end
  local path = M.write(text)
  if not path then
    return preview
  end

  local note = string.format(
    "The tool call succeeded but the output was truncated. Full output saved to: %s\nUse Grep to search the full content or Read with offset/limit to view specific sections.",
    path
  )
  if direction == "tail" then
    return string.format("...%s %s truncated...\n\n%s\n\n%s", removed or "many", unit or "lines", note, preview)
  end
  return string.format("%s\n\n...%s %s truncated...\n\n%s", preview, removed or "many", unit or "lines", note)
end

return M
