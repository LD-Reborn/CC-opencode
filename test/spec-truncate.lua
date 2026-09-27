-- truncate: keeping long tool output out of the context window.
--
-- Direction matters. File and search output is truncated from the head so the
-- first lines survive; shell output is truncated from the tail so the error at
-- the bottom of a build log survives. Either way the full text is written to
-- disk and the model is told where to find it.

return function(t, mock)
  local truncate = require("truncate")
  local env = require("environment")

  t.suite("truncate")

  t.eq(truncate.MAX_LINES, 2000, "the line limit matches opencode")
  t.eq(truncate.MAX_BYTES, 50 * 1024, "the byte limit matches opencode")

  local lines = function(n, prefix)
    local out = {}
    for index = 1, n do
      out[index] = (prefix or "line") .. index
    end
    return table.concat(out, "\n")
  end

  -- Short output is returned untouched, byte for byte.

  t.eq(truncate.output("hello"), "hello", "short output is passed through")
  t.eq(truncate.output(""), "", "empty output is passed through")
  t.eq(#truncate.output(lines(10)), #lines(10), "output under the limit is not rewritten")
  t.eq(#truncate.output(lines(10), { maxLines = 10, maxBytes = 4096 }), #lines(10), "output exactly at the limit is kept")
  t.eq(#truncate.output("a\nb\nc", { maxLines = 4, maxBytes = 4096 }), 5, "a trailing newline does not push a file over the line limit")

  -- Head direction: the first lines survive and the note points at the file.

  mock.setup()
  local long = lines(30)
  local head = truncate.output(long, { maxLines = 5, maxBytes = 4096 })
  t.contains(head, "line1\n", "the head keeps the first line")
  t.contains(head, "line5", "the head keeps the last line within the limit")
  t.ok(not head:find("line6", 1, true), "the head drops lines past the limit")
  t.contains(head, "5 lines truncated", "the head says how many lines went")
  t.contains(head, "Full output saved to:", "the head points at the saved file")
  t.contains(head, "opencode/tool-output", "the saved file is in the tool-output directory")
  t.ok(head:find("line1", 1, true) < head:find("Full output saved to:", 1, true), "the note comes after the preview in head direction")

  local files = {}
  env.walk(truncate.directory(), { onFile = function(path) files[#files + 1] = path end })
  t.eq(#files, 1, "the truncated output is written to exactly one file")
  t.eq(env.read(files[1]), long, "the saved file holds the complete, untruncated output")

  -- Tail direction: the last lines survive, and the note comes first.

  mock.setup()
  local tailed = truncate.output(long, { maxLines = 5, maxBytes = 4096, direction = "tail" })
  t.ok(not tailed:find("line1\n", 1, true), "the tail drops the early lines")
  t.contains(tailed, "line30", "the tail keeps the last line")
  t.contains(tailed, "line26", "the tail keeps the last five lines")
  t.ok(tailed:find("truncated", 1, true) < tailed:find("line26", 1, true), "the note comes before the preview in tail direction")
  t.contains(tailed, "25 lines truncated", "the tail says how many lines went")

  -- Byte limits bite before line limits when lines are long.

  mock.setup()
  local fat = string.rep("x", 300) .. "\n" .. string.rep("y", 300) .. "\n" .. string.rep("z", 300)
  local byBytes = truncate.output(fat, { maxLines = 100, maxBytes = 400 })
  t.contains(byBytes, "bytes truncated", "hitting the byte limit is reported in bytes")
  t.contains(byBytes, "Full output saved to:", "a byte-truncated result still points at the saved file")

  mock.setup()
  local tailedByBytes = truncate.output(fat, { maxLines = 100, maxBytes = 400, direction = "tail" })
  t.contains(tailedByBytes, "bytes truncated", "the tail reports a byte truncation in bytes")
  t.ok(not tailedByBytes:find("xxx", 1, true), "the tail drops the first line that does not fit")
  t.contains(tailedByBytes, "zzz", "the tail keeps the last line, which does fit")

  -- A single line over the byte limit must not produce an empty preview with no
  -- explanation.

  mock.setup()
  local oneBigLine = truncate.output(string.rep("q", 1000), { maxLines = 10, maxBytes = 100 })
  t.contains(oneBigLine, "truncated", "an over-long single line is still reported as truncated")
  t.contains(oneBigLine, "Full output saved to:", "an over-long single line still points at the saved file")

  -- When the full output cannot be written, the preview is all the model gets,
  -- and it must not claim otherwise.

  mock.setup()
  local realWrite = env.write
  env.write = function()
    return false
  end
  local unwritable = truncate.output(lines(50), { maxLines = 2, maxBytes = 4096 })
  env.write = realWrite
  t.contains(unwritable, "line2", "the preview survives when the full output cannot be saved")
  t.ok(not unwritable:find("Full output saved to:", 1, true), "a preview with no saved file does not claim there is one")

  -- The limits are configurable, which is how a smaller computer stays in budget.

  mock.setup()
  local configured = truncate.output(lines(50), { maxLines = 3, maxBytes = 4096 })
  t.contains(configured, "3 lines truncated", "a configured line limit is honoured")
end
