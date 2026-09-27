-- opencode for ComputerCraft: the entry point.
--
-- Two ways to use it:
--
--   opencode                     interactive, on a monitor if one is attached
--   opencode "list the programs" one turn, print the answer, exit
--   opencode run "..."           the same, spelled out
--
-- Everything below is presentation: argument parsing, the REPL, and rendering the
-- agent's events onto a screen. The work itself is in src/agent.lua.

--- Locate the library relative to this program, so the modular checkout and the
--- single-file bundle both work without editing `package.path` by hand.
--
-- ComputerCraft hands every program its own `require` and its own `package`, and it
-- resolves relative search patterns against *the program's own directory*. That
-- directory is wherever the program was found, which is not wherever its library
-- is: `init.lua` sits beside `src/`, one level above the modules. So a plain
-- `require("util")` looks for `<dir>/util.lua`, finds nothing, and the program dies
-- before it can print a word.
--
-- Three absolute entries fix it, and the absoluteness is the whole of the fix. CC
-- reads `package.path` each time it looks a name up, so rebinding the field is
-- enough; and a pattern beginning with `/` is used as written, which is the one
-- case where the program directory is not joined onto the front of it. Without that
-- the entries would be resolved against the directory they were meant to get away
-- from.
--
-- The `src/` prefix cannot be a fourth entry, because a `src/?.lua` pattern only
-- answers to a name spelled `src/util` -- and spelling it that way on every require
-- would leave the bundle to unspell it. A path entry is the only way to say it.
--
-- A bundled program needs none of this: the bundle installs every module into
-- `package.preload` under its bare name, so the first searcher answers before the
-- path is ever consulted.
--
-- Once, too. The path is prepended, so a second call would prepend it again -- no
-- harm on a computer, which runs this once, but a test suite that loads the entry
-- point twenty times would leave twenty copies behind it.
local located = false

local function bootstrap()
  if located then
    return
  end
  located = true

  local program = (shell and shell.getRunningProgram and shell.getRunningProgram()) or ""
  local directory = program:match("^(.*)/[^/]*$")
  -- A program at the root matches as the empty string, which is already the one
  -- separator a path needs -- `"" .. "/?.lua"` is `/?.lua`. So only a program with
  -- no directory in it at all falls back to a relative path, and a doubled separator
  -- in the name is collapsed rather than joined.
  if not directory then
    directory = "."
  elseif directory == "/" then
    directory = ""
  end
  package.path = table.concat({
    directory .. "/?.lua",
    directory .. "/src/?.lua",
    directory .. "/src/?/init.lua",
    package.path,
  }, ";")
end

bootstrap()

local env = require("environment")
local util = require("util")
local config = require("config")
local provider = require("provider")
local session = require("session")
local agent = require("agent")
local registry = require("tool/registry")
local permission = require("permission")

local M = {}

M.AGENTS = { "build", "general", "plan", "explore" }

-- Colour is used sparingly: a monitor in a dark room does not need decoration, and
-- the light palette is a guess that is wrong about half the time anyway.
local WHITE, LIGHT_GRAY, YELLOW, RED = colors.white, colors.lightGray, colors.yellow, colors.red

--- Everything one invocation needs, rebuilt when /model or /agent changes it.
M.state = {}

local function out(monitor, text, colour)
  if not monitor then
    return
  end
  if colour then
    monitor.setTextColor(colour)
  end
  monitor.write(text)
  monitor.setTextColor(WHITE)
end

--- The terminal's width, or 51, which is what a Computer or Turtle gives you.
local function columns(monitor)
  local ok, width = pcall(function()
    return monitor.getSize()
  end)
  if ok and type(width) == "number" and width > 0 then
    return width
  end
  return 51
end

-- Every line the program draws goes through here, so wrapping once means no
-- message can be silently cut off: not an error, not a url, not a tool's output.
local function line(monitor, text, colour)
  for _, part in ipairs(util.wrap(text, columns(monitor))) do
    out(monitor, part .. "\n", colour)
  end
end

--- Shorten a tool's input to one line, for the activity log.
local function summarise(part)
  local input = part.state.input or {}
  for _, key in ipairs({ "filePath", "path", "pattern", "command", "url" }) do
    if type(input[key]) == "string" then
      local value = input[key]:gsub("\n", " ")
      if #value > 48 then
        value = value:sub(1, 45) .. "..."
      end
      return value
    end
  end
  for key, value in pairs(input) do
    if type(value) ~= "table" then
      return tostring(key) .. "=" .. tostring(value)
    end
  end
  return ""
end

