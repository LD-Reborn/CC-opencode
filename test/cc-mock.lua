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

--- Make the next request fail the way a transport error does, so `pcall` in the
-- http layer sees a thrown value.
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

local function readAll(handle)
  local position = 1
  return function()
    if position > #handle.body then
      return nil
    end
    local chunk = handle.body:sub(position, position + 1023)
    position = position + 1024
    return chunk
  end
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
    getRunningProgram = function()
      return "/test/opencode.lua"
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

  _G.http = {
    request = function(url, options)
      options = options or {}
      M.requests[#M.requests + 1] = {
        url = url,
        method = options.method,
        headers = options.headers,
        body = options.body,
        timeout = options.timeout,
      }
      local failure = table.remove(M.failures, 1)
      if failure then
        error(failure, 0)
      end
      local response = popResponse(url, options)
      local body = response.body or ""
      local read = readAll({ body = body })
      return {
        read = function()
          return read()
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
function M.screen(inputs)
  local screen = {
    text = "",
    lines = {},
    inputs = inputs or {},
    colour = nil,
    cursorBlink = nil,
    cursor = { 1, 1 },
    size = { 40, 25 },
    cleared = 0,
  }
  local function collect(text)
    text = tostring(text)
    screen.text = screen.text .. text
    for _ in text:gmatch("\n") do
      screen.lines[#screen.lines + 1] = true
    end
  end
  -- ComputerCraft calls a screen's methods with a dot (`term.write(text)`), so
  -- they are defined that way here. `env.terminal()` passes the screen as the
  -- first argument, which suits both conventions.
  screen.write = function(text)
    collect(text)
  end
  screen.readLine = function()
    screen.blank = true
    return table.remove(screen.inputs, 1)
  end
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
  return screen
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
