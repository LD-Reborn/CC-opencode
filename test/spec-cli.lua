-- The entry point: argument parsing, the slash commands, and the rendering of
-- the agent's events onto a screen.
--
-- `init.lua` is loaded the way ComputerCraft loads it — from disk, once, with the
-- mocked CC API in place — so these tests cover the same path the program takes.

return function(t, mock)
  t.suite("cli")

  local json = require("json")
  local env = require("environment")

  --- Load init.lua fresh. It is a program rather than a library, so it is read
  --- from disk instead of required: a require would hand back a cached copy and
  --- `M.state` would leak from one test into the next.
  --- Write an `opencode.json`, keeping the zen key the tests need.
  --
  --- The default provider is the zen gateway and it needs a key, so a test that
  --- writes a config of its own would otherwise resolve no model and make no
  --- request. Merging keeps each test to the one field it is actually about.
  local function writeConfig(config)
    config = config or {}
    config.env = config.env or {}
    config.env.OPENCODE_API_KEY = config.env.OPENCODE_API_KEY or "zen-key"
    env.write(mock.root .. "/opencode.json", json.encode(config))
  end

  --- `running` names the program CC believes is running, which is what `init.lua`
  --- asks to decide whether to start itself. This harness is that program, so by
  --- default init.lua comes back as a library with `M.main` left for the test to
  --- call. Passing "init.lua" or "opencode.lua" makes it start itself instead,
  --- which is what a computer does, and `argv` is the command line it would get.
  local function loadInit(running, argv, screen)
    mock.setup()
    writeConfig()
    if screen then
      -- Named the way `environment.terminal` looks for one, so the self-start path
      -- finds a terminal the way it would on a computer. Every other test here
      -- hands `main` a screen directly and so never exercises that lookup.
      mock.attach({ monitor_1 = screen })
      -- And made `term`, because on a computer the screen the self-start path finds is
      -- the terminal, and `env.console` — the lookup the interface uses — only ever
      -- looks at `term`. A screen that is only a peripheral is a screen the interface
      -- will not use, which is the next test but one.
      _G.term = screen
    end
    shell.getRunningProgram = function()
      return running or "/test/harness.lua"
    end
    local path = t.root .. "/init.lua"
    local chunk, err = loadfile(path)
    if not chunk then
      t.ok(false, "could not load init.lua: " .. tostring(err))
      return nil
    end
    return chunk(unpack(argv or {}))
  end

  local function textTurn(content)
    return {
      status = 200,
      body = json.encode({
        choices = { { message = { content = content }, finish_reason = "stop" } },
        usage = { prompt_tokens = 11, completion_tokens = 7 },
      }),
    }
  end

  local function toolTurn(name, arguments, content)
    return {
      status = 200,
      body = json.encode({
        choices = { {
          message = {
            content = content or "",
            reasoning_content = "thinking about it",
            tool_calls = { { id = "call_1", type = "function", ["function"] = { name = name, arguments = arguments } } },
          },
          finish_reason = "tool_calls",
        } },
        usage = { prompt_tokens = 11, completion_tokens = 7 },
      }),
    }
  end

  -- setup

  do
    local init = assert(loadInit())
    -- A key, because these tests are about the other keys on the command line, and
    -- a model that needs a credential is the easiest way to have one resolve.

    local state = init.setup({}, mock.screen({}))

    t.eq(state.agent, "build", "the default agent is build")
    t.eq(state.config.model, "opencode/space-bunny-free", "the default model comes from the built-in defaults")
    t.eq(state.model.id, "space-bunny-free", "the default model resolves")
    t.eq(state.model.providerID, "opencode", "the default provider is opencode")
    t.eq(state.model.apiKey, "zen-key", "and takes the key from the env")
    t.eq(state.smallModel.id, "space-bunny-free", "the small model resolves too")
    t.eq(state.error, nil, "a working config reports no error")
    t.eq(state.autoSave, false, "sessions are not saved unless asked")
    t.eq(state.stream, false, "requests are not streamed unless asked")
    t.eq(type(state.session.id), "string", "setup starts a session")
    t.eq(state.cwd, mock.root, "the working directory defaults to the shell's")
    t.eq(init.state, state, "state is published for the rest of the program")
  end

  do
    -- The case a fresh install is in, and the one this default exists for: no
    -- config file, no key, nothing set. It has to start and resolve a model, or
    -- the first thing anyone sees after installing is a refusal.
    --
    -- Every field is read through `field` rather than indexed. A default that
    -- fails to resolve leaves `state.model` nil, and indexing that aborts the
    -- whole run on the first failure instead of reporting all of them -- which is
    -- how a paid default slipped through as a crash with no explanation.
    local function field(model, key)
      return model and model[key]
    end

    local init = assert(loadInit())
    fs.delete(mock.root .. "/opencode.json")
    t.eq(fs.exists(mock.root .. "/opencode.json"), false, "there is no config on this computer")

    local state = init.setup({}, mock.screen({}))

    t.eq(state.error, nil, "an unconfigured computer starts without an error")
    t.ok(state.model, "and resolves a model")
    t.eq(field(state.model, "id"), "space-bunny-free", "which is the one the gateway serves unauthenticated")
    t.eq(field(state.model, "apiKey"), nil, "with no credential, so the request goes out without an Authorization header")
    t.ok(state.smallModel, "the small model resolves too, or titles and compaction fail")
    t.eq(field(state.smallModel, "apiKey"), nil, "also without a credential")
  end

  do
    -- And a key is still what unlocks the rest: setting one must not change the
    -- default, only add the option of something else.
    local init = assert(loadInit())
    fs.delete(mock.root .. "/opencode.json")
    local state = init.setup({ "--model", "opencode/gpt-5" }, mock.screen({}))
    t.eq(state.model, nil, "a paid model is still refused with no key")
    writeConfig({ env = { OPENCODE_API_KEY = "zen-key" } })
    local keyed = assert(loadInit())
    t.eq(
      keyed.setup({ "--model", "opencode/gpt-5" }, mock.screen({})).model.apiKey,
      "zen-key",
      "and accepted once one is set"
    )
  end

  do
    -- A ComputerCraft screen discards anything written past its right edge rather
    -- than continuing it on the next row, so an unwrapped line is not ugly, it is
    -- incomplete. 51 columns is what a real Computer or Turtle gives you, and an
    -- error is exactly the kind of message that overruns it.
    local init = assert(loadInit())
    local screen = mock.screen({ "/exit" }, { 51, 19 })
    init.main({ "--model", "groq/llama-3.3-70b" }, screen)

    for _, drawn in ipairs(screen.drawn) do
      t.ok(#drawn <= 51, "nothing is drawn past the right edge: [" .. drawn .. "]")
    end
    t.contains(screen.text, "No API key for 'groq/llama-3.3-70b'", "and the message is still all there")
    t.contains(screen.text, "GROQ_API_KEY", "including the part that names the variable to set")
    t.contains(screen.text, "or env.", "and the end of it, which is what used to be lost")
  end

  do
    -- The width is read from the screen rather than hardcoded, so the identical
    -- error fits on one line on a wide monitor and only wraps on a narrow one.
    local init = assert(loadInit())
    local wide = mock.screen({ "/exit" }, { 200, 40 })
    init.main({ "--model", "groq/llama-3.3-70b" }, wide)
    t.contains(wide.text, "No API key for 'groq/llama-3.3-70b'", "the same message is reported when there is room")
  end

  do
    local init = assert(loadInit())
    local state = init.setup({ "--model", "ollama/llama3", "--agent", "plan", "--save", "--stream" }, mock.screen({}))

    t.eq(state.config.model, "ollama/llama3", "--model overrides the configured model")
    t.eq(state.model.providerID, "ollama", "the override resolves to its provider")
    t.eq(state.agent, "plan", "--agent selects the agent")
    t.eq(state.autoSave, true, "--save is remembered")
    t.eq(state.stream, true, "--stream is remembered")
  end

  do
    local init = assert(loadInit())
    local state = init.setup({ "--dir", "sub/dir" }, mock.screen({}))
    t.eq(state.cwd, mock.root .. "/sub/dir", "--dir resolves against the shell's directory")
  end

  do
    local init = assert(loadInit())
    local state = init.setup({ "--model", "groq/llama-3.3-70b" }, mock.screen({}))
    t.eq(state.model, nil, "a model with no key resolves to nothing")
    t.contains(state.error, "No API key for 'groq/llama-3.3-70b'", "the error names the model asked for")
    t.contains(state.error, "GROQ_API_KEY", "the error names the variable to set")
  end

  do
    local init = assert(loadInit())
    local state = init.setup({ "--model", "nosuch/model" }, mock.screen({}))
    t.eq(state.model, nil, "an unknown provider resolves to nothing")
    t.contains(state.error, "Unknown provider 'nosuch'", "the error names the unknown provider")
  end

  do
    local init = assert(loadInit())
    local state = init.setup({ "--model", "justaname" }, mock.screen({}))
    t.eq(state.model, nil, "a model id with no provider half does not resolve")
    t.contains(state.error, "has no model part", "the error explains the expected form")
  end

  do
    -- A key in the config makes the same model that just failed to resolve.
    local init = assert(loadInit())
    writeConfig({ env = { GROQ_API_KEY = "gsk-test" } })
    local state = init.setup({ "--model", "groq/llama-3.3-70b" }, mock.screen({}))
    t.eq(state.model and state.model.apiKey, "gsk-test", "a key in opencode.json is used")
  end

  -- One-shot mode

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    mock.respond(textTurn("There are 3 programs."))
    local code = init.main({ "how", "many", "programs" }, screen)

    t.eq(code, 0, "a successful one-shot run exits zero")
    t.contains(screen.text, "There are 3 programs.", "the answer is printed")
    t.eq(#mock.requests, 1, "one request was made")
    t.eq(mock.requests[1].url, "https://opencode.ai/zen/v1/chat/completions", "the default provider's url is used")
    local body = json.decode(mock.requests[1].body)
    t.eq(body.messages[#body.messages].content, "how many programs", "the arguments are joined into the question")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    mock.respond(textTurn("done"))
    init.main({ "run", "say hi" }, screen)
    local body = json.decode(mock.requests[1].body)
    t.eq(body.messages[#body.messages].content, "say hi", "`run` is accepted and ignored")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    mock.respond(textTurn("answered"))
    init.main({ "--save", "hello" }, screen)
    t.contains(screen.text, "saved ", "--save reports where it wrote")
    local saved = env.combine(mock.root, "opencode", "session")
    local names = env.listDir(saved)
    t.eq(#names, 1, "one session file was written")
    t.contains(names[1], "ses_", "the file is named after the session")
  end

  -- A saved session is named from its first question, so it can be found again.
  -- The extra request is only worth it once, and only if the operator allows it.

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    mock.respond(textTurn("answered"))
    mock.respond(textTurn("Counting the programs"))
    init.main({ "--save", "how many programs" }, screen)
    t.eq(#mock.requests, 2, "the answer, then a request for a name")
    local names = env.listDir(env.combine(mock.root, "opencode", "session"))
    local saved = json.decode(env.read(env.combine(mock.root, "opencode", "session", names[1])))
    t.eq(saved.title, "Counting the programs", "the saved session is named after the question")
    local ask = json.decode(mock.requests[2].body)
    t.eq(ask.max_tokens, 24, "the name is short")
    t.eq(ask.messages[2].content, "how many programs", "and comes from the first question")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    writeConfig({ title = false })
    mock.respond(textTurn("answered"))
    init.main({ "--save", "how many programs" }, screen)
    t.eq(#mock.requests, 1, "title = false skips the naming request")
    local names = env.listDir(env.combine(mock.root, "opencode", "session"))
    local saved = json.decode(env.read(env.combine(mock.root, "opencode", "session", names[1])))
    t.eq(saved.title, "New session", "and the session keeps the default name")
  end

  do
    -- A name that cannot be generated is not worth failing a run over: the
    -- session is saved under its default title and the exit code is unchanged.
    local init = assert(loadInit())
    local screen = mock.screen({})
    mock.respond(textTurn("answered"))
    mock.respond({ status = 200, body = '{"choices":[]}' })
    local code = init.main({ "--save", "a question" }, screen)
    t.eq(code, 0, "a session that cannot be named still exits zero")
    t.contains(screen.text, "saved ", "and the save is reported")
    t.eq(#mock.requests, 2, "the naming request was still attempted")
    local names = env.listDir(env.combine(mock.root, "opencode", "session"))
    local saved = json.decode(env.read(env.combine(mock.root, "opencode", "session", names[1])))
    t.eq(saved.title, "New session", "with the default name kept")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "what can you do", "/save", "/exit" })
    mock.respond(textTurn("A lot"))
    mock.respond(textTurn("Asking what I can do"))
    init.main({ "--plain" }, screen)
    local names = env.listDir(env.combine(mock.root, "opencode", "session"))
    local saved = json.decode(env.read(env.combine(mock.root, "opencode", "session", names[1])))
    t.eq(saved.title, "Asking what I can do", "/save names the session it writes")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    -- A 500 is retried, so all three attempts have to fail the same way.
    for _ = 1, 3 do
      mock.respond({ status = 500, body = '{"error":"nope"}' })
    end
    local code = init.main({ "break it" }, screen)

    t.eq(code, 1, "a failed turn exits nonzero")
    t.contains(screen.text, "HTTP 500", "the failing status is reported")
    t.contains(screen.text, "nope", "the provider's own message is reported")
    t.ok(mock.sleeps > 0, "a retryable status was retried")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    local code = init.main({ "--model", "nosuch/x", "hi" }, screen)
    t.eq(code, 1, "a one-shot run with no usable model exits nonzero")
    t.contains(screen.text, "Unknown provider", "the reason is printed once")
    local mentions = select(2, screen.text:gsub("Unknown provider", ""))
    t.eq(mentions, 1, "the reason is not printed twice")
    t.eq(#mock.requests, 0, "nothing was sent to a provider")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    local code = init.main({ "--help" }, screen)
    t.eq(code, 0, "--help exits zero")
    t.contains(screen.text, "--model", "the option list is printed")
    t.contains(screen.text, "interactive session", "the usage forms are printed")
    t.eq(#mock.requests, 0, "asking for help contacts nobody")
  end

  -- Streaming

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    mock.respond({
      status = 200,
      body = table.concat({
        'data: {"choices":[{"delta":{"content":"str"}}]}',
        'data: {"choices":[{"delta":{"content":"eam"}}]}',
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
        "data: [DONE]",
      }, "\n"),
    })
    init.main({ "--stream", "say something" }, screen)
    t.contains(screen.text, "stream", "the streamed answer is printed as it arrived")
    local body = json.decode(mock.requests[1].body)
    t.eq(body.stream, true, "the request asked for a stream")
    t.eq(body.stream_options.include_usage, true, "and asked for usage in the stream")
  end

  -- The REPL

  do
    -- The invariant, and the reason the suite was green while the program was not.
    -- ComputerCraft's `term` has no `readLine`; input arrives through the global
    -- `read`, which the shell uses for its own command line. Calling a screen for
    -- `readLine` answers nil, and both callers read nil as end of input -- so on a
    -- computer the REPL exited straight after its banner and every permission
    -- prompt denied without asking. The mock used to hand out a `readLine` and so
    -- agreed with the program and disagreed with the hardware.
    local probe = mock.screen({})
    t.eq(probe.readLine, nil, "a screen answers nil for readLine, as ComputerCraft does")
    t.eq(type(read), "function", "and input arrives through CraftOS's global read")

    local init = assert(loadInit())
    local screen = mock.screen({ "/help", "/exit" })
    local code = init.main({ "--plain" }, screen)

    t.eq(code, 0, "the REPL reads its lines and exits zero on /exit")
    t.eq(#screen.inputs, 0, "having consumed both of the answers it was given")
    t.contains(screen.text, "opencode for ComputerCraft", "the banner is printed")
    t.contains(screen.text, "/model", "/help lists the commands")
    t.contains(screen.text, "/exit", "/help lists every command")
    t.contains(screen.text, "model: opencode/space-bunny-free", "the banner shows the model")
    t.eq(#mock.requests, 0, "commands do not call a model")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/model", "/model opencode/gpt-5-nano", "/model", "/exit" })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "opencode/gpt-5-nano", "/model <id> switches the model")
    t.eq(init.state.config.model, "opencode/gpt-5-nano", "the switch is kept in the state")
    t.eq(init.state.model.id, "gpt-5-nano", "the resolved model follows")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/model groq/llama", "/exit" })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "No API key", "an unusable model is refused with a reason")
    t.eq(init.state.config.model, "opencode/space-bunny-free", "the previous model is kept")
  end

  do
    -- `/models` used to open on a fresh install to say nothing was configured,
    -- which is honest and useless. The defaults declare the one model that works
    -- without a key, so the list has something in it before anything is written --
    -- and it is listed as available, which is the whole point of it being there.
    local init = assert(loadInit())
    local screen = mock.screen({ "/models", "/exit" })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "opencode/space-bunny-free", "/models lists the model that needs no key")
    t.ok(not screen.text:find("space%-bunny%-free%s+.-%(%(no api key%)"), "/models does not mark it as needing a key")
  end

  do
    local init = assert(loadInit())
    writeConfig({
      env = { GROQ_API_KEY = "gsk-test" },
      provider = { groq = { models = { ["llama-3.3-70b"] = { name = "Llama 3.3 70B" } } } },
    })
    local screen = mock.screen({ "/models", "/providers", "/exit" })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "groq/llama-3.3-70b", "/models lists configured models")
    t.contains(screen.text, "openrouter", "/providers lists the built-in providers")
    t.contains(screen.text, "(no api key)", "and marks the ones with no key")
    t.contains(screen.text, "no api key", "groq has a key, so it is not marked")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/agent", "/agent plan", "/agent", "/agent explore", "/agent nonsense", "/exit" })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "build", "/agent shows the current agent")
    t.contains(screen.text, "agent: plan", "/agent <name> switches")
    t.contains(screen.text, "agent: explore", "and switches again")
    t.contains(screen.text, "Unknown agent 'nonsense'", "an unknown agent is refused")
    t.contains(screen.text, "build, general, plan, explore", "the error lists the known agents")
    t.eq(init.state.agent, "explore", "the last valid choice is kept")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/tools", "/exit" })
    init.main({ "--plain" }, screen)
    for _, id in ipairs({ "bash", "read", "glob", "grep", "edit", "write", "webfetch", "todowrite" }) do
      t.contains(screen.text, id, "/tools lists " .. id)
    end
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/new", "/new", "/exit" })
    init.main({ "--plain" }, screen)

    local ids = {}
    for id in screen.text:gmatch("new session (ses_%w+)") do
      ids[id] = true
    end
    local count = 0
    for _ in pairs(ids) do
      count = count + 1
    end
    t.eq(count, 2, "/new really starts a different session each time")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/save", "/exit" })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "saved ", "/save reports the path")
    t.eq(#env.listDir(env.combine(mock.root, "opencode", "session")), 1, "/save wrote one file")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/nonsense", "/exit" })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "Unknown command /nonsense", "an unknown command is reported")
    t.contains(screen.text, "Try /help", "and points at the help")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/", "   ", "/exit" })
    local code = init.main({ "--plain" }, screen)
    t.eq(code, 0, "a bare slash and a blank line are ignored rather than sent")
    t.eq(#mock.requests, 0, "nothing was sent to a model")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    local code = init.main({ "--plain" }, screen)
    t.eq(code, 0, "a closed terminal ends the REPL cleanly")
    t.contains(screen.text, "opencode for ComputerCraft", "the banner was printed first")
  end

  -- Rendering

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "read the notes", "/exit" })
    env.write(mock.root .. "/notes.txt", "one\ntwo\n")
    mock.respond(toolTurn("read", json.encode({ filePath = mock.root .. "/notes.txt" })))
    mock.respond(textTurn("It has two lines."))
    init.main({ "--plain" }, screen)

    t.contains(screen.text, "  * read " .. mock.root .. "/notes.txt", "the tool call is logged with its argument")
    t.notContains(screen.text, "    " .. mock.root .. "/notes.txt\n", "a title that only repeats the argument is not logged twice")
    t.contains(screen.text, "It has two lines.", "the final answer is printed")
    t.contains(screen.text, "(11 in, 7 out)", "usage is shown")
    t.eq(#mock.requests, 2, "the turn took two provider calls")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "write the file", "/exit" })
    mock.respond(toolTurn("write", json.encode({ filePath = mock.root .. "/new.txt", content = "hello" })))
    mock.respond(textTurn("Done."))
    init.main({ "--plain" }, screen)

    t.contains(screen.text, "  * write " .. mock.root .. "/new.txt", "the call is logged with its path")
    t.contains(screen.text, "    Created " .. mock.root .. "/new.txt", "a title that says more than the argument is logged")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "read a missing file", "/exit" })
    mock.respond(toolTurn("read", json.encode({ filePath = mock.root .. "/missing.txt" })))
    mock.respond(textTurn("It is not there."))
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "File not found: " .. mock.root .. "/missing.txt", "a tool error names the file")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "list the files", "/exit" })
    mock.respond(toolTurn("nosuchtool", "{}"))
    mock.respond(textTurn("Sorry about that."))
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "  ! Unknown tool 'nosuchtool'", "a tool error is printed with an exclamation mark")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "think about it", "/exit" })
    mock.respond({
      status = 200,
      body = json.encode({
        choices = { { message = { content = "hi", reasoning_content = "weighing the options" }, finish_reason = "stop" } },
      }),
    })
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "(reasoning) weighing the options", "reasoning is shown, and set apart from the answer")
  end

  do
    -- Reasoning is the one line that is always long — a model's thinking
    -- overruns a 51-column terminal several times over — and it arrives as a
    -- single event, the shape that used to be written straight out and lose
    -- everything past the right edge. The mock discards an overlong row the
    -- way ComputerCraft does, so `lost == 0` is the assertion that matters,
    -- and the newline before the label is the assertion that the block
    -- starts on a row of its own rather than glued to the answer's last.
    local init = assert(loadInit())
    local screen = mock.screen({}, { 51, 19 })
    local thinking = "The user wants a file that outputs \"hello world\". " ..
      "I should create a small Lua program, write it to disk, and tell the user how to run it.\n" ..
      "Now to write the file."
    mock.respond({
      status = 200,
      body = json.encode({
        choices = { { message = { content = "hi", reasoning_content = thinking }, finish_reason = "stop" } },
      }),
    })
    init.main({ "think about it" }, screen)

    t.eq(screen.lost, 0, "a long reasoning loses nothing past the right edge")
    t.contains(screen.text, "\n(reasoning) The user wants a file that outputs", "the reasoning starts on a row of its own")
    t.contains(screen.text, "Now to write the file.", "and the end of it, which is what used to be lost")
  end

  do
    -- The same reasoning as the first thing on the screen, which is where it
    -- lands when the step it belongs to returns no answer of its own. It
    -- wraps from the first column rather than from wherever a previous line
    -- happened to end.
    local init = assert(loadInit())
    local screen = mock.screen({}, { 51, 19 })
    local thinking = "The user wants a file that outputs \"hello world\", so I will write a small program."
    mock.respond({
      status = 200,
      body = json.encode({
        choices = { { message = { content = "", reasoning_content = thinking }, finish_reason = "stop" } },
      }),
    })
    init.main({ "think about it" }, screen)

    t.eq(screen.lost, 0, "a reasoning that is the first output loses nothing")
    t.contains(screen.text, "(reasoning) The user wants a file that outputs", "the reasoning is on the screen")
    t.contains(screen.text, "so I will write a small program.", "including the end of it")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "a long path", "/exit" })
    local path = mock.root .. "/" .. string.rep("deep/", 20) .. "file.txt"
    mock.respond(toolTurn("read", json.encode({ filePath = path })))
    mock.respond(textTurn("ok"))
    init.main({ "--plain" }, screen)

    local logged = screen.text:match("  %* read ([^\n]*)")
    t.ok(logged ~= nil, "the tool call was logged")
    t.contains(logged, "deep/deep/deep/", "the argument is shown, not hidden entirely")
    t.ok(#logged <= 50, "the argument is shortened to one line")
    t.ok(logged:sub(-3) == "...", "and ends in an ellipsis")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "no tool for this", "/exit" })
    mock.respond(toolTurn("todowrite", '{"todos":[]}'))
    mock.respond(textTurn("ok"))
    init.main({ "--plain" }, screen)
    t.contains(screen.text, "  * todowrite", "a tool with no single obvious argument still logs something")
  end

  -- Screens

  do
    -- The answer is the one thing the REPL never wrapped: it arrives as a single
    -- delta and used to be written straight out, so asking for a list of files —
    -- long paths, no spaces to break at — lost everything past the right edge.
    -- 51 columns is what a Computer gives you, and the mock throws away an
    -- overlong row the way ComputerCraft does, so `lost` is the assertion that
    -- matters: the text is on the screen, or it is not anywhere.
    local init = assert(loadInit())
    local screen = mock.screen({}, { 51, 19 })
    local paths = {}
    for i = 1, 6 do
      paths[i] = "/rom/modules/" .. string.rep("nested_", 4) .. i .. ".lua"
    end
    mock.respond(textTurn("These are the files:\n" .. table.concat(paths, "\n") .. "\nThat is all of them."))
    local code = init.main({ "list the files" }, screen)

    t.eq(code, 0, "a reply longer than the screen is answered")
    t.eq(screen.lost, 0, "and nothing was written past the right edge")
    for _, path in ipairs(paths) do
      t.contains(screen.text, path, "every path in the answer is on the screen")
    end
    t.contains(screen.text, "That is all of them.", "including the end of it")
    t.ok(#screen.lines >= 8, "which took more rows than one line to fit")
  end

  do
    -- The same answer, but delivered in pieces, as `--stream` delivers it. The
    -- column has to be carried from one piece to the next: three fragments of
    -- forty characters are a hundred and twenty, and wrapping each on its own
    -- would put the second and third in the wrong place and lose the rest.
    local init = assert(loadInit())
    local screen = mock.screen({}, { 51, 19 })
    local first, second, third = ("ab"):rep(20), ("cd"):rep(20), "the end"
    mock.respond({
      status = 200,
      body = table.concat({
        'data: {"choices":[{"delta":{"content":' .. json.encode(first) .. "}}]}",
        'data: {"choices":[{"delta":{"content":' .. json.encode(second) .. "}}]}",
        'data: {"choices":[{"delta":{"content":' .. json.encode(third) .. "}}]}",
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
        "data: [DONE]",
      }, "\n"),
    })
    local code = init.main({ "--stream", "go on" }, screen)

    t.eq(code, 0, "a streamed reply is answered")
    t.eq(screen.lost, 0, "and a reply in three pieces loses nothing")
    -- The exact join is the assertion that matters. The first piece is 40
    -- characters, so the second has 10 columns left on the row and the rest of
    -- it continues underneath. Wrapping each piece as though it began a row --
    -- which is what happens when the column is not carried between writes --
    -- puts 120 characters side by side instead and reads as if nothing wrapped.
    t.contains(
      screen.text,
      first .. second:sub(1, 10) .. "\n" .. second:sub(11) .. third,
      "the row is filled to the margin and the rest of the piece continues underneath"
    )
    t.contains(screen.text, third, "right through to the last word of it")
  end

  do
    -- A permission question is drawn by a different module and used to be written
    -- raw as well, so a long one — a path, an unfamiliar command — was cut off at
    -- the very moment the operator needed to read what they were approving.
    local init = assert(loadInit())
    mock.attach({})
    writeConfig({
      model = "ollama/llama3",
      permission = { { permission = "read", pattern = "*", action = "ask" } },
    })
    local screen = mock.screen({ "n" }, { 51, 19 })
    mock.respond(toolTurn("read", json.encode({ filePath = mock.root .. "/notes.txt" })))
    mock.respond(textTurn("I did not read it."))
    local code = init.main({ "read the notes" }, screen)

    t.eq(code, 0, "a call that has to be approved is attempted")
    t.contains(screen.text, "Permission denied", "and refusing it goes through")
    t.eq(screen.lost, 0, "with the question itself fitting the screen")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    mock.attach({ left = screen })
    mock.respond(textTurn("hello"))
    local code = init.main({ "hi" }, nil)

    t.eq(code, 0, "with no monitor passed, the attached one is used")
    t.contains(screen.text, "hello", "and the answer lands on it")
    mock.attach({})
  end

  do
    local init = assert(loadInit())
    -- The answers go on the terminal, the drawing on the monitor, which is the
    -- arrangement a computer with a screen attached actually has. CC's `read` is a
    -- global on the terminal, so a program that read from the screen it draws on
    -- would work here and hang on a real multi-computer setup.
    local terminal = mock.screen({ "/help", "/exit" })
    -- Armed with a decoy. If the program asked the screen it was drawing on, it
    -- would eat this and exit on the wrong line, which is the bug a
    -- multi-computer setup would show and a single-screen test never could.
    local monitor = mock.screen({ "/quit" }, { 200, 50 }, true)
    mock.attach({ monitor_1 = monitor })
    local code = init.main({ "--plain" }, nil)

    t.eq(code, 0, "the REPL runs with a monitor attached and no screen passed")
    t.contains(monitor.text, "/exit", "the command list made it onto the monitor")
    t.contains(monitor.text, "/help", "and so did the help it printed")
    t.eq(#terminal.inputs, 0, "having taken both of its answers off the terminal")
    t.eq(#monitor.inputs, 1, "and left the monitor's own queue untouched")
    mock.attach({})
  end

  do
    mock.setup()
    local envModule = require("environment")

    mock.attach({})
    envModule.isCC = true
    _G.term = nil
    t.eq(envModule.terminal(), nil, "with neither a monitor nor a terminal there is no screen")

    local screen = mock.screen({})
    _G.term = screen
    t.eq(envModule.terminal().raw, screen, "a terminal is used when there is no monitor")

    local monitor = mock.screen({})
    mock.attach({ monitor_2 = monitor })
    t.eq(envModule.terminal().raw, monitor, "a monitor is preferred over the terminal")

    mock.attach({ left = mock.screen({}) })
    t.eq(envModule.terminal().raw, _G.peripheral.find("left"), "peripherals are searched in order")

    _G.term = nil
    mock.attach({})
  end

  do
    local init = assert(loadInit())
    mock.attach({})
    _G.term = nil
    local code = init.main({ "hi" }, nil)
    t.eq(code, 1, "with nowhere to print, the program gives up rather than crashing")
  end

  -- The interface
  --
  -- Every other interactive test in this file passes `--plain`, because the plain
  -- screen is what those are about. These are the ones that do not: an interactive
  -- session with no `--plain` is the interface, and the questions worth asking about
  -- it are the ones a plain screen cannot answer at all — whether a reply wider than
  -- the terminal comes back whole, and whether a permission question is put in front
  -- of the operator before it is answered.
  --
  -- Driving it means queueing keys, because CraftOS's keyboard belongs to the
  -- terminal and the interface reads it from there. A turn ends on enter, and the
  -- session ends when the queue runs out, which is what closing the program looks
  -- like: `os.pullEvent` answers nil, and nil is the end of input.

  --- An interactive session on a terminal, which is where the interface draws.
  --
  -- `mock.console` rather than `mock.screen`: it is `mock.console` that makes a screen
  -- be `term`, and `env.console` — the lookup the interface uses — only ever looks at
  -- `term`. A screen attached as a monitor is a screen the interface will not use,
  -- which is the next test.
  local function loadGui(argv, events)
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, argv or {}, terminal))
    if events then
      mock.queue(unpack(events))
    end
    return init, terminal
  end

  do
    -- The default, and the reason the flag exists: a computer terminal is 51 columns
    -- wide and a reply that needs 80 of them loses the rest, so the interactive
    -- session draws the interface unless it is told not to.
    local init, terminal = loadGui()
    local code = init.main({}, nil)

    t.eq(code, 0, "the interactive session runs and exits zero")
    t.ok(init.state.ui ~= nil, "an interactive session gets the interface")
    t.contains(mock.row(terminal, 1), "opencode", "which draws a title bar")
    t.contains(mock.row(terminal, 18), "enter sends", "and a hint line under the conversation")
    t.contains(mock.row(terminal, 19), "> ", "and an input field under that")
    t.notContains(terminal.text, "plain screen:", "and does not apologise for not having one")
  end

  do
    -- The interface draws on the terminal and never on a monitor, because CraftOS's
    -- keyboard belongs to the terminal: a field on a monitor is a field nobody can
    -- reach, and the conversation is no use if the answer cannot be typed. So a
    -- computer with a screen attached gets the plain screen on that screen and the
    -- interface nowhere.
    local monitor = mock.screen({}, { 51, 19 })
    local init = assert(loadInit())
    mock.attach({ monitor_1 = monitor })
    local code = init.main({}, nil)

    t.eq(code, 0, "a session with a monitor and no terminal still runs")
    t.eq(init.state.ui, nil, "and does not put the interface on the monitor")
    t.notContains(mock.gridText(monitor), "enter sends", "which has no hint line to show")
    t.contains(monitor.text, "opencode for ComputerCraft", "but the plain screen is still there")
    mock.attach({})
  end

  do
    -- A terminal too small for a title bar and a hint line is the one reason that is
    -- about the machine rather than the install, and the one a person can do something
    -- about: attach a bigger screen. Which is why the reason is said out loud.
    local terminal = mock.console({ 12, 5 })
    local init = assert(loadInit(nil, {}, terminal))
    local code = init.main({}, nil)

    t.eq(code, 0, "a terminal too small for the interface still gives a session")
    t.eq(init.state.ui, nil, "with the plain screen in its place")
    -- The reason is wrapped at the terminal's own width, which is the point of it being
    -- on a screen at all: a 12-column terminal cannot hold the sentence whole.
    t.contains(terminal.text, "screen:", "and says which reason it was")
    t.contains(terminal.text, "too small", "and what the reason is")
  end

  do
    -- `--plain` is the escape hatch, and it is the screen this program had before the
    -- interface: prints, wraps, and nothing drawn. It is also asked for by name, so it
    -- gets no reason — an apology for a screen you asked for is not a reason.
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, {}, terminal))
    local code = init.main({ "--plain" }, nil)

    t.eq(code, 0, "--plain runs the same session")
    t.eq(init.state.ui, nil, "and builds no interface")
    t.notContains(terminal.text, "plain screen:", "and gives no reason for not having one")
    t.contains(terminal.text, "opencode for ComputerCraft", "but the banner is the one it always was")
  end

  do
    -- A one-shot's output is whatever is on the terminal when the program exits, and a
    -- screen that clears itself and keeps a scrollback nobody can reach once the
    -- program has gone is a worse answer to `opencode "what is 2 + 2"` than printed
    -- text. So the question form deliberately keeps the plain screen.
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, { "what is 2 + 2" }, terminal))
    mock.respond(textTurn("4"))
    local code = init.main({ "what is 2 + 2" }, nil)

    t.eq(code, 0, "a one-shot still answers")
    t.eq(init.state.ui, nil, "and still builds no interface")
    t.contains(terminal.text, "4", "with the answer on the screen it leaves behind")
    t.notContains(mock.gridText(terminal), "enter sends", "and no hint line to go with it")
  end

  do
    -- `--help` lists the escape hatch, because the person who needs it is the one
    -- staring at a screen that will not fit their terminal.
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, { "--help" }, terminal))
    local code = init.main({ "--help" }, nil)

    t.eq(code, 0, "--help exits zero")
    t.contains(terminal.text, "--plain", "and lists the plain screen")
    -- Wrapped at the terminal's own width, like everything else on it.
    t.contains(terminal.text, "no GUI,", "with what it is for")
  end

  do
    -- The complaint the interface exists for. A reply of long paths, no spaces to break
    -- at, on a 51-column terminal: the plain screen threw away everything past the
    -- right edge, and the interface has to bring the whole of it back.
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, {}, terminal))
    local paths = {}
    for i = 1, 6 do
      paths[i] = "/rom/modules/" .. string.rep("nested_", 4) .. i .. ".lua"
    end
    mock.respond(textTurn("These are the files:\n" .. table.concat(paths, "\n")))
    mock.queue({ "char", "l" }, { "char", "i" }, { "char", "s" }, { "char", "t" }, { "key", 28 })
    local code = init.main({}, nil)

    t.eq(code, 0, "a turn in the interface is answered")
    t.eq(terminal.outside, 0, "with nothing drawn outside the screen")
    for _, path in ipairs(paths) do
      t.contains(mock.gridText(terminal), path, "every path in the answer is on the screen: " .. path)
    end
  end

  do
    -- A tool call is a line in the log, and the log is grey while the answer is white.
    -- Both have to survive the width, and the log has to be there at all.
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, {}, terminal))
    mock.respond(toolTurn("read", json.encode({ filePath = mock.root .. "/notes.txt" })))
    mock.respond(textTurn("It has two lines."))
    mock.queue({ "char", "r" }, { "char", "e" }, { "char", "a" }, { "char", "d" }, { "key", 28 })
    local code = init.main({}, nil)

    t.eq(code, 0, "a turn that calls a tool is answered")
    t.contains(mock.gridText(terminal), "notes.txt", "and the tool is in the log")
    t.contains(mock.gridText(terminal), "It has two lines.", "and the answer after it")
  end

  do
    -- The permission question used to be written to a screen and the answer typed at
    -- the terminal, which on a computer with a monitor is a question nobody read. In
    -- the interface the question is a dialog and the answer is typed into the field
    -- under it, so the two are in front of the operator at the same time.
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, {}, terminal))
    writeConfig({
      model = "ollama/llama3",
      permission = { { permission = "read", pattern = "*", action = "ask" } },
    })
    mock.respond(toolTurn("read", json.encode({ filePath = mock.root .. "/notes.txt" })))
    mock.respond(textTurn("I did not read it."))
    mock.queue({ "char", "r" }, { "char", "e" }, { "char", "a" }, { "char", "d" }, { "key", 28 })
    mock.queue({ "char", "n" }, { "key", 28 })
    local code = init.main({}, nil)

    t.eq(code, 0, "a question that has to be asked is asked")
    -- Somewhere in the run, which is the only thing that does not depend on how the
    -- operator got to the answer: a dialog that was drawn and taken off again is not
    -- on the last frame, and which frame it is on depends on the keys in between.
    t.ok(mock.frameContaining(terminal, "Permission: read") ~= nil, "and names what is being asked")
    t.ok(mock.frameContaining(terminal, "notes.txt") ~= nil, "and what it is being asked about")
    t.contains(terminal.text, "Permission denied", "and refusing it goes through")
  end

  do
    -- The buttons on the hint line are the one part of this screen you can press, and
    -- clicking one answers with the command it stands for — so there is one
    -- implementation of `/help` rather than two.
    local terminal = mock.console({ 51, 19 })
    local init = assert(loadInit(nil, {}, terminal))
    mock.queue({ "mouse_click", 1, 40, 18 })
    local code = init.main({}, nil)

    t.eq(code, 0, "a click on the hint line is answered")
    t.contains(mock.gridText(terminal), "Commands:", "with the help the button stands for")
    t.contains(mock.gridText(terminal), "/exit", "and every command in it")
  end

  -- Starting itself.
  --
  -- `init.lua` ends in `return M` and nothing calls `M.main`, so running it does
  -- nothing at all: no error, no output, an immediate return. A test that called
  -- `M.main` itself never noticed, which is why a whole program could sit there
  -- being unstartable while the suite was green.
  --
  -- `require` and "run this file" are indistinguishable from inside the chunk, and
  -- a computer has no `debug.getinfo` to settle it. `shell.getRunningProgram` can,
  -- because `require` leaves it naming whatever program actually started -- so a
  -- program that loads this as a library does not get a REPL as a side effect.

  do
    local init = assert(loadInit())
    t.eq(type(init), "table", "loaded by something else, it stays a library")
    t.eq(type(init.main), "function", "with main left for the caller")
  end

  do
    for _, name in ipairs({ "init.lua", "opencode.lua" }) do
      local screen = mock.screen({})
      local code = loadInit("/program/" .. name, { "--help" }, screen)
      t.eq(code, 0, name .. " is the running program, so it runs: the exit code")
      t.contains(screen.text, "interactive session", name .. " printed the usage rather than nothing")
    end
  end

  do
    -- The same file under a name nobody installed it as is a library, and saying so
    -- is better than starting a REPL inside somebody else's program.
    local screen = mock.screen({})
    local loaded = loadInit("/program/renamed.lua", { "--help" }, screen)
    t.eq(type(loaded), "table", "a name that is not ours does not start it")
    t.eq(screen.text, "", "and prints nothing at all")
  end

  -- Finding the library.
  --
  -- ComputerCraft gives every program its own `require` and its own `package`, and
  -- its searchpath joins a relative pattern onto *the program's own directory*:
  -- `fs.combine(dir, sPath)`. The entry point sits beside `src/`, one level above
  -- the modules, so a bare `require("util")` looks for `<dir>/util.lua`, finds
  -- nothing, and the program dies on its first require without printing a word.
  --
  -- Nothing else in this file can see that. The host's own `package.path` already
  -- answers to this repository's `src/`, so an entry point with no way of finding
  -- its library passes every other test here -- which is what happened, with the
  -- suite green while the program was unstartable on a computer.
  --
  -- So the module search is modelled rather than borrowed. CC loads a program with
  -- `load(contents, "@" .. path, nil, env)` and hands it an env carrying a private
  -- `require` and `package`, so the model does the same: a separate environment with
  -- its own cache, its own path, and a searchpath that resolves relative patterns
  -- against a program directory. Nothing reaches the host's cache, which is what
  -- would otherwise let a stale `require` answer for a module that is not there.

  --- A program environment shaped the way ComputerCraft's is: bare names, a default
  --- path, relative patterns joined onto a program directory, and a private cache.
  local function likeComputerCraft(base, running)
    local fake = { loaded = {}, preload = {}, path = "?;?.lua;?/init.lua", looked = {} }
    -- Declared first because the file searcher below loads modules into it, and a
    -- reference written before this assignment would close over the *spec's* `env`
    -- instead -- which is the environment module, and a very convincing wrong answer.
    local env

    local package = {
      path = fake.path,
      loaded = fake.loaded,
      preload = fake.preload,
    }

    local function search(name)
      for pattern in package.path:gmatch("[^;]+") do
        local candidate = pattern:gsub("%?", (name:gsub("%.", "/")))
        -- A leading separator is used as written; anything else is relative to the
        -- program, which is the behaviour that makes a bare name miss.
        if candidate:sub(1, 1) ~= "/" then
          candidate = base .. "/" .. candidate
        end
        local file = io.open(candidate, "r")
        if file then
          file:close()
          local chunk, err = loadfile(candidate)
          if chunk then
            -- CC loads a module into the program's own environment, so a module that
            -- requires another one searches exactly as the entry point did.
            setfenv(chunk, env)
            fake.looked[#fake.looked + 1] = name
            return chunk, candidate
          end
          return nil, tostring(err)
        end
      end
      return nil, "no file for '" .. name .. "'"
    end

    package.loaders = {
      function(name)
        local loader = fake.preload[name]
        if loader then
          return loader
        end
        return nil, "no field package.preload['" .. name .. "']"
      end,
      search,
    }

    local function require(name)
      if fake.loaded[name] ~= nil then
        return fake.loaded[name]
      end
      local reasons = {}
      for _, searcher in ipairs(package.loaders) do
        local loader, detail = searcher(name)
        if loader then
          fake.loaded[name] = loader(name) or true
          return fake.loaded[name]
        end
        reasons[#reasons + 1] = tostring(detail)
      end
      error("module '" .. name .. "' not found:\n  " .. table.concat(reasons, "\n  "), 0)
    end

    -- The host's globals, with the program on top of them: what CC builds for a
    -- program, minus the parts of a computer that this suite has no use for.
    env = setmetatable({
      require = require,
      package = package,
      shell = { getRunningProgram = function()
        return running
      end },
    }, { __index = _G })

    return env, fake
  end

  do
    local base = t.root
    local env, fake = likeComputerCraft(base, base .. "/harness.lua")
    mock.setup()
    local chunk, err = loadfile(base .. "/init.lua")
    setfenv(chunk, env)
    local ok, result = pcall(chunk)

    t.ok(ok, "a modular checkout loads under ComputerCraft's own module search"
      .. (ok and "" or (" -- it said: " .. tostring(result):gsub("\n", " | "))))
    t.eq(type(ok and result and result.main), "function", "and comes back as an entry point that can be driven")
    t.contains(table.concat(fake.looked, " "), "util", "with the modules really searched for, not answered from a cache")
  end

  do
    -- The same program run as the program, with nothing else to find its library:
    -- the modules are all in `package.preload`, which is the bundle's situation and
    -- the reason the bundle needs none of the path.
    local base = t.root
    local env, fake = likeComputerCraft(base, base .. "/harness.lua")
    setmetatable(fake.preload, {
      __index = function()
        return function()
          return {}
        end
      end,
    })
    local chunk = assert(loadfile(base .. "/init.lua"))
    setfenv(chunk, env)
    local ok, result = pcall(chunk)

    t.ok(ok, "a bundled program loads with nothing on the path at all")
    t.eq(#fake.looked, 0, "because every module was already in package.preload")
    t.eq(type(ok and result), "table", "and it stays a library, because the harness is not its program")
    t.contains(env.package.path, base .. "/src/?.lua", "though the path entries are there, unused")
  end

  do
    -- A program installed at the root is the case where the root is already a
    -- separator, so joining one more would ask for "//?.lua". The load is expected
    -- to fail -- there is no /src on a host -- and it is the path that is being
    -- looked at rather than the result.
    local env, fake = likeComputerCraft("/nowhere", "/init.lua")
    mock.setup()
    local chunk = assert(loadfile(t.root .. "/init.lua"))
    setfenv(chunk, env)
    local ok = pcall(chunk)

    t.ok(not ok, "the load did fail, so this really is the root case")
    local doubled = {}
    for entry in env.package.path:gmatch("[^;]+") do
      if entry:find("//", 1, true) then
        doubled[#doubled + 1] = entry
      end
    end
    t.eq(table.concat(doubled, " "), "", "a program at the root asks for no doubled separator")
    local head = {}
    for entry in env.package.path:gmatch("[^;]+") do
      head[#head + 1] = entry
      if #head == 3 then
        break
      end
    end
    t.eq(table.concat(head, " "), "/?.lua /src/?.lua /src/?/init.lua", "the root being used as one separator")
  end
end
