-- util: the small shared helpers. The wildcard matcher matters most, because
-- permission decisions are built on it.

return function(t)
  local util = require("util")

  t.suite("util")

  -- id

  local id = util.id("msg")
  t.ok(util.startswith(id, "msg_"), "ids carry their prefix")
  t.ok(util.id("msg") ~= util.id("msg"), "consecutive ids differ even within the same second")

  -- lines

  t.eq(#util.lines(""), 0, "an empty string has no lines")
  t.eq(#util.lines("a"), 1, "one line")
  t.eq(#util.lines("a\n"), 1, "a trailing newline does not add a line")
  t.eq(#util.lines("a\nb"), 2, "two lines")
  t.eq(#util.lines("a\nb\n"), 2, "a trailing newline is dropped")
  t.eq(#util.lines("\n"), 1, "a lone newline is one empty line")
  t.eq(util.lines("a\nb")[2], "b", "lines keep their order")
  t.eq(util.lines("a\r\nb")[1], "a\r", "carriage returns are not stripped")

  t.eq(util.join({ "a", "b" }), "a\nb", "join defaults to newlines")
  t.eq(util.join({ "a", "b" }, ", "), "a, b", "join takes a separator")

  -- trim / startswith / endswith

  t.eq(util.trim("  hi  "), "hi", "trim removes both ends")
  t.eq(util.trim("hi"), "hi", "trim leaves a clean string alone")
  t.eq(util.trim(""), "", "trim handles the empty string")
  t.ok(util.startswith("opencode/gpt-5", "opencode"), "startswith matches a prefix")
  t.ok(not util.startswith("gpt-5", "opencode"), "startswith rejects a non-prefix")
  t.ok(util.endswith("main.lua", ".lua"), "endswith matches a suffix")
  t.ok(util.endswith("main", ""), "an empty suffix always matches")
  t.ok(not util.endswith("main.lua", ".json"), "endswith rejects a non-suffix")

  -- wildcard, used by the permission ruleset

  t.ok(util.wildcard("anything", "*"), "* matches everything")
  t.ok(util.wildcard("ls -l", "ls *"), "a trailing * matches a prefix plus anything")
  t.ok(util.wildcard("ls", "ls *"), "a trailing * matches the bare name too")
  t.ok(util.wildcard("ls -la /dir", "ls *"), "a trailing * matches across the rest of the line")
  t.ok(util.wildcard("/root/.env", "*.env"), "a leading * matches a suffix")
  t.ok(util.wildcard("read", "read"), "an exact permission name matches itself")
  t.ok(not util.wildcard("ls -l", "ls"), "an exact pattern does not match longer values")
  t.ok(not util.wildcard("git status", "ls *"), "a different command does not match")
  t.ok(not util.wildcard("lsfoo", "ls *"), "the prefix must be followed by a space")
  t.ok(util.wildcard("ls", "ls*"), "a pattern without a space before * matches the bare name")
  t.ok(util.wildcard("file1.txt", "file?.txt"), "? matches exactly one character")
  t.ok(not util.wildcard("file12.txt", "file?.txt"), "? does not match two characters")
  t.ok(util.wildcard("foo+bar", "foo+bar"), "a plus is literal in a permission pattern")
  t.ok(util.wildcard("read", "read"), "an exact permission name matches itself")

  -- fuzzyContains, used for read's "did you mean"

  t.ok(util.fuzzyContains("config.lua", "config"), "a needle is found in a haystack")
  t.ok(util.fuzzyContains("config.lua", "CONFIG"), "matching ignores case")
  t.ok(not util.fuzzyContains("config.lua", "zzz"), "a missing needle is not found")

  -- copy / count

  local source = { a = 1, b = { c = 2 } }
  local copy = util.copy(source)
  t.eq(copy.a, 1, "copy carries values")
  t.eq(copy.b, source.b, "copy is shallow, as intended")
  t.eq(util.count({ a = 1, b = 2 }), 2, "count counts entries")
  t.eq(util.count({}), 0, "count of an empty table is 0")

  -- byteLabel, quoted in the read tool's truncation footer

  t.eq(util.byteLabel(50 * 1024), "50 KB", "kilobytes are labelled")
  t.eq(util.byteLabel(2 * 1024 * 1024), "2 MB", "megabytes are labelled")
  t.eq(util.byteLabel(7), "7 bytes", "odd byte counts are labelled in bytes")

  -- sleep falls back to a timer when os.sleep is absent (ComputerCraft).

  local savedSleep = os.sleep
  local savedPull = os.pullEvent
  local pulled = 0
  os.sleep = nil
  _G.os.startTimer = function(seconds)
    return { seconds = seconds }
  end
  -- Replaced rather than deleted, because the mock's own `pullEvent` answers a timer
  -- on an empty queue and this stub answers one unconditionally: a test that leaked
  -- it would leave every later suite's key loop spinning on timers forever, and the
  -- suite it broke would not be the one that leaked.
  _G.os.pullEvent = function()
    pulled = pulled + 1
    return "timer", pulled
  end
  local ok = pcall(util.sleep, 0.01)
  os.sleep = savedSleep
  os.pullEvent = savedPull
  t.ok(ok, "sleep works through the timer fallback")
  t.eq(pulled, 1, "the timer fallback pulls exactly one event")

  -- wrap
  --
  -- ComputerCraft discards anything written past the right edge rather than
  -- continuing it on the next row, so this is what stands between a long error
  -- message and the half of it that never reaches the screen.

  t.eq(#util.wrap("hi", 51), 1, "a short line is one line")
  t.eq(util.wrap("hi", 51)[1], "hi", "and is unchanged")
  t.eq(#util.wrap("", 51), 1, "an empty string is still one line, so the newline is not lost")
  t.eq(util.wrap("a\nb", 51)[2], "b", "an embedded newline is respected")
  t.eq(util.wrap("a\nb", 51)[1], "a", "on both sides")
  t.eq(#util.wrap("a\n\nb", 51), 3, "a blank line survives as a blank line")
  t.eq(#util.wrap("a\nb", 51), 2, "text without a trailing newline is not dropped")

  local long = "the server's http allowlist does not permit git.example"
  local wrapped = util.wrap(long, 20)
  t.ok(#wrapped > 1, "a long line is broken up")
  for _, part in ipairs(wrapped) do
    t.ok(#part <= 20, "every piece fits the width: " .. part)
  end
  t.eq(table.concat(wrapped, " "), long, "and nothing is lost or added")

  t.eq(util.wrap("one two three four", 9)[1], "one two", "it breaks at a space near the margin")
  t.eq(util.wrap("one two three four", 9)[2], "three", "not at the first one, which would leave a scrap")

  t.eq(util.wrap("abcdefghij", 8)[1], "abcdefgh", "a word with no spaces fills the line")
  t.eq(util.wrap("abcdefghij", 8)[2], "ij", "and the pieces are all there")
  t.eq(#util.wrap("abcdefghij", 8), 2, "two pieces, rather than a third empty one")

  -- A space in the first half is not worth breaking on, or the first line would
  -- be one character long.
  t.eq(util.wrap("a bcdefghijklmnopqrst", 10)[1], "a bcdefghi", "an early space is ignored in favour of progress")

  t.eq(#util.wrap("x", 0), 1, "a nonsensical width does not loop forever")
  t.eq(#util.wrap("x", nil), 1, "a missing width falls back to a default")
  t.eq(#util.wrap("x", -5), 1, "a negative width is clamped")
  t.eq(#util.wrap(nil, 20), 1, "nil text is one empty line rather than an error")
  t.eq(#util.wrap(42, 20), 1, "a number is stringified")
end
