-- The built-in tools.
--
-- Each tool is exercised through the registry, because that is the path the
-- agent loop takes: permission checks, error capture into a structured result,
-- and output limits all live there rather than in the tool itself.

return function(t, mock)
  local registry = require("tool/registry")
  local env = require("environment")
  local session = require("session")

  t.suite("tools")

  registry.load()

  -- Every tool is registered exactly once, with a schema the provider accepts.

  local ids = registry.ids()
  local expected = { "bash", "read", "write", "edit", "glob", "grep", "webfetch", "todowrite" }
  t.eq(#ids, #expected, "all eight built-in tools are registered")
  local seen = {}
  for _, id in ipairs(ids) do
    t.eq(seen[id], nil, "tool '" .. id .. "' is not registered twice")
    seen[id] = true
  end
  for _, id in ipairs(expected) do
    t.ok(seen[id], "tool '" .. id .. "' is registered")
  end

  for _, id in ipairs(expected) do
    local tool = registry.get(id)
    t.eq(tool.parameters.type, "object", id .. " declares an object schema")
    t.ok(#tool.description > 80, id .. " has a description worth sending to the model")
    t.ok(type(tool.parameters.properties) == "table", id .. " documents its arguments")
    t.eq(tool.parameters.additionalProperties, false, id .. " refuses unexpected arguments")
  end

  local wire = registry.toWire(registry.get("read"))
  t.eq(wire.type, "function", "a tool is sent as an OpenAI function")
  t.eq(wire["function"].name, "read", "the function name is the tool id")
  t.ok(wire["function"].parameters ~= nil, "the schema travels with the function")

  t.eq(#registry.ids({ read = false }), #expected - 1, "a disabled tool is left out")
  t.eq(#registry.ids({ read = false, bash = false }), #expected - 2, "several tools can be disabled at once")
  t.eq(#registry.ids({}), #expected, "an empty toggle table disables nothing")

  t.eq(registry.get("nope"), nil, "an unknown tool id resolves to nothing")
  t.contains(registry.execute("nope", {}, mock.context()).error, "Unknown tool 'nope'", "an unknown tool is an error the model can read")
  t.contains(registry.execute("nope", {}, mock.context()).error, "read", "the error lists the tools that do exist")

  local function ctx(options)
    return mock.context(options)
  end

  local function file(path, content)
    env.mkdirs(env.dirname(path))
    env.write(path, content)
    return path
  end

  -- read

  mock.setup()
  local target = file(mock.root .. "/notes.txt", "alpha\nbeta\ngamma\n")
  local read = registry.execute("read", { filePath = target }, ctx())
  t.eq(read.status, "completed", "reading an existing file succeeds")
  t.contains(read.output, "1: alpha", "lines are numbered from one")
  t.contains(read.output, "3: gamma", "every line is returned")
  t.contains(read.output, "(End of file - total 3 lines)", "the end of a short file is announced")
  t.contains(read.output, "<type>file</type>", "the output is tagged so the model can tell what it got")
  t.eq(read.metadata.lines, 3, "the line count is reported as metadata")

  t.contains(registry.execute("read", { filePath = target, offset = 2 }, ctx()).output, "2: beta", "offset skips to a line")
  t.contains(registry.execute("read", { filePath = target, limit = 1 }, ctx()).output, "(Showing lines 1-1 of 3", "a limited read says where to continue")
  t.contains(registry.execute("read", { filePath = target, limit = 1 }, ctx()).output, "offset=2", "a limited read names the next offset")
  t.contains(registry.execute("read", { filePath = target, offset = 99 }, ctx()).error, "out of range", "an offset past the end is an error")

  t.contains(registry.execute("read", { filePath = mock.root .. "/notes" }, ctx()).error, "File not found: ", "a missing file is reported plainly")
  t.contains(registry.execute("read", { filePath = mock.root .. "/notes" }, ctx()).error, "Did you mean", "a name that is a prefix of a real file is suggested")
  t.contains(registry.execute("read", { filePath = mock.root .. "/notes" }, ctx()).error, "notes.txt", "the suggestion is the real filename")
  t.contains(registry.execute("read", { filePath = mock.root .. "/absent" }, ctx()).error, "File not found: ", "an unguessable name gets a plain error with no suggestions")

  local listed = registry.execute("read", { filePath = mock.root }, ctx())
  t.contains(listed.output, "<type>directory</type>", "a directory is listed rather than read")
  t.contains(listed.output, "notes.txt", "the listing includes the files")
  t.contains(listed.output, "(1 entries)", "the listing reports the entry count")

  env.mkdirs(mock.root .. "/sub")
  local nested = registry.execute("read", { filePath = mock.root }, ctx())
  t.contains(nested.output, "sub/", "a subdirectory is marked with a trailing slash")
  t.contains(nested.output, "(2 entries)", "subdirectories count towards the total")
  t.contains(registry.execute("read", { filePath = mock.root, limit = 1 }, ctx()).output, "Showing 1 of 2", "a limited listing says how much is left")

  file(mock.root .. "/binary.dat", "\0\1\2\3\4\5\6\7")
  t.contains(registry.execute("read", { filePath = mock.root .. "/binary.dat" }, ctx()).error, "Cannot read binary file", "a NUL byte means binary")
  file(mock.root .. "/image.png", "not really a png")
  t.contains(registry.execute("read", { filePath = mock.root .. "/image.png" }, ctx()).error, "Cannot read binary file", "a known binary extension means binary")

  file(mock.root .. "/long.txt", string.rep("z", 5000) .. "\nshort\n")
  t.contains(registry.execute("read", { filePath = mock.root .. "/long.txt" }, ctx()).output, "(line truncated to 2000 chars)", "an over-long line is cut rather than dropped")

  t.contains(registry.execute("read", { filePath = "../escape.txt" }, ctx()).error, "external_directory", "a path outside the root is refused")

  -- write

  mock.setup()
  local created = registry.execute("write", { filePath = mock.root .. "/a/b/c.txt", content = "hello" }, ctx())
  t.eq(created.status, "completed", "writing a new file succeeds")
  t.eq(env.read(mock.root .. "/a/b/c.txt"), "hello", "the content lands on disk")
  t.contains(created.output, "Created file successfully", "a new file is reported as created")
  t.eq(created.metadata.created, true, "the metadata records that it was new")
  t.contains(registry.execute("write", { filePath = mock.root .. "/a/b/c.txt", content = "again" }, ctx()).output, "Updated", "overwriting an existing file is reported as an update")
  t.eq(env.read(mock.root .. "/a/b/c.txt"), "again", "the overwrite really happened")
  t.contains(registry.execute("write", { filePath = mock.root, content = "x" }, ctx()).error, "Path is a directory, not a file", "writing over a directory is an error")
  t.contains(registry.execute("write", { filePath = mock.root .. "/x.txt" }, ctx()).error, "must be a string", "content is required")

  file(mock.root .. "/bom.txt", "\239\187\191with bom")
  registry.execute("write", { filePath = mock.root .. "/bom.txt", content = "no bom" }, ctx())
  t.eq(env.read(mock.root .. "/bom.txt"), "\239\187\191no bom", "an existing byte order mark is preserved")
  t.eq(env.read(mock.root .. "/a/b/c.txt"), "again", "a file written before the bom write is untouched")

  -- edit

  mock.setup()
  local source = file(mock.root .. "/src.lua", "local a = 1\nlocal b = 2\nlocal a = 3\n")
  local edited = registry.execute("edit", { filePath = source, oldString = "local a = 1", newString = "local a = 9" }, ctx())
  t.eq(edited.status, "completed", "an exact match is replaced")
  t.eq(env.read(source), "local a = 9\nlocal b = 2\nlocal a = 3\n", "only the matched span changes")
  t.eq(edited.metadata.created, false, "editing an existing file is not a creation")

  local ambiguous = registry.execute("edit", { filePath = source, oldString = "local a =", newString = "local c =" }, ctx())
  t.eq(ambiguous.status, "error", "an ambiguous edit fails instead of guessing")
  t.contains(ambiguous.error, "Found multiple matches", "an ambiguous edit says there were several matches")
  t.eq(env.read(source), "local a = 9\nlocal b = 2\nlocal a = 3\n", "a failed edit leaves the file alone")

  t.eq(registry.execute("edit", { filePath = source, oldString = "local a =", newString = "local c =", replaceAll = true }, ctx()).status, "completed", "replaceAll resolves the ambiguity")
  t.eq(env.read(source), "local c = 9\nlocal b = 2\nlocal c = 3\n", "every occurrence is replaced")

  t.contains(registry.execute("edit", { filePath = source, oldString = "nowhere", newString = "x" }, ctx()).error, "Could not find oldString", "a missing match is an error")
  t.contains(registry.execute("edit", { filePath = source, oldString = "local b = 2", newString = "local b = 2" }, ctx()).error, "No changes to apply", "an identical replacement is refused")
  t.contains(registry.execute("edit", { filePath = source, oldString = "", newString = "x" }, ctx()).error, "cannot be empty", "an empty oldString is refused for an existing file")
  t.contains(registry.execute("edit", { filePath = mock.root, oldString = "a", newString = "b" }, ctx()).error, "Path is a directory", "editing a directory is an error")

  -- Whitespace drift is the common failure, so the fuzzy fallbacks have to work.
  local indented = file(mock.root .. "/indented.lua", "function f()\n  return 1\nend\n")
  t.eq(registry.execute("edit", { filePath = indented, oldString = "return 1", newString = "return 2" }, ctx()).status, "completed", "an edit that only differs in indentation still lands")
  t.eq(env.read(indented), "function f()\n  return 2\nend\n", "the indented line is updated in place")
  t.eq(registry.execute("edit", { filePath = indented, oldString = "return   2", newString = "return 3" }, ctx()).status, "completed", "collapsed whitespace is matched")
  t.contains(env.read(indented), "return 3", "the collapsed-whitespace edit landed")

  t.eq(registry.execute("edit", { filePath = mock.root .. "/fresh.lua", oldString = "", newString = "made" }, ctx()).status, "completed", "an empty oldString on a missing file creates it")
  t.eq(env.read(mock.root .. "/fresh.lua"), "made", "the created file has the new content")
  t.contains(registry.execute("edit", { filePath = mock.root .. "/other.lua", oldString = "x", newString = "y" }, ctx()).error, "not found", "editing a missing file with a non-empty oldString is an error")

  -- A fuzzy match that would swallow the whole file must be refused rather than
  -- silently written: a one-line oldString that only matches once whitespace is
  -- collapsed is exactly the case that silently destroys a file.
  local wide = file(mock.root .. "/wide.txt", "unrelated\na\nb\nc\nd\ne\n")
  local swallow = registry.execute("edit", { filePath = wide, oldString = "a b c d e", newString = "z" }, ctx())
  t.eq(swallow.status, "error", "a fuzzy match spanning far more than oldString is refused")
  t.contains(swallow.error, "Refusing replacement", "the refusal explains itself")
  t.eq(env.read(wide), "unrelated\na\nb\nc\nd\ne\n", "the refused edit changed nothing")

  -- glob

  mock.setup()
  file(mock.root .. "/one.lua", "x")
  file(mock.root .. "/two.txt", "x")
  file(mock.root .. "/deep/three.lua", "x")
  file(mock.root .. "/deep/nested/four.lua", "x")

  local luaFiles = registry.execute("glob", { pattern = "**/*.lua" }, ctx())
  t.eq(luaFiles.metadata.count, 3, "a recursive glob finds every .lua file")
  t.contains(luaFiles.output, "one.lua", "a top-level match is included")
  t.contains(luaFiles.output, "deep/three.lua", "a nested match is included")
  t.contains(luaFiles.output, "nested/four.lua", "a deeply nested match is included")
  t.ok(not luaFiles.output:find("two.txt", 1, true), "a non-matching extension is left out")

  t.eq(registry.execute("glob", { pattern = "*.txt" }, ctx()).metadata.count, 1, "a non-recursive glob stays in one directory")
  t.eq(registry.execute("glob", { pattern = "**/*.md" }, ctx()).output, "No files found", "no matches says so rather than returning nothing")
  t.contains(registry.execute("glob", { pattern = "*", path = mock.root .. "/deep" }, ctx()).output, "three.lua", "a path argument scopes the search")
  t.contains(registry.execute("glob", { pattern = "**/*.lua" }, ctx({})).output, mock.root, "matches are absolute paths")
  t.contains(registry.execute("glob", {}).error, "pattern argument is required", "a missing pattern is an error")
  t.ok(registry.execute("glob", { pattern = "*", limit = 1 }, ctx()).output:find("truncated", 1, true), "a limited glob reports the truncation")
  t.contains(registry.execute("glob", { pattern = "*.lua" }, ctx()).output, "one.lua", "an absolute glob works too")

  -- grep

  mock.setup()
  file(mock.root .. "/a.lua", "local needle = 1\nlocal other = 2\n")
  file(mock.root .. "/b.lua", "print('needle')\n")
  file(mock.root .. "/c.txt", "needle in a text file\n")
  file(mock.root .. "/d.lua", "nothing here\n")
  env.mkdirs(mock.root .. "/.git")
  file(mock.root .. "/.git/hidden.lua", "needle in a repository\n")

  local hits = registry.execute("grep", { pattern = "needle" }, ctx())
  t.eq(hits.metadata.count, 3, "every matching line is counted")
  t.contains(hits.output, "a.lua:", "the matching file is named")
  t.contains(hits.output, "Line 1: local needle = 1", "a match is reported with its line number")
  t.contains(hits.output, "b.lua:", "a second file is reported")
  t.contains(hits.output, "Found 3 matches", "the header states the total")
  t.ok(not hits.output:find(".git", 1, true), "repository internals are skipped")
  t.ok(not hits.output:find("d.lua", 1, true), "a non-matching file is not reported")

  t.eq(registry.execute("grep", { pattern = "needle", include = "*.txt" }, ctx()).metadata.count, 1, "an include filter narrows the search")
  t.eq(registry.execute("grep", { pattern = "needle", include = "*.lua, *.txt" }, ctx()).metadata.count, 3, "several include filters are accepted")
  t.eq(registry.execute("grep", { pattern = "needle", include = "*.json" }, ctx()).output, "No matches found", "a filter that excludes everything reports no matches")
  t.eq(registry.execute("grep", { pattern = "local .* = " }, ctx()).metadata.count, 2, "a regex with a quantifier is translated")
  t.eq(registry.execute("grep", { pattern = "^local" }, ctx()).metadata.count, 2, "an anchor is honoured")
  t.eq(registry.execute("grep", { pattern = "other" }, ctx()).metadata.count, 1, "a single match is counted once")
  t.eq(registry.execute("grep", {}).status, "error", "a missing pattern is an error")
  file(mock.root .. "/bracket.lua", "local t = {}  -- arr[0] here\n")
  t.eq(registry.execute("grep", { pattern = "arr\\[0\\]" }, ctx()).metadata.count, 1, "an escaped bracket is matched literally")
  t.eq(registry.execute("grep", { pattern = "t = " }, ctx()).metadata.count, 1, "a substring search needs no anchors")
  t.ok(registry.execute("grep", { pattern = "needle", limit = 1 }, ctx()).output:find("showing the first", 1, true), "a limited search says it is limited")

  -- webfetch

  mock.setup()
  mock.respond({ status = 200, body = "<html><head><title>t</title></head><body><h1>Heading</h1><p>Some text.</p><script>bad()</script></body></html>" })
  local fetched = registry.execute("webfetch", { url = "https://example.com/page" }, ctx())
  t.eq(fetched.status, "completed", "a successful fetch completes")
  t.contains(fetched.output, "Heading", "headings survive the conversion")
  t.contains(fetched.output, "Some text.", "paragraph text survives")
  t.ok(not fetched.output:find("bad()", 1, true), "script contents are dropped")
  t.ok(not fetched.output:find("<h1>", 1, true), "tags are stripped")
  t.contains(fetched.output, "<status>200</status>", "the status is reported to the model")

  mock.setup()
  mock.respond({ status = 200, body = "<p>raw</p>" })
  local raw = registry.execute("webfetch", { url = "http://example.com", format = "html" }, ctx())
  t.eq(mock.requests[#mock.requests].url, "https://example.com", "http is upgraded to https")
  t.contains(raw.output, "<p>raw</p>", "format=html returns the source")
  t.contains(raw.output, "<url>https://example.com</url>", "the upgraded url is the one reported")

  mock.setup()
  mock.respond({ status = 404, body = '{"error":"nope"}' })
  local missing = registry.execute("webfetch", { url = "https://example.com/missing" }, ctx())
  t.eq(missing.status, "error", "a 404 is an error")
  t.contains(missing.error, "Could not fetch", "a 404 names the fetch")
  t.contains(missing.error, "nope", "the server's message is kept")

  mock.setup()
  mock.failWith("host unreachable")
  mock.failWith("host unreachable")
  mock.failWith("host unreachable")
  local transport = registry.execute("webfetch", { url = "https://example.com" }, ctx())
  t.eq(transport.status, "error", "a transport failure is an error")
  t.contains(transport.error, "Could not fetch", "a transport failure names the fetch")
  t.contains(registry.execute("webfetch", { url = "ftp://example.com" }, ctx()).error, "must start with", "a non-http scheme is refused")
  t.contains(registry.execute("webfetch", {}).error, "url argument is required", "a missing url is an error")

  -- todowrite

  mock.setup()
  local current = session.new()
  local written = registry.execute("todowrite", {
    todos = {
      { content = "read the code", status = "completed", priority = "high" },
      { content = "write the spec", status = "in_progress", priority = "high" },
    },
  }, ctx({ session = current }))
  t.eq(written.status, "completed", "a valid todo list is accepted")
  t.eq(#current.todos, 2, "the todos land on the session")
  t.eq(current.todos[1].status, "completed", "the status is stored as given")
  t.contains(written.output, "write the spec", "the tool echoes the list back so the model can see it")
  t.contains(written.title, "2 todos", "the title counts the todos")

  t.contains(registry.execute("todowrite", {
    todos = { { content = "a", status = "pending" }, { content = "b", status = "in_progress" } },
  }, ctx({ session = session.new() })).metadata.todos[1].priority, "medium", "a missing priority defaults to medium")
  t.contains(registry.execute("todowrite", {
    todos = { { content = "a", status = "nonsense" } },
  }, ctx({ session = session.new() })).metadata.todos[1].status, "pending", "an unknown status falls back to pending")
  t.contains(registry.execute("todowrite", {
    todos = { { content = "a", status = "in_progress" }, { content = "b", status = "in_progress" } },
  }, ctx({ session = session.new() })).error, "Exactly one todo may be in_progress", "two in-progress todos are an error")
  t.contains(registry.execute("todowrite", { todos = { { status = "pending" } } }, ctx({ session = session.new() })).error, "non-empty content", "a todo without content is an error")
  t.contains(registry.execute("todowrite", {}, ctx({ session = session.new() })).error, "todos argument is required", "a missing todo list is an error")

  -- bash

  mock.setup()
  local ran = registry.execute("bash", { command = "echo hello" }, ctx())
  t.eq(ran.status, "completed", "a command that works completes")
  t.contains(ran.output, "hello", "the command output is captured")
  t.eq(ran.metadata.exit, 0, "a successful command reports exit code 0")
  t.eq(mock.commands[#mock.commands]:match("^cd ") ~= nil, true, "the command is prefixed with a cd to the working directory")

  local failed = registry.execute("bash", { command = "exit 3" }, ctx())
  t.eq(failed.metadata.exit, 3, "a failing command reports its exit code")
  t.eq(failed.status, "completed", "a non-zero exit is reported, not treated as a tool failure")
  t.eq(registry.execute("bash", { command = "true" }, ctx()).output, "(no output)", "a command with no output says so")

  mock.setup()
  env.mkdirs(mock.root .. "/deep")
  local inWorkdir = registry.execute("bash", { command = "pwd", workdir = mock.root .. "/deep" }, ctx())
  t.eq(inWorkdir.status, "completed", "a workdir argument is honoured")
  t.contains(mock.commands[#mock.commands], "cd '" .. mock.root .. "/deep'", "the workdir becomes the cd target")

  t.contains(registry.execute("bash", {}, ctx()).error, "command argument is required", "a missing command is an error")
  t.contains(registry.execute("bash", { command = "  " }, ctx()).error, "command argument is required", "a blank command is an error")
  t.contains(registry.execute("bash", { command = "ls", timeout = -1 }, ctx()).error, "Invalid timeout value", "a negative timeout is an error")

  mock.hang = true
  local abandoned = registry.execute("bash", { command = "sleep 60", timeout = 0 }, ctx())
  mock.hang = false
  t.eq(abandoned.status, "completed", "a timed-out command is still reported")
  t.contains(abandoned.output, "<shell_metadata>", "a timeout is reported in shell metadata")
  t.contains(abandoned.output, "abandoned", "a command that cannot be killed is described as abandoned")

  -- Output limits are applied by the registry, and tools that already truncated
  -- their own output are left alone.
  mock.setup()
  local huge = file(mock.root .. "/huge.txt", string.rep("line\n", 5000))
  t.eq(#registry.execute("read", { filePath = huge }, ctx({ config = require("config").load(mock.root, { tool_output = { max_lines = 100 } }) })).output < 2000, true, "the registry applies the configured line limit")
end
