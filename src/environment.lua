-- ComputerCraft environment access.
--
-- Every CC API the project touches goes through this module so the rest of the
-- code has no direct `fs`/`shell`/`http` references. The test harness swaps in a
-- mock with the same surface, which is how the agent loop is exercised without
-- a Minecraft client.

local M = {}

M.isCC = type(shell) == "table" and type(fs) == "table"

-- Defined here rather than required from `util` so the environment layer stays
-- the one module that depends on nothing else.
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
    for _, name in ipairs(fs.dir(path)) do
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
  return {
    raw = screen,
    isMonitor = screen ~= term,
    write = function(text) return call("write", text) end,
    readLine = function() return call("readLine") end,
    clear = function() return call("clear") end,
    scroll = function() return call("scroll") end,
    setCursorBlink = function(state) return call("setCursorBlink", state) end,
    setCursorPos = function(x, y) return call("setCursorPos", x, y) end,
    setTextColor = function(colour) return call("setTextColor", colour) end,
    getCursorPos = function() return call("getCursorPos") end,
    getSize = function() return call("getSize") end,
  }
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

return M
