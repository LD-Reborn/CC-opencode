-- Permission rules and the interactive approval prompt.
--
-- Evaluation follows opencode: the last matching rule across the ruleset wins,
-- and the default when nothing matches is "ask". Approvals granted for the
-- session are appended to the session ruleset so later calls are silent.

local util = require("util")

local M = {}

M.ALLOW, M.DENY, M.ASK = "allow", "deny", "ask"

--- Last rule matching both permission and pattern, or an implicit "ask".
function M.evaluate(permission, pattern, ...)
  local rulesets = { ... }
  local found = nil
  for _, ruleset in ipairs(rulesets) do
    for _, rule in ipairs(ruleset or {}) do
      local rulePermission = rule.permission or rule[1] or "*"
      local rulePattern = rule.pattern or rule[2] or "*"
      if util.wildcard(permission, rulePermission) and util.wildcard(pattern, rulePattern) then
        found = { action = rule.action or rule[3] or M.ASK, permission = permission, pattern = pattern }
      end
    end
  end
  return found or { action = M.ASK, permission = permission, pattern = pattern }
end

--- Check a set of patterns at once, returning "allow", "deny" or "ask".
function M.evaluateAll(permission, patterns, ...)
  local needsAsk = false
  for _, pattern in ipairs(patterns) do
    local rule = M.evaluate(permission, pattern, ...)
    if rule.action == M.DENY then
      return M.DENY, pattern
    end
    if rule.action == M.ASK then
      needsAsk = true
    end
  end
  if needsAsk then
    return M.ASK
  end
  return M.ALLOW
end

--- Read a single line from a monitor, returning nil on end of input.
local function prompt(question, monitor)
  if not monitor or not term then
    return "n"
  end
  monitor.write(question)
  monitor.setCursorBlink(true)
  local line = monitor.readLine()
  monitor.setCursorBlink(false)
  if line == nil then
    return "n"
  end
  return util.trim(line):lower()
end

--- Ask the operator to approve `permission` for `patterns`.
--
-- Returns "allow", "deny", or "feedback:<message>" — a rejection carrying the
-- operator's explanation, which the agent loop feeds back to the model so it can
-- correct course instead of retrying blindly.
function M.ask(input)
  if input.ruleset then
    local action = M.evaluateAll(input.permission, input.patterns, input.ruleset)
    if action ~= M.ASK then
      return action
    end
  end

  local patterns = input.patterns or { "*" }
  local shown = {}
  for index, pattern in ipairs(patterns) do
    if index > 4 then
      shown[#shown + 1] = string.format("  ...and %d more", #patterns - 4)
      break
    end
    shown[#shown + 1] = "  " .. pattern
  end

  local lines = { string.format("Permission required: %s", input.permission), table.concat(shown, "\n") }
  if input.title then
    lines[#lines + 1] = input.title
  end
  lines[#lines + 1] = "[y] once  [a] always  [n] no"

  local reply = prompt(table.concat(lines, "\n") .. "\n> ", input.monitor)
  if reply == "y" or reply == "yes" then
    return M.ALLOW
  end
  if reply == "a" or reply == "always" then
    for _, pattern in ipairs(input.always or patterns) do
      input.session.permission[#input.session.permission + 1] = {
        permission = input.permission,
        pattern = pattern,
        action = M.ALLOW,
      }
    end
    return M.ALLOW
  end
  if reply == "n" or reply == "no" or reply == "" then
    return M.DENY
  end
  return "feedback:" .. reply
end

--- Normalise a config permission entry into a ruleset.
function M.ruleset(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "string" then
      out[#out + 1] = { permission = entry, pattern = "*", action = M.ALLOW }
    elseif type(entry) == "table" then
      out[#out + 1] = {
        permission = entry.permission or "*",
        pattern = entry.pattern or "*",
        action = entry.action or M.ALLOW,
      }
    end
  end
  return out
end

return M
