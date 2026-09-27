-- The `bash` tool: run a command in the ComputerCraft shell.
--
-- CC's shell is not a POSIX shell, so the command runs through `shell.run`. Output
-- is redirected to a temp file so it can be captured and tail-truncated without
-- flooding the terminal. When the `shell` builtin exists the command is spawned
-- with `bg`, which gives us a pid to poll for the timeout and to kill.

local env = require("environment")
local util = require("util")
local truncate = require("truncate")
local registry = require("tool/registry")

local DEFAULT_TIMEOUT_MS = 120000

local DESCRIPTION = [[Executes a command in the ComputerCraft shell with an optional timeout.

Be aware: this is the ComputerCraft shell, not bash. Supported syntax is limited:
- pipes (|), redirection (> >> 2>&1), background (&), and simple sequencing with ;
- builtins: cd, dir/ls, mkdir, rm/del, cp, mv, type/cat, echo, clear, exit, and
  any program installed under /rom/programs or on PATH
- `&&` is not supported; chain dependent commands in a single call separated by `;`
  and check the output

Working directory:
All commands run in the session working directory. Use the `workdir` parameter
instead of a `cd` prefix, so the permission check sees the real target path.

Usage notes:
  - The command argument is required.
  - You can specify an optional timeout in milliseconds. Commands time out after
    120000ms by default.
  - Output longer than the truncation limit is tail-truncated, so the most recent
    lines stay visible and the full text is saved to a file you can grep or read.
  - Do not use this tool for reading, writing, or searching files; use the Read,
    Write, Edit, Glob, and Grep tools for those.
  - You can issue several independent bash calls in one message; they run in order
    but a single call per command keeps the output attributable.

# ComputerCraft specifics
- Programs are Lua programs in /rom/programs or in a directory on PATH. A computer
  is limited in CPU and memory: prefer small, bounded commands over large scans.
- `shell.run` returns immediately for backgrounded commands; the output file may
  still be growing when the tool returns.
- File paths always start with `/` and use `/` as the separator. There is no
  current-directory-relative shorthand, and there is no `which`-free shell.
- The `edit`/`write` tools are the right way to create or modify files. Using
  redirection through bash works but is not tracked by the permission system.]]

local function quote(value)
  return env.quote(value)
end

--- Commands whose first token changes the working directory, exempt from
--- permission checks because the workdir parameter covers that case.
local CD_COMMANDS = { cd = true, chdir = true, pushd = true, popd = true }

--- Split a command line on `;` so each segment can be permission checked.
local function segments(command)
  local out = {}
  for piece in command:gmatch("[^;]+") do
    local trimmed = util.trim(piece)
    if trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return out
end

