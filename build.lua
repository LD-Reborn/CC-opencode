-- Build the single-file bundle.
--
--   lua build.lua            write dist/opencode.lua
--   lua build.lua --test     write it, then run the smoke test against it
--   lua build.lua --out p    write somewhere else
--
-- ComputerCraft programs are single files, and a directory tree is a nuisance to
-- install from a command or a pastebin, so the modules are concatenated into one
-- file with a loader that satisfies their `require` calls. The sources are copied
-- verbatim: nothing is rewritten, so a bug is always the bug in the source file.

local root = (arg[0] or ""):match("^(.*)/[^/]*$") or "."

local LIBRARY = root .. "/src"
local TOOLS = LIBRARY .. "/tool"
local ENTRY = root .. "/init.lua"

-- Module name -> file, and the reverse. "cli" is init.lua: in the bundle it is
-- just another module, so the tests can load it without running the program.
local FILES = {
  ["cli"] = ENTRY,
  json = LIBRARY .. "/json.lua",
  util = LIBRARY .. "/util.lua",
  environment = LIBRARY .. "/environment.lua",
  pattern = LIBRARY .. "/pattern.lua",
  truncate = LIBRARY .. "/truncate.lua",
  permission = LIBRARY .. "/permission.lua",
  config = LIBRARY .. "/config.lua",
  provider = LIBRARY .. "/provider.lua",
  http = LIBRARY .. "/http.lua",
  llm = LIBRARY .. "/llm.lua",
  prompt = LIBRARY .. "/prompt.lua",
  session = LIBRARY .. "/session.lua",
  agent = LIBRARY .. "/agent.lua",
  ui = LIBRARY .. "/ui.lua",
  ["tool/registry"] = TOOLS .. "/registry.lua",
  ["tool/lua"] = TOOLS .. "/lua.lua",
  ["tool/bash"] = TOOLS .. "/bash.lua",
  ["tool/read"] = TOOLS .. "/read.lua",
  ["tool/write"] = TOOLS .. "/write.lua",
  ["tool/edit"] = TOOLS .. "/edit.lua",
  ["tool/glob"] = TOOLS .. "/glob.lua",
  ["tool/grep"] = TOOLS .. "/grep.lua",
  ["tool/webfetch"] = TOOLS .. "/webfetch.lua",
  ["tool/todowrite"] = TOOLS .. "/todowrite.lua",
}

-- Modules that are allowed to be absent, and the file that would provide one.
--
-- `GUI` is CC-GUI, which is a separate project with its own licence and its own
-- release cadence, and the interface is built to survive without it: `M.open` answers
-- nil and a reason, the entry point says the reason, and the plain screen takes over.
-- So a bundle without it is a working bundle, and the build says so rather than
-- stopping -- the alternative is a build that cannot succeed on a checkout that has
-- not fetched a dependency, which is a build nobody can run.
--
-- `--gui <path>` inlines one, for a checkout that has it. The file is pasted in like
-- any other module, so a bug in it is the bug in the file it came from.
local EXTERNAL = {
  GUI = "GUI.lua",
}

local function read(path)
  local handle, err = io.open(path, "rb")
  if not handle then
    error("cannot read " .. path .. ": " .. tostring(err), 0)
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

