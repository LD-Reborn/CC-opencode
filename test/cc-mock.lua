-- ComputerCraft API mock.
--
-- Lets the agent loop, tools, and providers run under a plain Lua 5.1
-- interpreter. `fs` is backed by a real temp directory, `shell` delegates to the
-- host, and `http` serves canned provider responses from a queue.

local M = {}

M.root = nil
M.writes = {}
M.commands = {}
M.requests = {}
M.responses = {}
M.failures = {}
M.sleeps = 0
M.hang = false

local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Run a `test -X` probe and report whether it succeeded. The shell appends a
--- newline to `echo`, so the output has to be trimmed before comparing.
local function probe(test, path)
  local pipe = io.popen(test .. " " .. quote(path) .. " 2>/dev/null && echo yes")
  if not pipe then
    return false
  end
  local out = pipe:read("*a") or ""
  pipe:close()
  return out:match("^yes") ~= nil
end

--- Point the mock filesystem at a fresh temp directory.
function M.setup(root)
  M.root = root or (os.getenv("TMPDIR") or "/tmp") .. "/opencode-test"
  os.execute("rm -rf " .. quote(M.root) .. " && mkdir -p " .. quote(M.root))
  M.writes = {}
  M.commands = {}
  M.requests = {}
  M.responses = {}
  M.failures = {}
  M.sleeps = 0
  M.hang = false
  return M.root
end

