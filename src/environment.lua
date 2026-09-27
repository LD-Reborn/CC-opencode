-- ComputerCraft environment access.
--
-- Every CC API the project touches goes through this module so the rest of the
-- code has no direct `fs`/`shell`/`http` references. The test harness swaps in a
-- mock with the same surface, which is how the agent loop is exercised without
-- a Minecraft client.

-- `util` is the only project module this one reaches for, and only for its
-- word-breaking, because undoing a hardware habit belongs at the boundary with
-- the hardware. It requires nothing back, so the dependency is one-way.
local util = require("util")

local M = {}

M.isCC = type(shell) == "table" and type(fs) == "table"

-- Defined here rather than required from `util` so the environment layer stays
-- the one module that knows about the two string primitives it needs itself.
local function startswith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function endswith(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

M.startswith, M.endswith = startswith, endswith

function M.cwd()
  if not M.isCC then
    return (os.getenv and os.getenv("PWD")) or "/"
  end
  return shell.dir()
end

function M.combine(...)
  if M.isCC then
    return fs.combine(...)
  end
  local parts = { ... }
  local out = "/"
  for _, part in ipairs(parts) do
    if part == nil or part == "" then
      -- skip
    elseif out == "/" then
      out = "/" .. tostring(part)
    else
      out = out .. "/" .. tostring(part)
    end
  end
  return (out:gsub("//+", "/"))
end

function M.dirname(path)
  if M.isCC then
    return fs.getDir(path)
  end
  local dir = path:match("^(.*)/[^/]*$")
  if not dir or dir == "" then
    return "/"
  end
  return dir
end

function M.basename(path)
  if M.isCC then
    return fs.getName(path)
  end
  return path:match("([^/]*)$") or path
end

function M.isAbsolute(path)
  return M.startswith(path or "", "/")
end

--- Resolve `path` against `base` and normalise "." and ".." segments.
function M.resolve(path, base)
  local absolute = M.isAbsolute(path) and path or M.combine(base or M.cwd(), path)
  local parts = {}
  for segment in absolute:gmatch("[^/]+") do
    if segment == "." then
      -- skip
    elseif segment == ".." then
      parts[#parts] = nil
    else
      parts[#parts + 1] = segment
    end
  end
  return "/" .. table.concat(parts, "/")
end

--- True when `path` is `root` or lives inside it.
function M.contains(root, path)
  if root == path then
    return true
  end
  if M.endswith(root, "/") then
    return M.startswith(path, root)
  end
  return M.startswith(path, root .. "/")
end

function M.exists(path)
  if M.isCC then
    return fs.exists(path)
  end
  local handle = io.open(path, "r")
  if handle then
    handle:close()
    return true
  end
  -- Directories are not readable as files, so fall back to a probe.
  local pipe = io.popen("test -e " .. M.quote(path) .. " && echo yes")
  if not pipe then
    return false
  end
  local out = pipe:read("*a")
  pipe:close()
  return out == "yes"
end

function M.isDir(path)
  if M.isCC then
    return fs.isDir(path)
  end
  local pipe = io.popen("test -d " .. M.quote(path) .. " && echo yes")
  if not pipe then
    return false
  end
  local out = pipe:read("*a")
  pipe:close()
  return out == "yes"
end

function M.size(path)
  if M.isCC then
    return fs.getSize(path)
  end
  local handle = io.open(path, "rb")
  if not handle then
    return 0
  end
  local size = handle:seek("end")
  handle:close()
  return size
end

function M.modified(path)
  if M.isCC then
    return fs.attributes(path, "modification") or 0
  end
  local pipe = io.popen("date -r " .. M.quote(path) .. " +%s 2>/dev/null")
  if not pipe then
    return 0
  end
  local out = pipe:read("*a")
  pipe:close()
  return tonumber(out) or 0
end

function M.mkdir(path)
  if M.isCC then
    return fs.makeDir(path)
  end
  return os.execute("mkdir -p " .. M.quote(path))
end

--- Create `path` and every missing parent, ignoring directories that already exist.
function M.mkdirs(path)
  local current = "/"
  for segment in path:gmatch("[^/]+") do
    current = current .. segment
    if not M.isDir(current) then
      M.mkdir(current)
    end
    current = current .. "/"
  end
  return M.isDir(path)
end

function M.read(path)
  if M.isCC then
    local handle = fs.open(path, "r")
    if not handle then
      return nil
    end
    local content = handle.readAll()
    handle.close()
    return content
  end
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

--- Read at most `limit` bytes, reporting whether the file was cut short.
function M.readLimited(path, limit)
  local size = M.size(path)
  if limit and size > limit then
    if M.isCC then
      local handle = fs.open(path, "r")
      if not handle then
        return nil
      end
      local chunk = handle.read(limit) or ""
      handle.close()
      return chunk, true
    end
    local handle = io.open(path, "rb")
    if not handle then
      return nil
    end
    local chunk = handle:read(limit) or ""
    handle:close()
    return chunk, true
  end
  return M.read(path), false
end

function M.write(path, content)
  if M.isCC then
    local handle = fs.open(path, "w")
    if not handle then
      return false
    end
    handle.write(content)
    handle.close()
    return true
  end
  local handle = io.open(path, "wb")
  if not handle then
    return false
  end
  handle:write(content)
  handle:close()
  return true
end

function M.append(path, content)
  if M.isCC then
    local handle = fs.open(path, "a")
    if not handle then
      return false
    end
    handle.write(content)
    handle.close()
    return true
  end
  local handle = io.open(path, "ab")
  if not handle then
    return false
  end
  handle:write(content)
  handle:close()
  return true
end

function M.remove(path)
  if M.isCC then
    return fs.delete(path)
  end
  return os.remove(path)
end

function M.rename(from, to)
  if fs and fs.posix then
    local ok = fs.posix.rename(from, to)
    if ok then
      return true
    end
  end
  if not os.rename(from, to) then
    return false
  end
  return true
end

--- Entry names in a directory, sorted, excluding "." and "..".
function M.listDir(path)
  local names = {}
  if M.isCC then
    for _, name in ipairs(fs.list(path)) do
      names[#names + 1] = name
    end
  else
    local pipe = io.popen("ls -A " .. M.quote(path) .. " 2>/dev/null")
    if pipe then
      for name in pipe:lines() do
        names[#names + 1] = name
      end
      pipe:close()
    end
  end
  table.sort(names)
  return names
end

--- Walk `path` depth-first, calling `onFile` and `onDir` with absolute paths.
-- `onDir` returning false skips that subtree.
function M.walk(path, options)
  local onFile = options.onFile or function() end
  local onDir = options.onDir or function() end
  local includeHidden = options.includeHidden
  local maxDepth = options.maxDepth or 32

  local function visit(dir, depth)
    if depth > maxDepth or not M.isDir(dir) then
      return
    end
    for _, name in ipairs(M.listDir(dir)) do
      if includeHidden or not M.startswith(name, ".") then
        local full = dir .. (dir == "/" and "" or "/") .. name
        if M.isDir(full) then
          if onDir(full, name) ~= false then
            visit(full, depth + 1)
          end
        else
          onFile(full, name)
        end
      end
    end
  end

  visit(path, 1)
end

--- Single-quote a value for the ComputerCraft shell.
function M.quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.now()
  if os.date then
    return os.date("%c")
  end
  return "unknown"
end

function M.today()
  if os.date then
    return os.date("%Y-%m-%d")
  end
  return "unknown"
end

function M.computerLabel()
  if M.isCC and os.getComputerLabel then
    return os.getComputerLabel() or "computer"
  end
  return "host"
end

--- A screen presenting the same methods whether it is a monitor or a terminal.
--
-- Monitors and terminals are nearly the same API, but neither is a superset of
-- the other, and the REPL should not have to care which one it got.
--
-- `write` is also where text is wrapped, and it is here rather than in the REPL
-- for two reasons. It is the one place every drawn character passes through —
-- a line of the conversation and a question from the permission prompt alike —
-- so a new caller cannot get it wrong by forgetting. And it is a property of the
-- hardware rather than of the interface: ComputerCraft does not carry a line
-- that overruns its screen, so a 51-column terminal loses the end of every long
-- line, the tail of every url, and the part of an error message that says what
-- to do about it. The column is carried between calls because a reply arrives in
-- pieces and each piece has to be broken knowing where the last one finished.
local function adapt(screen)
  -- ComputerCraft calls these with a dot — `term.write(text)`, not
  -- `term:write(text)` — so the screen must not be passed back in.
  local function call(name, ...)
    local method = screen[name]
    if not method then
      return nil
    end
    return method(...)
  end

  -- The column the next character will land in, counting from 1. Only what this
  -- screen has been told moves it: `read` echoes onto the terminal and puts the
  -- cursor somewhere this cannot see, which is why the REPL writes its blank
  -- line before the next prompt and so re-synchronises it for free.
  local column = 1

  --- The usable width: the screen's, less the last column.
  --
  -- The last column is left alone on purpose. Filling it is what puts a
  -- ComputerCraft screen in a state where what happens next depends on the
  -- version — continued on the next row, or thrown away — and neither is worth
  -- betting a line of output on.
  local function limit()
    local ok, width = pcall(function()
      return screen.getSize()
    end)
    if ok and type(width) == "number" and width >= 8 then
      return width - 1
    end
    return 50
  end

  --- Write `text`, wrapped, with the newlines in it honoured.
  local function write(text)
    if text == nil then
      return nil
    end
    text = tostring(text)
    local rows = {}
    local at = 1
    while at <= #text do
      local stop = text:find("\n", at, true)
      local piece = text:sub(at, (stop or (#text + 1)) - 1)
      if piece ~= "" then
        local room = limit() - column + 1
        -- Nothing worth wrapping into, so move along a row rather than break
        -- words two characters at a time.
        if room < 8 then
          rows[#rows + 1] = "\n"
          column = 1
          room = limit()
        end
        if #piece > room then
          -- Fill what is left of this row, breaking at a space where there is
          -- one, then wrap the remainder at the full width rather than at
          -- whatever happened to be left over. A reply that spills ten
          -- characters past the margin has to carry on at full width: wrapping
          -- the rest of it into a column ten wide would fit a third of it on
          -- the screen.
          local head = util.wrap(piece, room)[1]
          rows[#rows + 1] = head
          rows[#rows + 1] = "\n"
          local rest = util.wrap(util.trim(piece:sub(#head + 1)), limit())
          for i, row in ipairs(rest) do
            rows[#rows + 1] = row
            if i < #rest then
              rows[#rows + 1] = "\n"
            else
              column = #row + 1
            end
          end
        else
          rows[#rows + 1] = piece
          column = column + #piece
        end
      end
      if stop then
        rows[#rows + 1] = "\n"
        column = 1
        at = stop + 1
      else
        at = #text + 1
      end
    end
    return call("write", table.concat(rows))
  end

  return {
    raw = screen,
    isMonitor = screen ~= term,
    write = write,
    clear = function() return call("clear") end,
    scroll = function() return call("scroll") end,
    setCursorBlink = function(state) return call("setCursorBlink", state) end,
    setCursorPos = function(x, y) return call("setCursorPos", x, y) end,
    setTextColor = function(colour) return call("setTextColor", colour) end,
    getCursorPos = function() return call("getCursorPos") end,
    getSize = function() return call("getSize") end,
  }
end

--- Prepare a screen for drawing on, or nil.
--
-- `M.terminal` is the usual way in; this is for a screen the caller already has.
-- It exists so that there is no way to hand the program something it will draw
-- on without the text being wrapped: the wrapping is the adapter's, and a raw
-- screen is not adapted, so every path in has to come through here. Adapting an
-- adapted screen gives it straight back, so there is no order to get right.
function M.screen(raw)
  if raw == nil then
    return nil
  end
  if raw.raw ~= nil then
    return raw
  end
  return adapt(raw)
end

--- The best available screen, or nil when there is neither a monitor nor a
--- terminal. Monitors are preferred, so a multi-computer setup prints to the
--- monitor rather than to the computer nobody is looking at.
function M.terminal()
  if peripheral and peripheral.find then
    for _, name in ipairs({ "left", "right", "monitor_1", "monitor_2", "monitor_3" }) do
      local monitor = peripheral.find(name)
      if monitor then
        return adapt(monitor)
      end
    end
  end
  if term then
    return adapt(term)
  end
  return nil
end

--- The computer's own terminal, unwrapped, or nil.
--
-- `M.terminal` prefers a monitor, which is right for a program that prints and
-- exits but wrong for one the operator has to type into: CraftOS's keyboard
-- belongs to the terminal, and `read` reads the terminal whatever the program
-- happens to be drawing on. An input field drawn on a monitor is a field nobody
-- can reach, so the GUI draws here.
function M.console()
  if M.isCC and type(term) == "table" and type(term.getSize) == "function" then
    return term
  end
  return nil
end

--- The remaining CraftOS primitives, for the UI, each absent rather than broken.
--
-- A GUI needs to draw boxes (`paintutils`), name a key code (`keys`), and block
-- until the operator does something (`os.pullEvent`). All of them are read off the
-- globals once, and each is nil when this build of CraftOS does not have it, so
-- that a caller can ask "is there a screen to draw on" instead of calling into
-- nothing. The UI cannot do without `pullEvent`; the rest it degrades on.
function M.system()
  if not M.isCC then
    return {}
  end
  return {
    paint = type(paintutils) == "table" and paintutils or nil,
    keyName = (type(keys) == "table" and type(keys.getName) == "function") and keys.getName or nil,
    pullEvent = (type(os.pullEvent) == "function") and os.pullEvent or nil,
    startTimer = (type(os.startTimer) == "function") and os.startTimer or nil,
    cancelTimer = (type(os.cancelTimer) == "function") and os.cancelTimer or nil,
    -- Seconds since the computer started. `os.timer` is wall-clock and so keeps
    -- moving while the program is blocked on the network, which is where a reply
    -- streams in; `os.clock` is CPU time and only counts the program's own work.
    -- The UI throttles its repaints with the first and falls back to the second,
    -- where a repaint of a screen this small costs less than the reading around it.
    timer = (type(os.timer) == "function") and os.timer or nil,
    clock = (type(os.clock) == "function") and os.clock or nil,
  }
end

--- Read one line of input from the operator, or nil at end of input.
--
-- This is CraftOS's global `read`, not a method on a screen, and the difference
-- is the whole of it. The `term` module is blit, clear, getCursorPos, getSize,
-- native, redirect, scroll, setBackgroundColour, setCursorBlink, setCursorPos,
-- setTextColour, and write -- there is no `readLine` on it. A screen asked for one
-- answers nil, which is indistinguishable from the operator closing the program,
-- and both callers here treated nil that way: the REPL exited straight after the
-- banner, and every permission prompt denied without ever asking. CC's own shell
-- reads its line this way, and gets line editing, history and tab completion for
-- it, none of which a hand-rolled key loop would have matched.
--
-- Named `readLine` rather than `read` because `M.read` is already the file reader
-- that `config` uses to fetch a key from disk, and one function cannot be both.
--
-- Wrapped rather than called as a global so that every CC API the project touches
-- is still visible in this one file, and so the harness can stand in for it.
function M.readLine()
  if type(read) ~= "function" then
    return nil
  end
  return read()
end

return M
