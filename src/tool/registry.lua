-- Tool registry.
--
-- A tool is `{ id, description, parameters, execute }` where `parameters` is a
-- JSON Schema object describing the tool's arguments. `execute(args, ctx)`
-- returns `{ title, metadata, output }`, or raises with a string to signal a tool
-- error that is reported back to the model.

local json = require("json")
local util = require("util")
local permission = require("permission")
local truncate = require("truncate")

local M = {}

M.builtin = {}

local BUILTIN_MODULES = {
  "tool/lua",
  "tool/bash",
  "tool/read",
  "tool/write",
  "tool/edit",
  "tool/glob",
  "tool/grep",
  "tool/webfetch",
  "tool/todowrite",
}

--- Load the built-in tool modules so their `define` calls have run.
--
-- Idempotent, and deliberately not done at the bottom of this file. Each tool
-- module requires the registry back, so a tool required while the registry is
-- still loading is a require cycle: `require` marks the module it is loading with
-- a sentinel in `package.loaded` and refuses to resolve the inner call. Calling
-- this from the agent loop or `/tools` happens once the registry is complete, and
-- `M.loaded` makes even a second call a no-op.
function M.load()
  if M.loaded then
    return M.builtin
  end
  M.loaded = true
  for _, name in ipairs(BUILTIN_MODULES) do
    require(name)
  end
  return M.builtin
end

--- Declare a tool. Keeping this in one place makes the schema and the executor
--- impossible to drift apart.
function M.define(spec)
  M.builtin[#M.builtin + 1] = {
    id = spec.id,
    description = spec.description,
    parameters = spec.parameters,
    execute = spec.execute,
  }
end

--- Convert a tool into the OpenAI wire shape.
function M.toWire(tool)
  return {
    type = "function",
    ["function"] = {
      name = tool.id,
      description = tool.description,
      parameters = tool.parameters,
    },
  }
end

function M.list(enabled)
  M.load()
  if not enabled then
    return M.builtin
  end
  local out = {}
  for _, tool in ipairs(M.builtin) do
    if enabled[tool.id] ~= false then
      out[#out + 1] = tool
    end
  end
  return out
end

function M.get(id)
  M.load()
  for _, tool in ipairs(M.builtin) do
    if tool.id == id then
      return tool
    end
  end
  return nil
end

function M.ids(enabled)
  local out = {}
  for _, tool in ipairs(M.list(enabled)) do
    out[#out + 1] = tool.id
  end
  return out
end

--- Request approval for a tool action, honouring the session ruleset.
-- Returns true when allowed, or raises a permission error the model will see.
function M.guard(ctx, permissionID, patterns, always, title)
  local decision = permission.ask({
    permission = permissionID,
    patterns = patterns or { "*" },
    always = always or patterns or { "*" },
    ruleset = ctx.permission,
    session = ctx.session,
    monitor = ctx.monitor,
    title = title,
  })
  if decision == permission.ALLOW then
    return true
  end
  if util.startswith(decision, "feedback:") then
    error("Permission denied by the user: " .. decision:sub(10), 0)
  end
  error("Permission denied by the user for " .. permissionID .. ": " .. table.concat(patterns or {}, ", "), 0)
end

local truncateLimits

function M.limits(config)
  if not truncateLimits or truncateLimits.config ~= config then
    local options = (config and config.tool_output) or {}
    truncateLimits = {
      config = config,
      maxLines = options.max_lines or truncate.MAX_LINES,
      maxBytes = options.max_bytes or truncate.MAX_BYTES,
    }
  end
  return truncateLimits
end

--- Apply output limits unless the tool already reported its own truncation.
function M.finish(tool, ctx, result)
  if result.metadata and result.metadata.truncated ~= nil then
    return result
  end
  local limits = M.limits(ctx.config)
  local truncated = truncate.output(result.output, {
    maxLines = limits.maxLines,
    maxBytes = limits.maxBytes,
    direction = "head",
  })
  if truncated == result.output then
    return result
  end
  result.metadata = result.metadata or {}
  result.metadata.truncated = true
  result.output = truncated
  return result
end

--- Run one tool by id, converting failures into a structured result.
function M.execute(id, rawArguments, ctx)
  local tool = M.get(id)
  if not tool then
    return {
      status = "error",
      error = "Unknown tool '" .. id .. "'. Available tools: " .. table.concat(M.ids(ctx.enabled), ", "),
    }
  end
  local arguments = type(rawArguments) == "table" and json.dropNulls(rawArguments) or {}

  local ok, result = pcall(tool.execute, arguments, ctx)
  if not ok then
    local message = tostring(result):gsub("^.-:%d+: ", "")
    if message:find("Permission denied") then
      return { status = "denied", error = message }
    end
    return { status = "error", error = message }
  end

  result = M.finish(tool, ctx, result)
  return { status = "completed", title = result.title, output = result.output, metadata = result.metadata }
end

return M
