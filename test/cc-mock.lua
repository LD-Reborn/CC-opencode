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
M.events = {}
M.sleeps = 0
M.hang = false
M.redirected = nil
M.clock = 0
M.clockStep = 1
M.closed = false
M.pulled = 0
M.budget = 10000
-- How many past frames a screen keeps. Enough for a test to look back through a
-- dialog and the conversation under it; bounded, because a GUI repaints on every
-- keystroke and a test that typed a few hundred characters would otherwise be
-- holding a few hundred grids in memory.
M.MAX_FRAMES = 200

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

--- Put the mock's transient state back to how it started.
--
-- Split out of `setup` because a spec that drives a key loop needs a fresh event
-- queue and a fresh budget between its own tests without also wiping the canned
-- responses and the filesystem it just arranged.
--
-- The globals are cleared as well, and that is the half of it that is easy to miss: a
-- terminal or a peripheral left over from the previous test is a screen the next one
-- will draw on and a keyboard it will read from, and the failure shows up several
-- tests later as an interface that opened where it should not have.
function M.reset()
  M.events = {}
  M.sleeps = 0
  M.hang = false
  M.redirected = nil
  M.clock = 0
  M.clockStep = 1
  M.closed = false
  M.pulled = 0
  M.budget = M.budget or 10000
  _G.term = nil
  _G.peripheral = nil
  return M
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
  return M.reset()
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
    -- `fs.list` is what `env.listDir` calls, and the only directory reader
    -- CraftOS has. `fs.dir` below is not a CraftOS function and nothing calls
    -- it, so it is kept out: a mock that grows a method the target lacks
    -- will happily pass code that cannot run.
    list = function(path)
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
    -- no event loop, so each thread is run once: one that finishes returns its
    -- token, and one that yields falls through to the next.
    waitForAny = function(...)
      local threads = { ... }
      for _, thread in ipairs(threads) do
        if type(thread) == "thread" then
          local ok, err = coroutine.resume(thread)
          if not ok then
            error(err, 0)
          end
          if coroutine.status(thread) == "dead" then
            return thread
          end
        elseif type(thread) == "function" then
          local token = thread()
          if token ~= nil then
            return token
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

  -- The full ComputerCraft palette, at the values CC:Tweaked actually uses.
  --
  -- CC-GUI names colours its callers pass in, and a mock holding only the handful
  -- this project used to answer nil for the rest -- so a widget that asked for
  -- `colors.green` would draw an invisible one here and be perfectly correct on
  -- a computer. The encoding is a terminal colour index for the first eight, then
  -- one bit per further colour, which is why `white` is 0 and `black` is not.
  _G.colors = {
    white = 0,
    orange = 1,
    magenta = 2,
    lightBlue = 3,
    yellow = 4,
    lime = 5,
    pink = 6,
    gray = 7,
    lightGray = 128,
    cyan = 256,
    blue = 512,
    brown = 1024,
    green = 2048,
    red = 4096,
    black = 8192,
    lightRed = 16384,
    darkGray = 32768,
  }
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
  -- A handle the program can hand back to `os.cancelTimer`, so that a screen is a
  -- real object here as well. Nothing else looks inside it.
  local timerSerial = 0
  _G.os.startTimer = function(seconds)
    timerSerial = timerSerial + 1
    return { timer = timerSerial, seconds = seconds or 0 }
  end
  _G.os.cancelTimer = function(handle)
    for index, queued in ipairs(M.events) do
      if queued[1] == "timer" and queued[2] == handle then
        table.remove(M.events, index)
        return
      end
    end
  end
  -- The event queue, so a program that drives its own key loop can be tested.
  --
  -- A real terminal is an event source and a program that polls one blocks until
  -- something happens; the old stub answered "timer" unconditionally, which let a
  -- key loop spin forever instead of failing. Now it hands out what a test queued.
  --
  -- What it does with an empty queue is the part that matters, and it is not
  -- "wait". A test that queues three keys and calls a read wants to be handed those
  -- three keys and then to have the read *end* -- that is what "the operator typed
  -- three characters and the program stopped reading" looks like -- and an endless
  -- "timer" answers neither: the read runs to the pull budget, repaints the screen
  -- ten thousand times, and returns a nil that says nothing about what happened.
  -- So an unfiltered pull on an empty queue is the end of input, the same nil
  -- `os.pullEvent` gives when the program is shutting down. A *filtered* pull still
  -- answers a timer, because that is how `util.sleep` waits for one.
  _G.os.pullEvent = function(filter, timeout)
    if M.closed then
      return nil
    end
    -- A budget, so a program that waits for an event that is never coming ends as
    -- "end of input" instead of running until the suite is killed. Ten thousand is
    -- far more than any of these programs spends waiting for a real key, and the
    -- alternative is a run that hangs with no output, which is the one failure
    -- mode that tells the person who hit it nothing at all.
    M.pulled = M.pulled + 1
    if M.budget and M.pulled > M.budget then
      return nil
    end
    local fallback = timeout and { "timer", os.startTimer and 0 or 0 } or nil
    for index, event in ipairs(M.events) do
      if not filter or event[1] == filter then
        if index == 1 then
          table.remove(M.events, 1)
        else
          M.events[index] = M.events[#M.events]
          M.events[#M.events] = nil
        end
        return unpack(event, 1, #event)
      end
    end
    -- Nothing left, and nothing to wait for: the end of input. See the note above.
    if not fallback then
      return nil
    end
    return unpack(fallback, 1, 2)
  end
  -- `os.queueEvent`, which a program uses to hand an event it pulled to a
  -- coroutine of its own: the lua tool runs the model's code in one and feeds it
  -- every event this loop pulls, so the tool can time out. The queue is the same
  -- one `pullEvent` reads, and an event queued lands where a key the operator
  -- pressed would -- behind whatever is still waiting, ahead of the next pull.
  _G.os.queueEvent = function(name, ...)
    M.events[#M.events + 1] = { name, ... }
  end
  _G.os.getComputerLabel = function()
    return "testbed"
  end
  -- The clock `os.timer` reports, in seconds, and what advances it.
  --
  -- A UI throttles its repaints with this: a streamed answer arrives in hundreds of
  -- pieces and repainting the screen for each one is the difference between an
  -- interface that keeps up and one that does not. A test that wants to watch the
  -- throttle has to be able to stand the clock still, so it is a number here
  -- rather than a call into the host's clock. It advances by a second on every read
  -- by default, which is a machine fast enough that every write repaints -- the
  -- visible behaviour, and what a test asserting on a layout wants.
  M.clock = 0
  M.clockStep = 1
  _G.os.timer = function()
    M.clock = M.clock + (M.clockStep or 0)
    return M.clock
  end
  _G.os.clock = _G.os.timer

  -- CraftOS's `keys`, which is how a program names a key code. Only the names this
  -- project and CC-GUI look up are here; anything else answers "unknown", which is
  -- what CC does for a key bound to nothing.
  local KEY_NAMES = {
    [12] = "delete",
    [14] = "backspace",
    [28] = "enter",
    [43] = "tab",
    [208] = "up",
    [209] = "down",
    [210] = "left",
    [211] = "right",
    [256] = "left shift",
    [257] = "right shift",
    [258] = "left ctrl",
    [259] = "right ctrl",
    [260] = "left alt",
    [261] = "right alt",
    [274] = "home",
    [275] = "end",
    [276] = "insert",
    [277] = "delete",
    [278] = "page up",
    [279] = "page down",
  }
  for index = 0, 11 do
    KEY_NAMES[280 + index] = "f" .. (index + 1)
  end
  _G.keys = {
    getName = function(code)
      return KEY_NAMES[code] or "unknown"
    end,
  }

  -- `paintutils`, which CC-GUI draws its boxes and borders with.
  --
  -- It has no screen argument of its own: like the real one it draws to whichever
  -- terminal `term.redirect` last pointed it at, which is how CC-GUI draws on a
  -- monitor without passing it in. Straight into the cell grid, and bounded by
  -- it -- a coordinate outside the screen is dropped, which is the half of the
  -- boundary rule a GUI library does not do for itself and the reason the mock
  -- has a grid at all.
  local function target()
    return M.redirected or _G.term
  end
  -- Every one of these paints a *background*, which is what a filled box, a border
  -- and a line are on a real screen: the cell's colour, not the colour of some
  -- character in it. Drawing a space with the colour as its foreground would fill
  -- the grid's text and leave the background black, so a grey title bar would
  -- assert as empty.
  _G.paintutils = {
    drawPixel = function(x, y, colour)
      M.pixel(target(), x, y, " ", colors.white, colour)
    end,
    drawBox = function(x1, y1, x2, y2, colour)
      local monitor = target()
      local x, y = math.min(x1, x2), math.min(y1, y2)
      local right, bottom = math.max(x1, x2), math.max(y1, y2)
      for column = x, right do
        M.pixel(monitor, column, y, " ", colors.white, colour)
        M.pixel(monitor, column, bottom, " ", colors.white, colour)
      end
      for row = y, bottom do
        M.pixel(monitor, x, row, " ", colors.white, colour)
        M.pixel(monitor, right, row, " ", colors.white, colour)
      end
    end,
    drawFilledBox = function(x1, y1, x2, y2, colour)
      local monitor = target()
      local x, y = math.min(x1, x2), math.min(y1, y2)
      local right, bottom = math.max(x1, x2), math.max(y1, y2)
      for row = y, bottom do
        for column = x, right do
          M.pixel(monitor, column, row, " ", colors.white, colour)
        end
      end
    end,
    drawLine = function(x1, y1, x2, y2, colour)
      local monitor = target()
      local dx, dy = math.abs(x2 - x1), math.abs(y2 - y1)
      local sx = x1 < x2 and 1 or -1
      local sy = y1 < y2 and 1 or -1
      local err = dx - dy
      while true do
        M.pixel(monitor, x1, y1, " ", colors.white, colour)
        if x1 == x2 and y1 == y2 then
          break
        end
        local double = err * 2
        if double > -dy then
          err = err - dy
          x1 = x1 + sx
        end
        if double < dx then
          err = err + dx
          y1 = y1 + sy
        end
      end
    end,
  }
end

--- Every file written during the test, for assertions.
function M.writtenFiles()
  return M.writes
end

--- Put one character in one cell of a screen's grid.
--
-- Bounded, and the bound is the interesting part: a coordinate outside the screen
-- is dropped and counted rather than clamped. A GUI library that does not enforce
-- its own boundaries draws a box one column past the right edge, and on a real
-- ComputerCraft screen that overflow wraps to the next row and shreds whatever
-- was already there. Dropping it here is what lets a test say that nothing
-- escaped, which is a claim no amount of string matching on `text` can make.
function M.pixel(screen, x, y, char, fg, bg)
  if not screen or not screen.grid then
    return false
  end
  x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
  if x < 1 or y < 1 or x > screen.size[1] or y > screen.size[2] then
    screen.outside = screen.outside + 1
    return false
  end
  local index = (y - 1) * screen.size[1] + x
  screen.grid[index] = char
  screen.gridFg[index] = fg
  screen.gridBg[index] = bg
  return true
end

--- Queue events for `os.pullEvent`, in order.
--
-- `M.queue({ "char", "/" })` and `M.queue({ "key", 28 })` are the two a key loop
-- sees. Once the queue is empty an unfiltered pull is the end of input, so a read
-- driven by a test ends when the test has run out of keys to give it rather than
-- looping to the pull budget.
function M.queue(...)
  for _, event in ipairs({ ... }) do
    M.events[#M.events + 1] = event
  end
end

--- Close the program, so the next `os.pullEvent` answers nil.
--
-- On a computer nothing does this while a program is running: the terminal blocks
-- until the operator does something, and the program is gone when they close it.
-- What it *is* is the end of input, which CraftOS's `read` reports by returning nil
-- and a hand-rolled key loop has to be able to hear as well -- otherwise a program
-- waiting for a key that will never arrive spins on a nil event forever instead of
-- exiting, and a test that wanted to show the exit cannot finish at all.
function M.close()
  M.closed = true
  return M
end

--- Type a line into the input field a GUI is showing: the chars, then enter.
function M.type(text, ...)
  for index = 1, #text do
    M.queue({ "char", text:sub(index, index) })
  end
  M.queue({ "key", 28, "enter" })
  return M
end

--- A copy of one of the cell tables, for keeping a frame.
function M.copyGrid(grid)
  local out = {}
  for index = 1, #grid do
    out[index] = grid[index]
  end
  return out
end

--- The cells a test is reading: the screen's own, or a frame that has ended.
--
-- The three accessors below all take this, so every one of them can be pointed at
-- either. That is the whole of the frame feature: `M.frame(screen, -1)` is the last
-- frame to end, which is the one that held the dialog, and `M.frameText` and
-- `M.fg` read it without the test having to know a frame is a table of tables.
function M.cells(screen, frame)
  if frame == nil then
    return screen.grid, screen.gridFg, screen.gridBg
  end
  local frames = screen.frames or {}
  local held = frames[frame > 0 and frame or #frames + frame + 1]
  if not held then
    return {}, {}, {}
  end
  return held.grid, held.fg, held.bg
end

--- One row of a screen's grid, as a string, for asserting on a layout.
function M.row(screen, y, frame)
  local grid = M.cells(screen, frame)
  local out = {}
  for x = 1, screen.size[1] do
    out[x] = grid[(y - 1) * screen.size[1] + x] or " "
  end
  return table.concat(out)
end

--- The whole grid, rows joined by newlines, for a test that wants to read the screen.
function M.gridText(screen, frame)
  local rows = {}
  for y = 1, screen.size[2] do
    rows[y] = M.row(screen, y, frame)
  end
  return table.concat(rows, "\n")
end

--- The foreground colour of one cell, for a test asserting on colour rather than text.
function M.fg(screen, x, y, frame)
  local _, fg = M.cells(screen, frame)
  return fg[(y - 1) * screen.size[1] + x]
end

--- The background colour of one cell.
function M.bg(screen, x, y, frame)
  local _, _, bg = M.cells(screen, frame)
  return bg[(y - 1) * screen.size[1] + x]
end

--- The newest frame that has `text` anywhere in it, or nil.
--
-- For something that is drawn, read, and taken off again inside one call: a permission
-- dialog, say. Which frame held it depends on how many keys the operator pressed on
-- the way to the answer, so there is no fixed offset to read -- but the question of
-- whether it was ever on the screen at all does not depend on that, and that is the
-- question worth asking.
function M.frameContaining(screen, text)
  for index = #screen.frames, 1, -1 do
    if M.gridText(screen, index):find(text, 1, true) then
      return index
    end
  end
  return nil
end

--- Install a screen as the computer's own terminal, so `term` exists.
--
-- The GUI draws on the terminal rather than a monitor, because the operator has to
-- be able to type and CraftOS's keyboard belongs to the terminal. Tests that
-- exercise it need `term` to be a real screen of a known size, which is what this
-- gives them; it does not make the screen a peripheral, so `env.terminal()` still
-- reports no monitor and a test has to say which screen it means.
function M.console(size, inputs)
  local screen = M.screen(inputs, size)
  _G.term = screen
  screen.redirect = function(monitor)
    M.redirected = monitor
    return _G.term
  end
  screen.native = function()
    return _G.term
  end
  screen.isColor = function()
    return false
  end
  screen.setPaletteColor = function() end
  screen.getPaletteColor = function()
    return "ffffff"
  end
  return screen
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
    backgroundColour = nil,
    cursorBlink = nil,
    cursor = { 1, 1 },
    size = size or { 200, 50 },
    cleared = 0,
    lost = 0,
    outside = 0,
    frames = {},
  }
  -- The cell grid, alongside the linear record above rather than instead of it.
  --
  -- `text` answers "what did the program hand over, in order", which is what a
  -- printing program needs to be checked on. It cannot tell a title bar from a
  -- transcript, a button from the text beside it, or whether anything was drawn
  -- twice on top of itself -- a GUI is geometry, so the same cells are also kept
  -- by coordinate and a layout can be read one row at a time.
  local width, height = size and size[1] or 200, size and size[2] or 50
  screen.grid = {}
  screen.gridFg = {}
  screen.gridBg = {}
  for index = 1, width * height do
    screen.grid[index] = " "
  end
  local function collect(text)
    text = tostring(text)
    -- ComputerCraft does not carry a line that overruns its screen: the tail is
    -- discarded, not continued on the next row. Modelling that is the point. A
    -- screen that accepted every length would let a program with no wrapping at
    -- all pass, and the symptom on hardware is text that silently stops halfway
    -- across — which is exactly what it did here, with the whole of the model's
    -- answer written straight out past the right edge.
    local at = 1
    while at <= #text do
      local stop = text:find("\n", at, true)
      local row = text:sub(at, (stop or (#text + 1)) - 1)
      -- `drawn` is what the program handed over, so a test can say whether the
      -- program wrapped; `text` and `lost` are what the screen did with it, so a
      -- test can say whether the wrapping was enough. Asserting on the first and
      -- getting the second for free is the whole arrangement.
      screen.drawn[#screen.drawn + 1] = row
      if #row > screen.size[1] then
        screen.lost = screen.lost + (#row - screen.size[1])
        row = row:sub(1, screen.size[1])
      end
      screen.text = screen.text .. row
      if stop then
        screen.text = screen.text .. "\n"
        screen.lines[#screen.lines + 1] = true
        at = stop + 1
      else
        break
      end
    end
  end
  -- ComputerCraft calls a screen's methods with a dot (`term.write(text)`), so
  -- they are defined that way here. `env.terminal()` passes the screen as the
  -- first argument, which suits both conventions.
  --
  -- `write` does both jobs: it feeds the linear record above, and it paints the
  -- grid at the cursor. The two are deliberately separate models -- the first
  -- answers about a program that prints, the second about a program that draws --
  -- but they read the same text, so a wrapping bug shows up in the first and a
  -- layout bug in the second without either being arranged for the other.
  screen.write = function(text)
    text = tostring(text)
    collect(text)
    local x, y = screen.cursor[1], screen.cursor[2]
    for index = 1, #text do
      local char = text:sub(index, index)
      if char == "\n" then
        x, y = 1, y + 1
      else
        M.pixel(screen, x, y, char, screen.colour, screen.backgroundColour)
        x = x + 1
        if x > screen.size[1] then
          -- A real screen carries the character onto the next row rather than
          -- losing it, which is why the program has to wrap before this happens.
          x, y = 1, y + 1
        end
      end
    end
    screen.cursor = { x, y }
  end
  -- Deliberately no `readLine`. The real `term` module has no such method, and
  -- supplying one here is what let a program that called it pass: the mock
  -- answered, real hardware returned nil, and nil was read as end of input, so
  -- the REPL exited after its banner and every permission prompt denied in
  -- silence. A mock that offers an API the target does not have will happily
  -- pass code that cannot run, which is the whole reason this file exists.
  screen.clear = function()
    screen.cleared = screen.cleared + 1
    -- The frame that is ending, kept, because the cells afterwards say what the
    -- program settled on rather than what it put on screen on the way there. A
    -- permission dialog is the case that needs it: the question is drawn, read,
    -- and taken off again in one call, and a test that looks at the screen
    -- afterwards finds an empty one and concludes the dialog was never shown.
    --
    -- A copy, since the grid below is about to be emptied. `cleared` counts the
    -- same moments, so a test counting repaints and a test reading one both work
    -- off the same place.
    if #screen.frames >= M.MAX_FRAMES then
      table.remove(screen.frames, 1)
    end
    screen.frames[#screen.frames + 1] = {
      grid = M.copyGrid(screen.grid),
      fg = M.copyGrid(screen.gridFg),
      bg = M.copyGrid(screen.gridBg),
    }
    for index = 1, #screen.grid do
      screen.grid[index] = " "
      screen.gridBg[index] = nil
    end
    screen.cursor = { 1, 1 }
  end
  screen.scroll = function() end
  screen.setCursorBlink = function(state)
    screen.cursorBlink = state
  end
  screen.setCursorPos = function(x, y)
    -- Clamped rather than refused, as a real screen does, so a caller that asks
    -- for a cell past the edge still gets a usable cursor.
    screen.cursor = {
      math.min(math.max(math.floor(tonumber(x) or 1), 1), screen.size[1]),
      math.min(math.max(math.floor(tonumber(y) or 1), 1), screen.size[2]),
    }
  end
  screen.getCursorPos = function()
    return screen.cursor[1], screen.cursor[2]
  end
  screen.setTextColor = function(colour)
    screen.colour = colour
  end
  screen.setBackgroundColor = function(colour)
    screen.backgroundColour = colour
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
