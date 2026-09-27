-- Test harness and runner. Usage: lua test/run.lua [filter]

local root = arg[0]:match("^(.*)/test/run%.lua$") or "."
package.path = table.concat({
  root .. "/src/?.lua",
  root .. "/test/?.lua",
  package.path,
}, ";")

local mock = require("cc-mock")

local M = {}

M.results = { passed = 0, failed = 0, failures = {} }
M.currentSuite = "?"

function M.suite(name)
  M.currentSuite = name
end

local function label(name)
  return M.currentSuite .. " :: " .. name
end

function M.ok(condition, message)
  if condition then
    M.results.passed = M.results.passed + 1
    return
  end
  M.results.failed = M.results.failed + 1
  M.results.failures[#M.results.failures + 1] = label(message)
end

function M.eq(actual, expected, message)
  if actual == expected then
    M.results.passed = M.results.passed + 1
    return
  end
  M.results.failed = M.results.failed + 1
  M.results.failures[#M.results.failures + 1] = string.format(
    "%s\n    expected: %s\n    actual:   %s",
    label(message), tostring(expected), tostring(actual)
  )
end

function M.contains(haystack, needle, message)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    M.results.passed = M.results.passed + 1
    return
  end
  M.results.failed = M.results.failed + 1
  M.results.failures[#M.results.failures + 1] = string.format(
    "%s\n    expected to contain: %s\n    actual: %s",
    label(message), tostring(needle), tostring(haystack)
  )
end

function M.notContains(haystack, needle, message)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    M.results.passed = M.results.passed + 1
    return
  end
  M.results.failed = M.results.failed + 1
  M.results.failures[#M.results.failures + 1] = string.format(
    "%s\n    expected not to contain: %s\n    actual: %s",
    label(message), tostring(needle), tostring(haystack)
  )
end

function M.report()
  print("")
  if #M.results.failures > 0 then
    print(string.format("FAILURES (%d)", #M.results.failures))
    for _, failure in ipairs(M.results.failures) do
      print("  - " .. failure)
    end
  end
  print(string.format(
    "%d passed, %d failed, %d total",
    M.results.passed, M.results.failed, M.results.passed + M.results.failed
  ))
  return M.results.failed == 0
end

M.mock = mock
M.root = root

function M.run(filter)
  mock.install()
  mock.setup()

  local suites = { "json", "util", "pattern", "provider", "http", "llm", "truncate", "tools", "agent", "cli", "install" }
  local missing = {}
  for _, name in ipairs(suites) do
    if not filter or name:find(filter, 1, true) then
      local chunk, loadError = loadfile(root .. "/test/spec-" .. name .. ".lua")
      if not chunk then
        missing[#missing + 1] = name .. " (" .. tostring(loadError) .. ")"
      else
        M.suite(name)
        -- Each spec file returns a function; run it with the harness.
        local spec = chunk()
        if type(spec) == "function" then
          spec(M, mock)
        else
          M.ok(false, "spec-" .. name .. " did not return a function")
        end
      end
    end
  end
  if #missing > 0 then
    print("MISSING SPECS: " .. table.concat(missing, ", "))
  end

  return M.report()
end

-- Invoked directly (`lua test/run.lua [filter]`) rather than required by main.lua.
if arg and arg[0] and arg[0]:match("run%.lua$") then
  os.exit(M.run(arg[1]) and 0 or 1)
end

return M
