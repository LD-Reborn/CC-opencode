-- The `lua` tool: run arbitrary Lua code in the CraftOS environment.
--
-- The code runs with `loadstring` in a sandboxed coroutine. Output is
-- captured by redirecting `print` to a buffer. The code has access to
-- the full CraftOS API (fs, shell, http, term, peripheral, etc.) and
-- all standard Lua libraries available in CC.

local util = require("util")
local truncate = require("truncate")
local registry = require("tool/registry")

local DEFAULT_TIMEOUT_MS = 30000

local DESCRIPTION = [[Executes Lua code in the ComputerCraft environment and returns the output.

The code runs with full access to the CraftOS API:
- fs (filesystem), shell, http, term, peripheral, colors, keys, paintutils, os, etc.
- All standard Lua libraries available in CC (string, table, math, coroutine, etc.)

Usage notes:
  - The code argument is required.
  - You can specify an optional timeout in milliseconds. Code times out after
    30000ms by default.
  - Use print() to return output. The last expression's value is NOT auto-printed.
  - Output longer than the truncation limit is tail-truncated.
  - You can issue several independent lua calls in one message; they run in order.
  - The code runs in the same CraftOS instance, so it can interact with peripherals,
    redstone, turtles, and the filesystem directly.]]

--- Capture print output by temporarily replacing the global print.
local function capturePrint(fn)
  local lines = {}
  local original = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(fn)
  _G.print = original
  return ok, err, table.concat(lines, "\n")
end

--- Run Lua code with a timeout using coroutines.
local function runWithTimeout(code, timeoutMs)
  -- loadstring is Lua 5.1; load is 5.2+. CC uses 5.1 or 5.2 depending on version.
  local chunk, compileErr
  if loadstring then
    chunk, compileErr = loadstring(code)
  else
    chunk, compileErr = load(code)
  end
  if not chunk then
    return false, "compile error: " .. tostring(compileErr), ""
  end

  local co = coroutine.create(chunk)
  local timerId
  if os.startTimer then
    timerId = os.startTimer(math.ceil(timeoutMs / 1000))
  end

  local ok, err
  while true do
    if coroutine.status(co) == "dead" then
      break
    end
    if timerId then
      local event = { os.pullEvent() }
      if event[1] == "timer" and event[2] == timerId then
        return false, string.format("timeout: code exceeded %d ms", timeoutMs), ""
      end
      -- Re-queue the event so the coroutine can see it
      os.queueEvent(unpack(event))
    end
    ok, err = coroutine.resume(co)
    if not ok then
      break
    end
  end

  if timerId and os.cancelTimer then
    os.cancelTimer(timerId)
  end

  if not ok then
    return false, tostring(err), ""
  end
  return true, nil, ""
end

registry.define({
  id = "lua",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      code = { type = "string", description = "The Lua code to execute" },
      timeout = {
        type = "number",
        description = "Optional timeout in milliseconds. Defaults to 30000.",
      },
    },
    required = { "code" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local code = args.code
    if type(code) ~= "string" or util.trim(code) == "" then
      error("The code argument is required.", 0)
    end
    local timeout = tonumber(args.timeout) or DEFAULT_TIMEOUT_MS
    if timeout < 0 then
      error("Invalid timeout value: " .. tostring(args.timeout) .. ". Timeout must be a positive number.", 0)
    end

    registry.guard(ctx, "lua", { "*" }, { "*" }, "lua")

    local ok, err, captured = capturePrint(function()
      return runWithTimeout(code, timeout)
    end)

    local output = captured or ""
    if not ok then
      output = (output ~= "" and output .. "\n" or "") .. "Error: " .. tostring(err)
    end

    local limits = registry.limits(ctx.config)
    output = truncate.output(output, {
      maxLines = limits.maxLines,
      maxBytes = limits.maxBytes,
      direction = "tail",
    })
    if output == "" then
      output = "(no output)"
    end

    return {
      title = "lua",
      metadata = { output = output },
      output = output,
    }
  end,
})

return true