--- Render the agent's events. This is the whole UI: one line per tool call, the
--- answer as it arrives, and a usage footer.
local function renderer(monitor)
  return function(event)
    if event.type == "text" then
      out(monitor, event.delta)
    elseif event.type == "reasoning" then
      line(monitor, "(reasoning) " .. event.text, LIGHT_GRAY)
    elseif event.type == "tool_start" then
      local part = event.part
      line(monitor, "  * " .. part.tool .. " " .. summarise(part), LIGHT_GRAY)
    elseif event.type == "tool_end" then
      local part = event.part
      if part.state.status == "error" then
        line(monitor, "    ! " .. tostring(part.state.error), RED)
      else
        -- A tool whose title is the thing the start line already named — read
        -- and webfetch, mostly — has nothing to add by repeating it.
        local detail = part.state.title or ""
        if detail ~= "" and detail ~= summarise(part) then
          line(monitor, "    " .. detail, LIGHT_GRAY)
        end
      end
    elseif event.type == "step_end" then
      local tokens = event.message.tokens
      if tokens and tokens.input and tokens.input > 0 then
        line(monitor, string.format("  (%d in, %d out)", tokens.input, tokens.output), LIGHT_GRAY)
      end
    elseif event.type == "compacted" then
      -- The conversation was summarised, so an answer may now rest on the
      -- summary. Saying so beats silently losing the detail.
      line(monitor, "(summarised the earlier conversation to fit the context window)", LIGHT_GRAY)
    elseif event.type == "error" then
      line(monitor, tostring(event.message), RED)
    elseif event.type == "aborted" then
      line(monitor, "(aborted)", YELLOW)
    end
  end
end

--- Resolve the configured model, returning nil plus the reason it cannot be used.
local function resolveModel(current)
  local resolved, err = provider.resolve(current.config, current.config.model)
  if not resolved then
    return nil, err
  end
  return resolved
end

--- Build the run context from the current state.
local function buildContext(monitor)
  local current = M.state
  return {
    session = current.session,
    config = current.config,
    model = current.model,
    smallModel = current.smallModel,
    agent = current.agent,
    root = current.root,
    cwd = current.cwd,
    permission = permission.ruleset(current.config.permission),
    enabled = current.enabled,
    monitor = monitor,
    stream = current.stream,
    on = renderer(monitor),
    -- ComputerCraft gives a program no way to be interrupted while it runs, so
    -- this never fires. It is here so the loop has one place to ask.
    aborted = function()
      return false
    end,
  }
end

-- Slash commands

local function banner(monitor, current)
  line(monitor, "opencode for ComputerCraft", LIGHT_GRAY)
  line(monitor, string.format("model: %s   agent: %s   dir: %s", current.config.model, current.agent, current.cwd), LIGHT_GRAY)
  line(monitor, "Type a question, or /help for commands.", LIGHT_GRAY)
end

local function help(monitor)
  line(monitor, "Commands:")
  line(monitor, "  /help           this list", LIGHT_GRAY)
  line(monitor, "  /model          show the current model", LIGHT_GRAY)
  line(monitor, "  /model <id>     switch to provider/model", LIGHT_GRAY)
  line(monitor, "  /models         models the config can reach", LIGHT_GRAY)
  line(monitor, "  /providers      the known providers and their keys", LIGHT_GRAY)
  line(monitor, "  /agent          show the current agent", LIGHT_GRAY)
  line(monitor, "  /agent <name>   switch agent (" .. table.concat(M.AGENTS, ", ") .. ")", LIGHT_GRAY)
  line(monitor, "  /tools          list the available tools", LIGHT_GRAY)
  line(monitor, "  /new            start a new session", LIGHT_GRAY)
  line(monitor, "  /save           save the session to disk", LIGHT_GRAY)
  line(monitor, "  /exit           quit", LIGHT_GRAY)
  line(monitor, "Anything else is sent to the model.", LIGHT_GRAY)
end

--- `/models` shows what the config can actually reach. A provider with no `models`
--- block cannot be listed, because nothing in the config says which model ids it
--- serves, so the hint points at the file rather than guessing.
--
--- The defaults declare one model, so this is not what a fresh install shows any
--- more. It is kept as a guard: `merge` only ever adds keys, so a config cannot
--- undeclare the default, but a future default that shipped none would otherwise
--- print an empty list and say nothing about why.
local function listModels(monitor, current)
  local models = provider.availableModels(current.config)
  if #models == 0 then
    line(monitor, "No models are listed in the config.", YELLOW)
    line(monitor, 'Add one under "provider" in opencode.json:', LIGHT_GRAY)
    line(monitor, '  "provider": {"groq": {"models": {"llama-3.3-70b": {"name": "Llama 3.3 70B"}}}}', LIGHT_GRAY)
    return
  end
  for _, entry in ipairs(models) do
    local note = entry.available and "" or "  (no api key)"
    line(monitor, string.format("  %-36s %-16s%s", entry.id, entry.provider, note), entry.available and WHITE or LIGHT_GRAY)
  end
