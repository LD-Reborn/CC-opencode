-- Permission rules and the interactive approval prompt.
--
-- Evaluation follows opencode: the last matching rule across the ruleset wins,
-- and the default when nothing matches is "ask". Approvals granted for the
-- session are appended to the session ruleset so later calls are silent.

local util = require("util")
local env = require("environment")

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

--- Ask the operator one question, returning "n" at end of input.
--
-- The answer comes from CraftOS's `read`, not from a screen: `term` has no
-- `readLine`, so a screen answered nil here, and nil was read as "no" -- which
-- made every `ask` rule deny silently, with no question ever put to anyone. An
-- unattended denial is the safe direction to fail, but a prompt that cannot be
-- seen is not a prompt.
local function prompt(question, monitor)
  if not monitor or not term or not env.isCC then
    return "n"
  end
  monitor.write(question)
  local line = env.readLine()
  if line == nil then
    return "n"
  end
  return util.trim(line):lower()
end

--- Put the question on screen and get the answer back, whichever screen this is.
--
-- A UI screen is asked itself, because that is the whole reason it exists: `read`
-- draws nothing, so the question went to a monitor nobody was reading while the
-- answer was typed blind at the terminal. A plain screen is not, and the question
-- goes down the path above unchanged -- `--plain` is meant to be the screen this
-- program had before, byte for byte, and a change to its prompt would be a change
-- to what it is for.
--
-- The `ask` method is the interface, and the check is for its existence rather
-- than for this module knowing what kind of screen it has been handed.
local function askOn(screen, title, permission, patterns)
  if not screen or type(screen.ask) ~= "function" then
    return nil
  end
  local reply = screen:ask({ title = title, permission = permission, patterns = patterns })
  if reply == nil then
    return "n"
  end
  return util.trim(reply):lower()
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
  local monitor = input.monitor

  -- The plain path's question, a function so that a UI screen never builds it: the
  -- text here is four lines for a dialog, and a dialog that renders it as a dialog
  -- is not a dialog with a header, buttons and a hint line.
  local function plainQuestion()
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
    return table.concat(lines, "\n") .. "\n> "
  end

  local reply = askOn(monitor, input.title, input.permission, patterns)
  if reply == nil then
    reply = prompt(plainQuestion(), monitor)
  end
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
