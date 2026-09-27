-- pattern: glob translation and the regex-to-Lua translator grep depends on.

return function(t)
  local pattern = require("pattern")

  t.suite("pattern")

  local function matches(glob, path)
    return pattern.matchesGlob(path, glob)
  end

  -- Globs

  t.ok(matches("*.lua", "main.lua"), "* matches within one segment")
  t.ok(not matches("*.lua", "src/main.lua"), "* does not cross a separator")
  t.ok(not matches("*.lua", "a/b/main.lua"), "* does not cross a separator")
  t.ok(matches("**/*.lua", "a/b/main.lua"), "** crosses separators")
  t.ok(matches("**/*.lua", "main.lua"), "** also matches zero directories")
  t.ok(matches("src/**/*.ts", "src/deep/nested/a.ts"), "** works mid-pattern")
  t.ok(matches("a?c", "abc"), "? matches one character")
  t.ok(not matches("a?c", "ac"), "? requires a character")
  t.ok(matches("[abc]x", "bx"), "a character class matches its members")
  t.ok(not matches("[abc]x", "dx"), "a character class rejects others")
  t.ok(matches("[!abc]x", "dx"), "a negated class inverts")
  t.ok(matches("a.b", "a.b"), "a dot is literal, not any-character")
  t.ok(not matches("a.b", "axb"), "a dot does not match an arbitrary character")
  t.ok(matches("a+b", "a+b"), "a plus is literal in a glob")
  t.ok(matches("a(b)", "a(b)"), "parentheses are literal in a glob")
  t.ok(matches("*.{lua,txt}", "*.{lua,txt}"), "braces are literal in a glob")

  -- Regex translation, anchored.

  local function anchored(regex, subject)
    return pattern.test(pattern.compile(regex), subject)
  end

  t.ok(anchored("foo", "foo"), "a literal matches")
  t.ok(not anchored("foo", "foobar"), "an anchored literal does not match a longer string")
  t.ok(anchored("foo.*", "foobar"), ".* extends a match")
  t.ok(anchored("f.o", "foo"), ". matches any character")
  t.ok(anchored("^foo$", "foo"), "explicit anchors are honoured")
  t.ok(anchored("fo+", "fooo"), "+ is one or more")
  t.ok(not anchored("fo+", "f"), "+ requires at least one")
  t.ok(anchored("fo?", "f"), "? is zero or one")
  t.ok(anchored("fo?", "fo"), "? allows one")
  t.ok(anchored("a|b", "b"), "alternation is supported")
  t.ok(not anchored("a|b", "c"), "alternation does not match other text")
  t.ok(anchored("[a-c]x", "bx"), "character ranges work")
  t.ok(anchored("a{2,3}", "aa"), "{n,m} matches n copies")
  t.ok(anchored("a{2,3}", "aaa"), "{n,m} matches up to m")
  t.ok(not anchored("a{2,3}", "a"), "{n,m} enforces the lower bound")
  t.ok(not anchored("a{2,3}", "aaaa"), "{n,m} enforces the upper bound")
  t.ok(anchored("[[]literal]", "[literal]"), "an escaped bracket is literal")
  t.ok(anchored("a\\.b", "a.b"), "an escaped dot is literal")
  t.ok(not anchored("a\\.b", "axb"), "an escaped dot does not match any character")
  t.ok(anchored("\\(a\\)b", "(a)b"), "escaped parens are literal")
  t.ok(anchored("(?<name>foo)", "foo"), "a named group is dropped, not matched literally")
  t.ok(type(pattern.compilePartial("(?<name>foo)")[1]) == "string", "a named group is transparent")
  t.ok(anchored("(\\w+)@(\\w+)", "me@host"), "two groups inline correctly")
  t.ok(not anchored("(\\w+)@(\\w+)", "me host"), "two groups still require the literal between them")
  t.ok(anchored("(?i)abc", "abc"), "an inline flag group is dropped")
  t.ok(#pattern.compile("(?=foo)") > 0, "a lookahead does not break compilation")
  t.ok(type(pattern.compile("(?:")) == "table", "an unclosed group does not raise")
  t.ok(anchored("\\d+", "42"), "digit classes translate")
  t.ok(not anchored("\\d+", "abc"), "digit classes reject letters")
  t.ok(anchored("\\w+", "a_1"), "word classes translate")
  t.ok(not anchored("\\w+", "a-1"), "word classes reject punctuation")
  t.ok(anchored("\\s", " "), "whitespace classes translate")
  t.ok(anchored("\\.", "."), "an escaped non-class character is a literal")
  t.ok(anchored("a.*?b", "axxb"), "a lazy quantifier still matches")

  -- Partial translation, which grep uses for substring search within a line.

  local function partial(regex, subject)
    return pattern.test(pattern.compilePartial(regex), subject)
  end

  t.ok(partial("foo", "a foo b"), "a partial match is found mid-line")
  t.ok(partial("^foo", "foo bar"), "a leading anchor is preserved when compiling partially")
  t.ok(not partial("^foo", "a foo b"), "a leading anchor still anchors")
  t.ok(partial("o+$", "hello"), "a trailing anchor is preserved")
  t.ok(not partial("o+$", "hello world"), "a trailing anchor still anchors")
  t.ok(partial("a.c", "xxabcxx"), "a dot matches inside a partial search")

  -- find returns offsets so callers can slice.

  local start, finish = pattern.find(pattern.compilePartial("b.*d"), "abcde")
  t.eq(start, 2, "find reports the start offset")
  t.eq(finish, 4, "find reports the end offset")
  t.eq(pattern.find(pattern.compile("zzz"), "abcde"), nil, "find reports no match as nil")

  -- compile never raises on a bad pattern, so one bad regex cannot break grep.

  t.ok(type(pattern.compile("[unclosed")) == "table", "an unclosed class does not raise")
  t.ok(type(pattern.compile("")) == "table", "an empty regex returns a table")
  t.eq(pattern.find(pattern.compile(""), "anything"), nil, "an empty regex matches nothing")
  t.eq(pattern.find({}, "anything"), nil, "an empty pattern list matches nothing")
end