end

local function listProviders(monitor, current)
  local providers = provider.list(current.config)
  local ids = {}
  for id in pairs(providers) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local entry = providers[id]
    local key = provider.apiKey(current.config, entry)
    local note = key and "" or "  (no api key)"
    line(monitor, string.format("  %-12s %-14s %s%s", id, entry.name or id, entry.base or "(no base url)", note),
      key and WHITE or LIGHT_GRAY)
  end
end

local function listTools(monitor, current)
  for _, tool in ipairs(registry.list(current.enabled)) do
    line(monitor, "  " .. tool.id)
  end
end

--- Give the session a generated name, once, just before it is saved.
--
-- The first question makes a far better title than "New session", but naming
-- costs a request, so it happens on save rather than on every turn. A failure
-- leaves the default title: a session with an unhelpful name is a minor
-- inconvenience, not a broken run, so nothing is reported.
local function nameSession(monitor)
  local current = M.state
  if current.config.title == false or current.session.title ~= session.DEFAULT_TITLE then
    return
  end
  local name = agent.title(buildContext(monitor), session.text(session.firstUserMessage(current.session)))
  if name and name ~= "" then
    current.session.title = name
  end
end

--- Write the session to disk, naming it first if it still has no name.
local function save(monitor)
  nameSession(monitor)
  local path, err = session.save(M.state.session)
  if path then
    line(monitor, "saved " .. path, LIGHT_GRAY)
  else
    line(monitor, "could not save: " .. tostring(err), RED)
  end
end

--- Handle a slash command. Returns false when the REPL should stop.
local function command(monitor, input)
  local current = M.state
  local verb, rest = input:match("^/(%S+)%s*(.*)$")
  if not verb then
    return true
  end
  rest = rest:gsub("^%s+", ""):gsub("%s+$", "")

  if verb == "exit" or verb == "quit" then
    return false
  elseif verb == "help" then
    help(monitor)
  elseif verb == "model" then
    if rest == "" then
      line(monitor, current.config.model)
    else
      local resolved, err = provider.resolve(current.config, rest)
      if not resolved then
        line(monitor, err, RED)
      else
        current.config.model = rest
        current.model = resolved
        line(monitor, "model: " .. rest)
      end
    end
  elseif verb == "models" then
    listModels(monitor, current)
  elseif verb == "providers" then
    listProviders(monitor, current)
  elseif verb == "agent" then
    if rest == "" then
      line(monitor, current.agent)
    else
      local known = false
      for _, name in ipairs(M.AGENTS) do
        known = known or name == rest
      end
      if not known then
        line(monitor, "Unknown agent '" .. rest .. "'. Try: " .. table.concat(M.AGENTS, ", "), RED)
      else
        current.agent = rest
        line(monitor, "agent: " .. rest)
      end
    end
  elseif verb == "tools" then
    listTools(monitor, current)
  elseif verb == "new" then
    current.session = session.new()
    line(monitor, "new session " .. current.session.id, LIGHT_GRAY)
  elseif verb == "save" then
    save(monitor)
  else
    line(monitor, "Unknown command /" .. verb .. ". Try /help.", RED)
  end
  return true
end

-- Turns

--- Run one user turn, printing the result. Returns the message, or nil plus the
--- reason the run stopped early.
local function turn(monitor, text)
  local current = M.state
  session.addUser(current.session, text)
  return agent.run(buildContext(monitor))
end

--- Report whatever ended the run other than a normal finish.
local function reportStop(monitor, message, reason)
  if reason == nil or reason == "aborted" then
    return
  end
  if message and message.error then
    return
  end
  line(monitor, tostring(reason), YELLOW)
end

--- Read one line from the operator, or nil at end of input.
--
-- The cursor and the line editing are `read`'s own business on ComputerCraft, so
-- this neither blinks the cursor nor reads a key: it hands the question to the
-- same call the shell uses for its own command line.
local function prompt()
  return env.readLine()
end

local function finish(monitor)
  if M.state.autoSave then
    save(monitor)
  end
end

--- The interactive loop.
local function repl(monitor)
  banner(monitor, M.state)
  while true do
    line(monitor, "")
    out(monitor, "> ", LIGHT_GRAY)
    local input = prompt()
    if input == nil then
      return
    end
    input = input:gsub("^%s+", ""):gsub("%s+$", "")
    if input == "" then
      -- nothing typed; ask again
    elseif input:sub(1, 1) == "/" then
      if not command(monitor, input) then
        finish(monitor)
        return
      end
    elseif M.state.model == nil then
      line(monitor, "No usable model. Try /model, or fix the config.", RED)
    else
      reportStop(monitor, turn(monitor, input))
    end
  end
end

