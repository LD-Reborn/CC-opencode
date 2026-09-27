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
  local pulled = 0
  os.sleep = nil
  _G.os.startTimer = function(seconds)
    return { seconds = seconds }
  end
  _G.os.pullEvent = function()
    pulled = pulled + 1
    return "timer", pulled
  end
  local ok = pcall(util.sleep, 0.01)
  os.sleep = savedSleep
  t.ok(ok, "sleep works through the timer fallback")
  t.eq(pulled, 1, "the timer fallback pulls exactly one event")
end
