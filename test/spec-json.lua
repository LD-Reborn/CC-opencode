-- json: the encoder/decoder has to be exact, because it decides what bytes reach
-- the provider and what the doom-loop fingerprint compares.

return function(t)
  local json = require("json")

  t.suite("json")

  -- Encoding

  t.eq(json.encode(nil), "null", "nil encodes as null")
  t.eq(json.encode(json.null), "null", "the null sentinel encodes as null")
  t.eq(json.encode(true), "true", "booleans pass through")
  t.eq(json.encode(false), "false", "false is not dropped")
  t.eq(json.encode(42), "42", "integers stay integral")
  t.eq(json.encode(-7), "-7", "negative integers keep their sign")
  t.eq(json.encode(1.5), "1.5", "fractional numbers keep their fraction")
  t.eq(json.encode("hi"), '"hi"', "strings are quoted")
  t.eq(json.encode({}), "{}", "an empty table is an object")
  t.eq(json.encode(json.array({})), "[]", "a marked empty table is an array")
  t.eq(json.encode({ 1, 2, 3 }), "[1,2,3]", "sequential tables are arrays")
  t.eq(json.encode({ b = 1, a = 2 }), '{"a":2,"b":1}', "object keys are sorted")
  t.eq(json.encode({ [1] = "x", [3] = "z" }), '["x",null,"z"]', "a hole becomes null")

  t.eq(json.encode('a"b'), '"a\\"b"', "double quotes are escaped")
  t.eq(json.encode("a\\b"), '"a\\\\b"', "backslashes are escaped")
  t.eq(json.encode("a\nb"), '"a\\nb"', "newlines are escaped")
  t.eq(json.encode("a\tb"), '"a\\tb"', "tabs are escaped")
  t.eq(json.encode("\1"), '"\\u0001"', "control characters become unicode escapes")
  t.eq(json.encode("héllo"), '"héllo"', "utf-8 passes through unescaped")
  t.eq(json.encode({ list = { 1, 2 } }), '{"list":[1,2]}', "nested arrays survive")
  t.eq(json.encode({ list = {} }), '{"list":{}}', "a nested empty table is an object")

  -- Encoding is deterministic, which cache keys and loop detection depend on.
  local first = json.encode({ z = 1, m = 2, a = 3, alpha = 4, beta = 5 })
  for _ = 1, 20 do
    t.eq(json.encode({ alpha = 4, beta = 5, a = 3, m = 2, z = 1 }), first, "key order is stable across runs")
  end

  t.eq(json.encode({ a = 1 }, "  "), '{\n  "a": 1\n}', "pretty printing indents")
  t.eq(json.encode({ a = { 1 } }, "  "), '{\n  "a": [\n    1\n  ]\n}', "pretty printing nests")

  t.eq(json.encode(1 / 0), nil, "infinity is rejected rather than emitted")
  t.eq(json.encode(function() end), nil, "functions are rejected")
  t.eq(json.encode({ [1.5] = "x" }), '{"1.5":"x"}', "fractional keys are object keys")

  -- dropNulls

  t.eq(json.encode(json.dropNulls({ a = 1, b = json.null })), '{"a":1}', "dropNulls removes sentinel values")
  t.eq(json.encode(json.dropNulls({ a = { b = json.null, c = 2 } })), '{"a":{"c":2}}', "dropNulls recurses")

  -- isNull

  t.ok(json.isNull(json.decode("null")), "a decoded null is the sentinel")
  t.ok(not json.isNull(json.decode("0")), "zero is not null")
  t.ok(not json.isNull(json.decode("false")), "false is not null")
  t.ok(not json.isNull(json.decode('""')), "an empty string is not null")

  -- Decoding

  local function roundtrip(text, expected, message)
    t.eq(json.encode(json.decode(text)), expected, message)
  end

  roundtrip("null", "null", "null round-trips")
  roundtrip("true", "true", "true round-trips")
  roundtrip(" 42 ", "42", "surrounding whitespace is ignored")
  roundtrip('"hi"', '"hi"', "strings round-trip")
  roundtrip("[]", "[]", "an empty array decodes to an array")
  roundtrip("{}", "{}", "an empty object decodes to an object")
  roundtrip('{"a":1,"b":[1,2]}', '{"a":1,"b":[1,2]}', "structures round-trip")
  roundtrip('"\\u0041"', '"A"', "unicode escapes decode")
  roundtrip('"\\ud83d\\ude00"', '"😀"', "surrogate pairs decode to one character")
  roundtrip('"a\\/b"', '"a/b"', "escaped slashes decode")
  roundtrip('[1, 2,\n3]', "[1,2,3]", "whitespace inside arrays is ignored")

  local nested = json.decode('{"a":{"b":[{"c":"d"}]}}')
  t.eq(nested.a.b[1].c, "d", "deeply nested values are reachable")

  local empty = json.decode("[]")
  t.eq(#empty, 0, "an empty array has length 0")
  t.eq(json.encode(empty), "[]", "an empty array re-encodes as an array, not an object")

  t.ok(json.decode("{\"a\":\"b\"}"), "a value without json.null is truthy")
  -- A null field is kept, not dropped, which is what makes an assistant message
  -- with `content: null` survive a round trip.
  local withNull = json.decode('{"content":null,"role":"assistant"}')
  t.ok(json.isNull(withNull.content), "a null field keeps its key and value")
  t.eq(withNull.role, "assistant", "sibling fields are unaffected")
  t.eq(json.encode(withNull), '{"content":null,"role":"assistant"}', "a null field re-encodes as null")

  t.eq(json.decode("{"), nil, "an unterminated object fails")
  t.eq(json.decode("[1,"), nil, "an unterminated array fails")
  t.eq(json.decode('{"a" 1}'), nil, "a missing colon fails")
  t.eq(json.decode('{"a":1}extra'), nil, "trailing content fails")
  t.eq(json.decode(""), nil, "empty input fails")
  t.eq(json.decode("nonsense"), nil, "garbage fails")
  t.eq(json.decode(42), nil, "a non-string input fails")

  -- Numbers with exponents and fractions, which token counts arrive in.
  t.eq(json.decode("1e3"), 1000, "exponent notation decodes")
  t.eq(json.decode("-2.5"), -2.5, "negative fractions decode")
  t.eq(json.decode("1.0"), 1, "a trailing zero stays a number")
end