--- One turn and out, for `opencode "<question>"`.
local function once(monitor, text)
  if M.state.model == nil then
    line(monitor, M.state.error or "No model configured.", RED)
    return 1
  end
  local message, reason = turn(monitor, text)
  line(monitor, "")
  reportStop(monitor, message, reason)
  finish(monitor)
  -- A turn that ended in a provider or transport error is a failed run, and a
  -- caller watching the exit code should be able to tell.
  if not message or message.error or reason then
    return 1
  end
  return 0
end

-- Argument parsing

local function usage(monitor)
  line(monitor, "opencode for ComputerCraft")
  line(monitor, "")
  line(monitor, "  opencode                    interactive session", LIGHT_GRAY)
  line(monitor, "  opencode <question>         one turn, then exit", LIGHT_GRAY)
  line(monitor, "  opencode run <question>     the same, spelled out", LIGHT_GRAY)
  line(monitor, "")
  line(monitor, "Options:")
  line(monitor, "  --model <id>     provider/model to use", LIGHT_GRAY)
  line(monitor, "  --agent <name>   " .. table.concat(M.AGENTS, ", "), LIGHT_GRAY)
  line(monitor, "  --dir <path>     working directory (default: the shell's)", LIGHT_GRAY)
  line(monitor, "  --save           save the session when it ends", LIGHT_GRAY)
  line(monitor, "  --stream         ask the provider for a stream", LIGHT_GRAY)
  line(monitor, "  --help           this list", LIGHT_GRAY)
end

--- Split the program's arguments. `run` is accepted and ignored so the one-shot
--- form can be spelled out.
local function parse(argv)
  local options = { save = false, stream = false, help = false }
  local rest = {}
  local index = 1
  while index <= #argv do
    local item = argv[index]
    if item == "--model" or item == "--agent" or item == "--dir" then
      options[item:sub(3)] = argv[index + 1]
      index = index + 2
    elseif item == "--save" then
      options.save = true
      index = index + 1
    elseif item == "--stream" then
      options.stream = true
      index = index + 1
    elseif item == "--help" or item == "-h" then
      options.help = true
      index = index + 1
    elseif item == "run" and #rest == 0 then
      index = index + 1
    else
      rest[#rest + 1] = item
      index = index + 1
    end
  end
  options.question = table.concat(rest, " ")
  return options
end

--- Build the run state from parsed arguments. Split out so the REPL, one-shot
--- mode, and the test harness all start from the same place.
function M.setup(argv, monitor)
  local options = parse(argv or {})
  local cwd = options.dir and env.resolve(options.dir, env.cwd()) or env.cwd()

  local overrides = {}
  if options.model then
    overrides.model = options.model
  end

  local current = {
    config = config.load(cwd, overrides),
    cwd = cwd,
    root = cwd,
    agent = options.agent or "build",
    session = session.new(),
    monitor = monitor,
    autoSave = options.save,
    stream = options.stream,
    enabled = nil,
  }
  current.enabled = current.config.tools

  current.model, current.error = resolveModel(current)
  if current.model then
    local small = provider.resolve(current.config, current.config.small_model)
    -- Falling back to the main model beats refusing to name a session at all.
    current.smallModel = small or current.model
  end

  M.state = current
  return current, options
end

--- Program entry point. Returns the shell exit code.
function M.main(argv, monitor)
  monitor = monitor or env.terminal()
  if not monitor then
    return 1
  end

  local state, options = M.setup(argv, monitor)
  if options.help then
    usage(monitor)
    return 0
  end
  if state.model == nil and state.error then
    -- Not fatal in the REPL: /model can still fix it, and the message says what is
    -- wrong. In one-shot mode `once` reports it instead, so it is not said twice.
    if options.question == "" then
      line(monitor, state.error, YELLOW)
    end
  end

  if options.question ~= "" then
    return once(monitor, options.question)
  end
  repl(monitor)
  return 0
end

--- Whether this file is the program being run, rather than a library that something
--- else loaded.
--
-- `require` and "run this file" look identical from inside the chunk, and a
-- computer has no `debug.getinfo` to tell them apart. `shell.getRunningProgram`
-- can: it names whichever program CC actually started, and `require` leaves it
-- alone. So a program that loads this one as a library does not get a REPL as a
-- side effect, which is the only reason this is worth asking.
--
-- The cost is a name, so it starts under the two names the installer writes. Rename
-- the file and it becomes a library, to be driven through `M.main`.
local function isProgram()
  local running = (shell and shell.getRunningProgram and shell.getRunningProgram()) or ""
  local name = running:match("([^/]+)$") or ""
  return name == "init.lua" or name == "opencode.lua"
end

if isProgram() then
  -- CC hands a program its command line as the chunk's varargs, so
  -- `shell.run("init.lua what is 2 + 2")` arrives here as one question.
  return M.main({ ... }, env.terminal())
end

return M