--- Replace every comment in a source with a blank, leaving the code alone.
--
-- Only the dependency scan below cares, and only about this project's own source,
-- so this is a blunt instrument. What it is not allowed to be is wrong about
-- punctuation: a `--` inside a string or a long bracket is two ordinary
-- characters, and treating it as a comment truncates the rest of the line -- which
-- is how a real `require` ends up half-deleted. Ten of the twenty-two modules use
-- long brackets for tool descriptions, so they are walked, not guessed at.
--
-- Line structure is preserved so that anything reading the result can still count
-- lines, and so a comment left behind is where the comment was rather than a
-- colon, which would be a syntax error.
local function stripComments(source)
  local out = {}
  local function emit(text)
    out[#out + 1] = text
  end

  local i, n = 1, #source
  while i <= n do
    local char = source:sub(i, i)
    local following = source:sub(i + 1)

    if char == '"' or char == "'" then
      -- A short string. An escaped quote does not end it, so the backslashes in
      -- front of a candidate are counted rather than assumed absent.
      local stop = source:find(char, i + 1, true)
      while stop do
        local backslashes, k = 0, stop - 1
        while k >= i and source:sub(k, k) == "\\" do
          backslashes = backslashes + 1
          k = k - 1
        end
        if backslashes % 2 == 0 then
          break
        end
        stop = source:find(char, stop + 1, true)
      end
      local finish = stop or n
      emit(source:sub(i, finish))
      i = finish + 1

    elseif char == "[" and following:match("^=*%[") then
      -- A long bracket: a string when at the start of an expression, a comment
      -- when it follows `--`. Either way it runs to a matching `]` plus the same
      -- number of `=`, and its contents are copied through untouched.
      local level = following:match("^(=*)%[")
      local close = "]=" .. level .. "]"
      local stop = source:find(close, i + #level + 2, true)
      if not stop then
        emit(source:sub(i))
        i = n + 1
      else
        emit(source:sub(i, stop + #close - 1))
        i = stop + #close
      end

    elseif char == "-" and following:sub(1, 1) == "-" then
      if following:sub(2, 2) == "[" and following:match("^%-%-=*%[") then
        -- A long comment, which is a long bracket that began with `--`.
        local level = following:match("^%-%-(=*)%[")
        local close = "]=" .. level .. "]"
        local stop = source:find(close, i + #level + 3, true) or n
        emit((source:sub(i, stop):gsub("[^\n]", " ")))
        i = stop + 1
      else
        local stop = source:find("\n", i, true) or n
        emit((source:sub(i, stop):gsub("[^\n]", " ")))
        i = stop
      end

    else
      emit(char)
      i = i + 1
    end
  end
  return table.concat(out)
end

--- What a source refers to, as two lists.
--
-- `direct` is every name passed to `require`. That is authoritative, so a name in
-- it that is not in the bundle is a build error: it would fail on a computer,
-- where there is no way to test it first.
--
-- `named` is every string literal that looks like a module name. `tool/registry`
-- lists its built-ins as data rather than requiring them, so this catches
-- dependencies a `require` scan misses. It is a guess, so it only affects the
-- order of the file, and the bundle loads modules lazily anyway.
--
-- Comments come out first. This project's comments explain things by quoting the
-- code they explain, and a `require("src/util")` written in a comment about
-- requires is not a dependency of anything -- but read as one it is a name that is
-- not in the bundle, and the build stops.
local function dependencies(source)
  source = stripComments(source)
  local direct, named, seen = {}, {}, {}
  local function add(list, name)
    if not seen[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  for name in source:gmatch("require%s*%(%s*[\"']([^\"']+)[\"']%s*%)") do
    add(direct, name)
  end
  for name in source:gmatch("[\"']([a-z][a-z0-9_]*/?[a-z0-9_/]*)[\"']") do
    if not seen[name] then
      add(named, name)
    end
  end
  return direct, named
end

--- Order the modules so each one comes after everything it needs.
local function sortModules(modules, names)
  local order, done, visiting, cycles = {}, {}, {}, {}

  local function visit(name)
    if done[name] then
      return
    end
    if visiting[name] then
      -- A require that comes back around is fine (the loader guards it), so a
      -- cycle only means the reading order is less tidy than it could be.
      cycles[#cycles + 1] = name
      return
    end
    visiting[name] = true
    for _, dependency in ipairs(modules[name]) do
      -- A module that mentions its own name is not a dependency of itself; it
      -- would only look like a cycle.
      if dependency ~= name then
        visit(dependency)
      end
    end
    visiting[name] = nil
    done[name] = true
    order[#order + 1] = name
  end

  for _, name in ipairs(names) do
    visit(name)
  end

  -- The same loop is reported once per edge into it, so say each name once.
  local seen, unique = {}, {}
  for _, name in ipairs(cycles) do
    if not seen[name] then
      seen[name] = true
      unique[#unique + 1] = name
    end
  end
  return order, unique
end

--- Write the bundle for `order` into a string.
--
-- Each module becomes the *body* of a function rather than a long-bracket string:
-- ComputerCraft has no `loadstring`, so the source has to be real code by the
-- time it runs. That means the file is pasted in verbatim, which also means a
-- bug is always the bug in the file it came from.
local function bundle(order, external)
  local parts = {}
  local function add(text)
    parts[#parts + 1] = text
  end

  add([[
-- opencode for ComputerCraft — single-file build.
--
-- Generated by build.lua from the files in src/. Edit those, not this.
-- Copy this file to /rom/programs/opencode and run it.
--
-- Every module below is the untouched source of one file, wrapped in a function
-- and registered with package.preload so the `require` calls still work.

local __sources = {}
]])

  for _, name in ipairs(order) do
    local label, source
    if external[name] then
      -- Normalise line endings and make sure the source ends on a line of its own,
      -- so a trailing comment cannot swallow the `end` that follows it. The header
      -- is the file's own name rather than a path under `src/`: CC-GUI is a separate
      -- project with its own licence, and pasting its banner into a file that says
      -- "generated by build.lua from the files in src/" would be a claim this build
      -- did not make.
      label = EXTERNAL[name]
      source = external[name]:gsub("\r\n", "\n"):gsub("%s+$", "\n")
    else
      label = FILES[name]:gsub("^" .. root .. "/", "")
      source = read(FILES[name])
      -- Normalise line endings and make sure the source ends on a line of its own,
      -- so a trailing comment cannot swallow the `end` that follows it.
      source = source:gsub("\r\n", "\n"):gsub("%s+$", "\n")
    end
    -- An empty block, so a source that happens to open with a parenthesis or a
    -- bracket still parses. Lua 5.1 has no empty statement, so `;` will not do.
    add(("\n-- %s\n__sources[%q] = function(...)\ndo end\n%s\nend\n"):format(label, name, source))
  end

  add([[
-- Module loading.
--
-- This deliberately does not read `package.loaded` to decide whether a module is
-- loaded. ComputerCraft's `require` marks the module it is loading with a
-- light-userdata sentinel, so a "is it already there?" check sees the sentinel
-- and hands that back to the caller in place of the module. `require` does its
-- own caching, so there is nothing to check.
local __loading = {}

local function __require(name, ...)
  local source = __sources[name]
  if not source then
    error("opencode: '" .. tostring(name) .. "' is not part of this bundle", 0)
  end
  if __loading[name] then
    -- The modules require each other, but never while one of them is still
    -- running: `tool/registry` pulls its tools in from `load()`, which is only
    -- called once the registry itself is complete. If this fires, it is a real
    -- require cycle and there is no way to guess the intended order.
    error("opencode: '" .. name .. "' is required while it is still loading, which cannot be resolved", 0)
  end
  __loading[name] = true
  local ok, result = pcall(source, name, ...)
  __loading[name] = nil
  if not ok then
    error("opencode: '" .. name .. "' failed to load: " .. tostring(result), 0)
  end
  package.loaded[name] = result == nil and true or result
  return result
end

for name in pairs(__sources) do
  package.preload[name] = __require
end

-- Run. On a computer the entry point has already run itself, and its return value
-- -- the shell's exit code -- is what requiring it produced. ComputerCraft hands a
-- program's return to nobody and passes `arg` in as a global, so `opencode
-- <question>` arrives the same way it does for the modular version.
--
-- When the bundle is loaded by something else, as the test suite does, the entry
-- came back as a library instead, and `main` is still waiting to be called. That is
-- the only place this return value is read.
local cli = __require("cli")
if type(cli) == "table" then
  return cli.main(arg or {}, nil)
end
return cli
]])

  return table.concat(parts)
end

-- Command line

local function usage()
  print([[
Usage: lua build.lua [--out <path>] [--test] [--gui <path>]

  --out <path>   where to write the bundle (default: dist/opencode.lua)
  --test         run the bundle against a mocked ComputerCraft and report
  --gui <path>   inline CC-GUI from <path> (default: leave it out)
]])
end

local options = { out = root .. "/dist/opencode.lua", test = false, gui = nil }
local index = 1
while arg[index] do
  local item = arg[index]
  if item == "--out" then
    options.out = arg[index + 1] or options.out
    index = index + 2
  elseif item == "--test" then
    options.test = true
    index = index + 1
  elseif item == "--gui" then
    options.gui = arg[index + 1]
    index = index + 2
  elseif item == "--help" or item == "-h" then
    usage()
    os.exit(0)
  else
    io.stderr:write("build: unknown option '" .. item .. "'\n")
    usage()
    os.exit(2)
  end
end

-- Build

local isModule = {}
local names = {}
for name in pairs(FILES) do
  isModule[name] = true
  names[#names + 1] = name
end

-- An external module, if one was named. Looked for in the three places it can be —
-- beside the sources as the installer writes it, in a checkout of the project, and
-- beside the checkout as it is developed against — and inlined when it is there.
--
-- Said rather than fatal when it is not, for the reason at `EXTERNAL` above: the
-- program is built to work without it, so a missing one is a note about what the
-- bundle will not do, not a build that failed.
local external = {}
local guiPath = options.gui
if guiPath then
  for _, directory in ipairs({ root, root .. "/CC-GUI", root .. "/../CC-GUI" }) do
    local candidate = directory .. "/" .. EXTERNAL.GUI
    if io.open(candidate, "rb") then
      guiPath = candidate
      break
    end
  end
  local handle, err = io.open(guiPath, "rb")
  if handle then
    external.GUI = handle:read("*a")
    handle:close()
    isModule.GUI = true
    names[#names + 1] = "GUI"
  else
    io.stderr:write("build: --gui " .. guiPath .. " could not be read: " .. tostring(err) .. "\n")
    io.stderr:write("build: continuing without it; the interface will be unavailable\n")
  end
else
  io.stderr:write("build: no --gui given; CC-GUI is not inlined, so the interface is unavailable\n")
  io.stderr:write("build: pass --gui <path> to inline it\n")
end
table.sort(names)

local modules, missing = {}, {}
for _, name in ipairs(names) do
  local direct, named = dependencies(external[name] or read(FILES[name]))
  local edges = {}
  for _, dependency in ipairs(direct) do
    if isModule[dependency] then
      edges[#edges + 1] = dependency
    elseif not EXTERNAL[dependency] then
      -- One of the optional externals, so a name that is allowed to be absent. Not an
      -- error and not an edge: nothing in the bundle provides it, and the program
      -- asks for it with a `pcall` and carries on without it.
      missing[#missing + 1] = name .. " requires '" .. dependency .. "' (optional, not inlined)"
    else
      missing[#missing + 1] = name .. " requires '" .. dependency .. "'"
    end
  end
  for _, dependency in ipairs(named) do
    if isModule[dependency] then
      edges[#edges + 1] = dependency
    end
  end
  modules[name] = edges
end
-- Only the absent ones are fatal, and only when they are not optional: a `require` for
-- a module that is not in the bundle and not optional is a bundle that cannot run on
-- a computer, where there is no way to test it first.
local absent = {}
for _, item in ipairs(missing) do
  if not item:find("optional", 1, true) then
    absent[#absent + 1] = item
  end
end
if #absent > 0 then
  error("build: these requires are not in the bundle:\n  " .. table.concat(absent, "\n  "), 0)
end
if #missing > 0 then
  print("note: optional modules not inlined: " .. table.concat(missing, ", "))
end

local order, cycles = sortModules(modules, names)
local output = bundle(order, external)

if os.getenv("CCOPENCODE_DEBUG_BUNDLE") then
  local dump = assert(io.open(os.getenv("CCOPENCODE_DEBUG_BUNDLE"), "wb"))
  dump:write(output)
  dump:close()
end

local chunk, syntaxError = loadstring(output, "opencode.lua")
if not chunk then
  error("build: the generated bundle does not parse: " .. tostring(syntaxError), 0)
end

local directory = options.out:match("^(.*)/[^/]*$")
if directory and directory ~= "" then
  os.execute("mkdir -p '" .. directory .. "'")
end
local handle, writeError = io.open(options.out, "wb")
if not handle then
  error("build: cannot write " .. options.out .. ": " .. tostring(writeError), 0)
end
handle:write(output)
handle:close()

print(string.format("wrote %s (%d modules, %d bytes)", options.out, #order, #output))
print("order: " .. table.concat(order, " "))
if #cycles > 0 then
  -- Not a build failure: the loader is lazy, so the order is only cosmetic.
  print("note: these modules require each other in a loop: " .. table.concat(cycles, " "))
end
io.stdout:flush()

-- Test

if not options.test then
  return
end

--- Write `content` to a scratch file and return its path.
local scratch = os.getenv("TMPDIR") or "/tmp"
local function scratchFile(name, content)
  local path = scratch .. "/opencode-build-" .. name
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
  return path
end

local RUNNER = [[
-- Load the bundle in a process where nothing else has been loaded, so a module
-- can only come from the bundle itself.
package.path = %q

local bundle = ...

local mock = require("cc-mock")
mock.install()

local results = { failed = 0 }
local function check(name, condition, detail)
  if condition then
    print("  ok   " .. name)
  else
    results.failed = results.failed + 1
    print("  FAIL " .. name .. (detail and ("  — " .. detail) or ""))
  end
end

local function turn(answer)
  return {
    status = 200,
    body = '{"choices":[{"message":{"content":' ..
      require("json").encode(answer) .. '},"finish_reason":"stop"}],'
      .. '"usage":{"prompt_tokens":3,"completion_tokens":4}}',
  }
end

--- A turn that calls one tool, and the turn that answers afterwards.
local function toolTurn(name, arguments, answer)
  return {
    {
      status = 200,
      body = '{"choices":[{"message":{"content":"","tool_calls":[{"id":"c1","type":"function",'
        .. '"function":{"name":"' .. name .. '","arguments":' ..
        require("json").encode(arguments) .. '}}]},"finish_reason":"tool_calls"}]}',
    },
    turn(answer),
  }
end

local function run(args, inputs, responses, prepare)
  mock.setup()
  -- mock.setup() empties the mock filesystem, so a fixture is written after it,
  -- not before.
  --
  -- The default provider is the zen gateway and it needs a key, so without one
  -- nothing resolves and no request is ever made. Seeded here rather than in
  -- each case, and a `prepare` that wants a different config writes its own file
  -- over this one.
  -- Written as a literal rather than encoded: by this point the bundle has
  -- replaced package.preload, so a require here would not find the json module.
  local config = assert(io.open(mock.root .. "/opencode.json", "wb"))
  config:write('{"env":{"OPENCODE_API_KEY":"zen-key"}}')
  config:close()
  if prepare then
    prepare()
  end
  local screen = mock.screen(inputs or {})
  mock.attach({ left = screen })
  for _, response in ipairs(responses or {}) do
    mock.respond(response)
  end
  _G.arg = args
  local code = dofile(bundle)
  mock.attach({})
  return code, screen
end

print("bundle:")

local code, screen = run({ "--help" })
check("--help exits zero", code == 0, "got " .. tostring(code))
check("--help prints the options", screen.text:find("--model", 1, true) ~= nil)

code, screen = run({ "what is the time" }, {}, { turn("It is Tuesday.") })
check("a one-shot turn exits zero", code == 0, "got " .. tostring(code))
check("the answer is printed", screen.text:find("It is Tuesday.", 1, true) ~= nil)
check("one request was made", #mock.requests == 1, "got " .. #mock.requests)
check("the request went to the default provider",
  mock.requests[1] and mock.requests[1].url == "https://opencode.ai/zen/v1/chat/completions",
  mock.requests[1] and mock.requests[1].url or "none")

-- A file for the read tool below to find. The mock's filesystem is the host's, so
-- this is a real file.
local function writeNotes()
  local handle = assert(io.open(mock.root .. "/notes.txt", "wb"))
  handle:write("one\ntwo\n")
  handle:close()
end

code, screen = run({ "read notes" }, {}, toolTurn("read", { filePath = mock.root .. "/notes.txt" }, "Two lines."), writeNotes)
check("the tool call is logged", screen.text:find("  * read", 1, true) ~= nil)
check("the tools were sent to the model",
  #mock.requests == 2 and (mock.requests[1].body:find('"read"', 1, true) ~= nil), "got " .. #mock.requests)
check("the tool result was fed back",
  #mock.requests == 2 and (mock.requests[2].body:find('"role":"tool"', 1, true) ~= nil))
check("the file's contents came back through the model",
  #mock.requests == 2 and (mock.requests[2].body:find("1: one", 1, true) ~= nil)
    and (mock.requests[2].body:find("2: two", 1, true) ~= nil))
check("the answer after the tool is printed", screen.text:find("Two lines.", 1, true) ~= nil)

code, screen = run({ "--stream", "say something" }, {}, {
  { status = 200, body = 'data: {"choices":[{"delta":{"content":"str"}}]}\n'
    .. 'data: {"choices":[{"delta":{"content":"eam"}}]}\n'
    .. 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\ndata: [DONE]' },
})
check("a streamed turn exits zero", code == 0, "got " .. tostring(code))
check("the streamed answer is printed", screen.text:find("stream", 1, true) ~= nil)
check("the request asked for a stream",
  #mock.requests == 1 and (mock.requests[1].body:find('"stream":true', 1, true) ~= nil))

code, screen = run({}, { "/help", "/model", "/exit" })
check("the REPL exits zero", code == 0, "got " .. tostring(code))
check("/help printed the commands", screen.text:find("/agent", 1, true) ~= nil)

code, screen = run({ "--model", "nosuchprovider/x", "hi" })
check("an unusable model exits nonzero", code == 1, "got " .. tostring(code))
check("and says why", screen.text:find("Unknown provider", 1, true) ~= nil)

-- A saved session is named from its first question, so it can be found again.
-- The mock filesystem is the host's, so the file is read straight off disk.

local function readFile(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function savedSession()
  local directory = mock.root .. "/opencode/session"
  local pipe = io.popen("ls " .. directory .. " 2>/dev/null")
  for name in pipe:lines() do
    pipe:close()
    return readFile(directory .. "/" .. name)
  end
  pipe:close()
  return nil
end

code, screen = run({ "--save", "how many programs" }, {}, { turn("Three."), turn("Counting the programs") })
check("--save exits zero", code == 0, "got " .. tostring(code))
check("--save reports where it wrote", screen.text:find("saved ", 1, true) ~= nil)
local saved = savedSession()
check("the saved session is named from the question",
  saved ~= nil and saved:find('"title": "Counting the programs"', 1, true) ~= nil,
  saved and saved:sub(1, 160) or "no session file was written")
check("the answer is in the saved session too",
  saved ~= nil and saved:find("how many programs", 1, true) ~= nil)

if results.failed > 0 then
  print(results.failed .. " bundle check(s) failed")
  os.exit(1)
end
print("bundle checks passed")
]]

local runner = scratchFile("runner.lua", RUNNER:format(root .. "/test/?.lua"))
local interpreter = arg[-1] or "lua"
local command = string.format("%q %q %q", interpreter, runner, options.out)
print("running: " .. command)
io.stdout:flush()
local status = os.execute(command)
if type(status) == "number" then
  status = math.floor(status / 256)
end
if status ~= 0 then
  os.exit(1)
end