--- Queue one canned response. `response` is `{ status, body }` or a plain string.
function M.respond(response)
  M.responses[#M.responses + 1] = response
end

function M.respondJson(value, status)
  M.respond({ status = status or 200, body = require("json").encode(value) })
end

--- Make the next request fail the way a transport error does.
--
-- On a computer this is not an exception. The socket fails, `http_failure` is
-- queued, and the synchronous wrapper hands back `nil` and a message; the
-- `pcall` in the http layer is there for malformed arguments, not for the
-- network. A mock that threw instead would send callers looking for a guard that
-- real code does not need.
function M.failWith(message)
  M.failures[#M.failures + 1] = message or "connection refused"
end

local function popResponse(url, options)
  local response = table.remove(M.responses, 1)
  if response == nil then
    return { status = 200, body = '{"choices":[]}' }
  end
  if type(response) == "string" then
    return { status = 200, body = response }
  end
  return response
end

function M.install()
  _G.fs = {
    combine = function(...)
      local parts = {}
      for _, part in ipairs({ ... }) do
        parts[#parts + 1] = tostring(part)
      end
      local out = table.concat(parts, "/")
      out = out:gsub("//+", "/")
      if #out > 1 then
        out = out:gsub("/$", "")
      end
      return out
    end,
    getDir = function(path)
      return path:match("^(.*)/[^/]*$") or "/"
    end,
    getName = function(path)
      return path:match("([^/]*)$")
    end,
    exists = function(path)
      local handle = io.open(path, "r")
      if handle then
        handle:close()
        return true
      end
      return probe("test -e", path)
    end,
    isDir = function(path)
      return probe("test -d", path)
    end,
    getSize = function(path)
      local handle = io.open(path, "rb")
      if not handle then
        return 0
      end
      local size = handle:seek("end")
      handle:close()
      return size
    end,
    attributes = function(path, kind)
      if kind ~= "modification" then
        return nil
      end
      local pipe = io.popen("date -r " .. quote(path) .. " +%s 2>/dev/null")
      local out = pipe:read("*a")
      pipe:close()
      return tonumber(out) or 0
    end,
    makeDir = function(path)
      return os.execute("mkdir -p " .. quote(path))
    end,
    dir = function(path)
      local names = {}
      local pipe = io.popen("ls -A " .. quote(path) .. " 2>/dev/null")
      if pipe then
        for name in pipe:lines() do
          names[#names + 1] = name
        end
        pipe:close()
      end
      return names
    end,
    open = function(path, mode)
      local file, err = io.open(path, mode == "w" and "wb" or (mode == "a" and "ab" or "rb"))
      if not file then
        return nil, err
      end
      if mode == "w" or mode == "a" then
        table.insert(M.writes, path)
      end
      -- CC handles are called as `handle.read(n)`, not `handle:read(n)`, so
      -- every method here takes its first argument as the real value and
      -- tolerates a stray self.
      return {
        write = function(a, b)
          file:write(b or a or "")
        end,
        read = function(a, b)
          return file:read(b or a or 4096)
        end,
        readAll = function()
          return file:read("*a") or ""
        end,
        readLine = function()
          return file:read("*l")
        end,
        seek = function(a, b)
          return file:seek(b or a or "cur")
        end,
        close = function()
          file:close()
        end,
      }
    end,
    delete = function(path)
      return os.remove(path)
    end,
  }

  _G.shell = {
    dir = function()
      return M.root
    end,
    -- This harness is the program, and it is not called `init.lua` or
    -- `opencode.lua`, so an entry point loaded here comes back as a library. That
    -- is the same answer a computer gives for a program requiring one, and it is
    -- what keeps `init.lua` from starting a REPL inside the test run. The specs
    -- that want the other answer name one of those two files here.
    getRunningProgram = function()
      return "/test/harness.lua"
    end,
    -- Returning nil forces the `bash` tool's coroutine fallback path, which is
    -- the one ComputerCraft installs actually take.
    which = function()
      return nil
    end,
    run = function(command)
      M.commands[#M.commands + 1] = command
      if M.hang then
        -- Stand in for a command that never finishes: yield forever so the
        -- timeout branch of `bash` runs.
        coroutine.yield()
      end
      -- The `bash` tool always redirects output to a file, so only the exit
      -- status matters here. Lua 5.1 hands back the raw wait status.
      local status = os.execute(command)
      if type(status) == "number" then
        return math.floor(status / 256)
      end
      return status and 0 or 1
    end,
  }

  _G.parallel = {
    --- CC yields to the event loop until one thread yields an event. The mock has
    -- no event loop, so a coroutine is resumed once: it either finishes (return
    -- the thread) or yields (fall through to the timer token).
    waitForAny = function(threads)
      for _, thread in ipairs(threads) do
        if type(thread) == "thread" then
          local ok, err = coroutine.resume(thread)
          if not ok then
            error(err, 0)
          end
          if coroutine.status(thread) == "dead" then
            return thread
          end
        end
      end
      return threads[#threads]
    end,
    waitForAll = function(threads)
      for _, thread in ipairs(threads) do
        if type(thread) == "thread" then
          local ok, err = coroutine.resume(thread)
          if not ok then
            error(err, 0)
          end
        end
      end
    end,
  }

  -- ComputerCraft's http API, on its real argument handling and its real return
  -- values. There are two things in it that read as reasonable, cannot work on a
  -- computer, and that this mock used to wave through:
  --
  --   1. `http.request` is *asynchronous*. It starts the request, returns
  --      immediately, and delivers the response later as an `http_success` or
  --      `http_failure` event. Its own source calls the return value "for legacy
  --      reasons" and undocumented. It is a boolean, so reading a response out of
  --      it raises "attempt to index local 'handle' (a boolean value)" and
  --      nothing is ever fetched. The synchronous pair is `http.get`/`http.post`,
  --      which wraps the very same call in an `os.pullEvent` loop internally.
  --
  --   2. All three dispatch on the type of the *first* argument. A table is the
  --      options form, with the url inside it. A string is the legacy positional
  --      signature, where argument 2 is the body and so must be a string — which
  --      is why `http.request(url, { method = "GET" })` is refused with "bad
  --      argument #2 (string expected, got table)".
  --
  -- A mock that accepts any arrangement and hands back a handle cannot fail the
  -- way the hardware does, so a program that made no working request at all had a
  -- fully green suite. Both refusals are reproduced here now.
  --
  -- Failures follow the documented contract as well: `nil, message`, plus the
  -- failing Response as a third value whenever the server answered at all. That
  -- third value is the only place a provider's own error text lives, so losing it
  -- turns a 401 into a bare "HTTP 401" — worth modelling rather than flattening.
  local function checkField(options, key, expected, optional)
    local value = options[key]
    if (value ~= nil or not optional) and type(value) ~= expected then
      error(string.format("bad field '%s' (%s expected, got %s)", key, expected, type(value)), 0)
    end
  end

  local function checkRequestOptions(options, allowBody)
    checkField(options, "url", "string", false)
    if allowBody == false then
      -- `get` refuses a body outright, checking it as "nil expected".
      if options.body ~= nil then
        error("bad field 'body' (nil expected, got " .. type(options.body) .. ")", 0)
      end
    else
      checkField(options, "body", "string", true)
    end
    checkField(options, "headers", "table", true)
    checkField(options, "method", "string", true)
    checkField(options, "redirect", "boolean", true)
    checkField(options, "timeout", "number", true)
    if options.method then
      local method = options.method:upper()
      if method == "CONNECT" then
        error("Unsupported HTTP method", 0)
      end
      if method == "" or #method > 32 or method:find("[^A-Z_-]") then
        error("Invalid HTTP method", 0)
      end
    end
  end

  -- What a computer says for a status it has no reason phrase ready for. Kept
  -- distinct from anything the program computes, so that a caller which mistakes
  -- this message for the real error shows up as a test failure.
  local REASON = {
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [422] = "Unprocessable Entity",
    [429] = "Too Many Requests",
    [500] = "Internal Server Error",
    [502] = "Bad Gateway",
    [503] = "Service Unavailable",
  }

  local function responseHandle(response)
    local body = response.body or ""
    local position = 1
    return {
      read = function(n)
        local chunk = body:sub(position, position + (n or 1024) - 1)
        position = position + #chunk
        if chunk == "" then
          return nil
        end
        return chunk
      end,
      readAll = function()
        return body
      end,
      getResponseCode = function()
        return response.status or 200
      end,
      getResponseHeaders = function()
        return response.headers or {}
      end,
      close = function() end,
    }
  end

  -- What a request actually does, once its arguments have been sorted out.
  local function send(url, options)
    M.requests[#M.requests + 1] = {
      url = url,
      method = options.method,
      headers = options.headers,
      body = options.body,
      timeout = options.timeout,
    }
    local failure = table.remove(M.failures, 1)
    if failure then
      return nil, failure
    end
    local response = popResponse(url, options)
    local status = response.status or 200
    if status >= 200 and status < 300 then
      return responseHandle(response)
    end
    return nil, REASON[status] or ("HTTP error " .. status), responseHandle(response)
  end

  _G.http = {
    get = function(a, b, c)
      if type(a) == "table" then
        checkRequestOptions(a, false)
        return send(a.url, a)
      end
      if type(a) ~= "string" then
        error("bad argument #1 to 'get' (string expected, got " .. type(a) .. ")", 0)
      end
      if b ~= nil and type(b) ~= "table" then
        error("bad argument #2 to 'get' (table expected, got " .. type(b) .. ")", 0)
      end
      return send(a, { method = "GET", headers = b })
    end,

    post = function(a, b, c)
      if type(a) == "table" then
        checkRequestOptions(a, true)
        return send(a.url, a)
      end
      if type(a) ~= "string" then
        error("bad argument #1 to 'post' (string expected, got " .. type(a) .. ")", 0)
      end
      if type(b) ~= "string" then
        error("bad argument #2 to 'post' (string expected, got " .. type(b) .. ")", 0)
      end
      return send(a, { method = "POST", body = b, headers = c })
    end,

    -- Asynchronous, and the reason is not obvious from the name: this starts the
    -- request and returns a boolean. The response arrives as an event, which this
    -- mock does not deliver -- `os.pullEvent` here is a stub -- so a caller that
    -- correctly waits for one will hang visibly rather than quietly pass.
    request = function(a, b, c)
      if type(a) == "table" then
        checkRequestOptions(a, true)
        local handle, message = send(a.url, a)
        if handle then
          return true
        end
        return false, message
      end
      if type(a) ~= "string" then
        error("bad argument #1 to 'request' (string expected, got " .. type(a) .. ")", 0)
      end
      if b ~= nil and type(b) ~= "string" then
        error("bad argument #2 to 'request' (string expected, got " .. type(b) .. ")", 0)
      end
      local handle, message = send(a, { method = b and "POST" or "GET", body = b, headers = c })
      if handle then
        return true
      end
      return false, message
    end,
  }

  _G.textutils = {
    urlEncode = function(s)
      return (tostring(s):gsub("[^%w%-%._~]", function(char)
        return string.format("%%%02X", char:byte())
      end))
    end,
  }

  _G.colors = {
    white = 1,
    orange = 2,
    magenta = 3,
    lightBlue = 4,
    yellow = 5,
    lime = 6,
    pink = 7,
    gray = 8,
    lightGray = 128,
    cyan = 256,
  }
  _G.colors.red = 16384
  _G.term = nil
  _G.peripheral = nil
  M.sleeps = 0
  M.currentScreen = nil
  -- CraftOS's `read`, as a global, answering from the current screen's queue and
  -- nil once it is empty -- which is what a real terminal does when the operator
  -- closes the program. Overwriting the host's `io.read` on purpose: the program
  -- env inherits globals, and a test that let the real one through would block on
  -- stdin instead of failing.
  _G.read = function()
    local screen = M.currentScreen
    if not screen or #screen.inputs == 0 then
      return nil
    end
    return table.remove(screen.inputs, 1)
  end
  _G.os.sleep = function(seconds)
    M.sleeps = M.sleeps + (seconds or 0)
  end
  _G.os.startTimer = function(seconds)
    return { timer = seconds or 0 }
  end
  _G.os.cancelTimer = function() end
  _G.os.pullEvent = function()
    return "timer"
  end
  _G.os.getComputerLabel = function()
    return "testbed"
  end
end

--- Every file written during the test, for assertions.
function M.writtenFiles()
  return M.writes
end

--- A stand-in for a monitor or terminal.
--
-- `inputs` is the list of answers `readLine` returns, in order; once it runs out
-- `readLine` returns nil, which is what a ComputerCraft terminal does when its
-- user closes the program. Everything written is accumulated so a test can
-- assert on the output.
--- A screen for the program to draw on.
--
-- Wide by default, so an assertion about what was printed is not also an
-- assertion about where it happened to wrap. A test that cares about narrow
-- terminals passes the width, and there is one of those on purpose: wrapping is
-- only visible at a width narrow enough to force it, and a roomy default hides
-- it completely.
--
-- `notATerminal` marks a screen as a monitor rather than the terminal, which
-- matters because `read` is a global reading the terminal: output can go to a
-- monitor while the answers still come from the keyboard. The most recently
-- created ordinary screen stands in for the terminal.
function M.screen(inputs, size, notATerminal)
  local screen = {
    text = "",
    lines = {},
    drawn = {},
    inputs = inputs or {},
    colour = nil,
    cursorBlink = nil,
    cursor = { 1, 1 },
    size = size or { 200, 50 },
    cleared = 0,
  }
  local function collect(text)
    text = tostring(text)
    screen.text = screen.text .. text
    for _ in text:gmatch("\n") do
      screen.lines[#screen.lines + 1] = true
    end
    -- Each line as it was actually written, so a test can assert on the width of
    -- every one of them. `text` as a whole cannot: it says nothing about where
    -- the lines were broken, which is the only thing that matters on a screen
    -- narrow enough to have broken them.
    local at = 1
    while at <= #text do
      local stop = text:find("\n", at, true)
      screen.drawn[#screen.drawn + 1] = text:sub(at, (stop or (#text + 1)) - 1)
      if not stop then
        break
      end
      at = stop + 1
    end
  end
  -- ComputerCraft calls a screen's methods with a dot (`term.write(text)`), so
  -- they are defined that way here. `env.terminal()` passes the screen as the
  -- first argument, which suits both conventions.
  screen.write = function(text)
    collect(text)
  end
  -- Deliberately no `readLine`. The real `term` module has no such method, and
  -- supplying one here is what let a program that called it pass: the mock
  -- answered, real hardware returned nil, and nil was read as end of input, so
  -- the REPL exited after its banner and every permission prompt denied in
  -- silence. A mock that offers an API the target does not have will happily
  -- pass code that cannot run, which is the whole reason this file exists.
  screen.clear = function()
    screen.cleared = screen.cleared + 1
  end
  screen.scroll = function() end
  screen.setCursorBlink = function(state)
    screen.cursorBlink = state
  end
  screen.setCursorPos = function(x, y)
    screen.cursor = { x, y }
  end
  screen.getCursorPos = function()
    return screen.cursor[1], screen.cursor[2]
  end
  screen.setTextColor = function(colour)
    screen.colour = colour
  end
  screen.getSize = function()
    return screen.size[1], screen.size[2]
  end
  -- CraftOS's `read` is a global that reads from the terminal, not a method on
  -- whichever screen the program happens to be drawing on, and it is how the
  -- shell reads its own command line. Modelling that matters: it means a test
  -- cannot accidentally pass by putting the answers on a monitor.
  if not notATerminal then
    M.currentScreen = screen
  end
  -- The invariant, asserted where it is established rather than in a spec: a
  -- screen answers nil for any method it does not have, exactly as a ComputerCraft
  -- peripheral does, and `nil` is what "the operator closed the program" looks
  -- like. A mock that grows a method the target lacks will pass code that cannot
  -- run, and the symptom on hardware is a program that exits in silence.
  screen.readLine = nil
  return screen
end

--- The answers `read` will hand out, in order; nil once they run out.
--
-- Read from the most recently created screen, which is the terminal as far as
-- `read` is concerned. Kept as a function rather than a closure over one screen
-- because the permission tests build a screen to draw the question on and then
-- answer it, and that is the same arrangement a computer has.
function M.answers(...)
  local screen = M.currentScreen
  if not screen then
    return nil
  end
  for _, answer in ipairs({ ... }) do
    screen.inputs[#screen.inputs + 1] = answer
  end
  return nil
end

--- Attach screens to named peripherals, so `env.terminal()` has something to find.
-- `map` is `{ left = screen }`; a nil value detaches.
function M.attach(map)
  local peripherals = {}
  for name, screen in pairs(map or {}) do
    peripherals[name] = screen
  end
  if next(peripherals) == nil then
    _G.peripheral = nil
    return
  end
  _G.peripheral = {
    find = function(name)
      return peripherals[name]
    end,
    getType = function()
      return "monitor"
    end,
  }
end

--- Build a context object for a tool or agent test.
--
-- The permission ruleset allows everything, so tests exercise the tools rather
-- than the approval prompt. `config` is derived from the real loader so a test
-- exercises the same defaults the program would.
function M.context(options)
  options = options or {}
  local configModule = require("config")
  local sessionModule = require("session")
  local cwd = options.cwd or M.root
  local current = options.session or sessionModule.new()
  return {
    session = current,
    config = options.config or configModule.load(cwd),
    model = options.model,
    smallModel = options.smallModel,
    agent = options.agent or "build",
    root = options.root or cwd,
    cwd = cwd,
    permission = options.permission or configModule.load(cwd).permission,
    enabled = options.enabled,
    monitor = options.monitor,
    stream = options.stream,
    timeout = options.timeout,
    blocked = false,
    on = options.on or function() end,
    aborted = options.aborted or function() return false end,
  }
end

return M