--- Derive the permission pattern for a command: `git status` -> `git status`,
--- and the always-pattern `git *` that covers its subcommands.
local function arityPatterns(segment)
  local tokens = {}
  for token in segment:gmatch("%S+") do
    tokens[#tokens + 1] = token:gsub("^%s+", "")
  end
  local name = tokens[1] and tokens[1]:gsub("[;&|].*$", "")
  if not name or name == "" then
    return segment, nil
  end
  local always = name
  if #tokens > 1 and not tokens[2]:match("^%-") then
    always = name .. " " .. tokens[2]
  end
  return segment, always .. " *"
end

--- Poll a spawned job until it finishes, the timeout expires, or we are aborted.
-- Returns whether the job timed out and whether it was aborted; the exit code is
-- read from `shell.getJobInfoEx`, which retains info after the job is reaped.
local function waitForJob(pid, timeoutMs, ctx)
  local deadline = os.time() + math.ceil(timeoutMs / 1000)
  while shell.getJobInfo(pid) do
    if os.time() >= deadline then
      shell.kill(pid)
      return true, false
    end
    if ctx and ctx.aborted and ctx.aborted() then
      shell.kill(pid)
      return false, true
    end
    util.sleep(0.1)
  end
  local info = shell.getJobInfoEx and shell.getJobInfoEx(pid)
  return false, false, type(info) == "table" and info.exitCode or nil
end

--- Run `command`, returning its exit code, captured output, and any failure note.
local function run(command, workdir, timeoutMs, ctx)
  local outputPath = env.combine(truncate.directory(), util.id("bash") .. ".out")
  if not env.mkdirs(truncate.directory()) then
    error("could not create the output directory " .. truncate.directory(), 0)
  end

  local line = command
  if workdir and workdir ~= "" then
    line = "cd " .. quote(workdir) .. " ; " .. line
  end
  line = line .. " > " .. quote(outputPath) .. " 2>&1"

  local notes = {}
  local exitCode

  if shell.which and shell.which("shell") and shell.getJobInfo and shell.getJobInfoEx then
    local pid = shell.run("bg shell " .. quote(line))
    if type(pid) ~= "number" or pid <= 0 then
      env.remove(outputPath)
      error("could not start the command", 0)
    end
    local timedOut, aborted
    timedOut, aborted, exitCode = waitForJob(pid, timeoutMs, ctx)
    if timedOut then
      notes[#notes + 1] = string.format(
        "the command was terminated after exceeding the timeout of %d ms. Retry with a larger timeout if it was not waiting for input.",
        timeoutMs
      )
    end
    if aborted then
      notes[#notes + 1] = "the user aborted the command"
    end
  else
    -- No cancellable job handle available. The command still runs with its output
    -- captured, but on timeout it cannot be killed and is reported as abandoned.
    local abandoned = false
    local coroutine = coroutine.create(function()
      exitCode = shell.run(line)
    end)
    local timer = os.startTimer(math.ceil(timeoutMs / 1000))
    local event = parallel.waitForAny({ coroutine, timer })
    if event == timer then
      abandoned = true
      notes[#notes + 1] = string.format(
        "the command was still running after the timeout of %d ms and was abandoned; its output file may still be growing.",
        timeoutMs
      )
    end
    if abandoned and shell.kill then
      shell.kill(tostring(coroutine))
    end
  end

  local captured = env.read(outputPath) or ""
  env.remove(outputPath)
  return exitCode, captured, notes
end

registry.define({
  id = "bash",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      command = { type = "string", description = "The command to execute" },
      timeout = {
        type = "number",
        description = "Optional timeout in milliseconds. Defaults to 120000.",
      },
      workdir = {
        type = "string",
        description = "The directory to run the command in. Defaults to the session working directory. Use this instead of a cd prefix.",
      },
    },
    required = { "command" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local command = args.command
    if type(command) ~= "string" or util.trim(command) == "" then
      error("The command argument is required.", 0)
    end
    local timeout = tonumber(args.timeout) or DEFAULT_TIMEOUT_MS
    if timeout < 0 then
      error("Invalid timeout value: " .. tostring(args.timeout) .. ". Timeout must be a positive number.", 0)
    end
    local workdir = args.workdir and env.resolve(args.workdir, ctx.cwd) or ctx.cwd

    local patterns, always = {}, {}
    for _, segment in ipairs(segments(command)) do
      local name = segment:match("^(%S+)")
      if not (name and CD_COMMANDS[name]) then
        local pattern, alwaysPattern = arityPatterns(segment)
        patterns[#patterns + 1] = pattern
        if alwaysPattern then
          always[#always + 1] = alwaysPattern
        end
      end
    end
    if not env.contains(ctx.root, workdir) then
      registry.guard(ctx, "external_directory", { workdir .. "/*" }, { workdir .. "/*" },
        "working outside " .. ctx.root)
    end
    registry.guard(ctx, "bash", patterns, always, command)

    local exitCode, captured, notes = run(command, workdir, timeout, ctx)

    local limits = registry.limits(ctx.config)
    local output = truncate.output(captured, {
      maxLines = limits.maxLines,
      maxBytes = limits.maxBytes,
      direction = "tail",
    })
    if output == "" then
      output = "(no output)"
    end
    if #notes > 0 then
      output = output .. "\n\n<shell_metadata>\n" .. table.concat(notes, "\n") .. "\n</shell_metadata>"
    end

    return {
      title = command,
      metadata = { output = output, exit = exitCode },
      output = output,
    }
  end,
})

return true
