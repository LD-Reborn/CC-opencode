local t = ...

local M = {}

--- Run the whole suite. Called from run.lua and from the single-file bundle's
--- self-test mode.
function M.main()
  return require("run").run(arg and arg[1])
end

return M
