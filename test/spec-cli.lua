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
  local function loadInit()
    mock.setup()
    local path = t.root .. "/init.lua"
    local chunk, err = loadfile(path)
    if not chunk then
      t.ok(false, "could not load init.lua: " .. tostring(err))
      return nil
    end
    return chunk()
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
    local state = init.setup({}, mock.screen({}))

    t.eq(state.agent, "build", "the default agent is build")
    t.eq(state.config.model, "opencode/gpt-5", "the default model comes from the built-in defaults")
    t.eq(state.model.id, "gpt-5", "the default model resolves")
    t.eq(state.model.providerID, "opencode", "the default provider is opencode")
    t.eq(state.model.apiKey, "public", "the opencode profile carries a public key")
    t.eq(state.smallModel.id, "gpt-5-mini", "the small model resolves too")
    t.eq(state.error, nil, "a working config reports no error")
    t.eq(state.autoSave, false, "sessions are not saved unless asked")
    t.eq(state.stream, false, "requests are not streamed unless asked")
    t.eq(type(state.session.id), "string", "setup starts a session")
    t.eq(state.cwd, mock.root, "the working directory defaults to the shell's")
    t.eq(init.state, state, "state is published for the rest of the program")
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
    t.eq(state.model, nil, "a provider with no key resolves to nothing")
    t.contains(state.error, "No API key for provider 'groq'", "the error names the provider")
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
    env.write(mock.root .. "/opencode.json", json.encode({ env = { GROQ_API_KEY = "gsk-test" } }))
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
    t.eq(mock.requests[1].url, "https://models.opencode.ai/api/v1/chat/completions", "the default provider's url is used")
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
    env.write(mock.root .. "/opencode.json", json.encode({ title = false }))
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
    init.main({}, screen)
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
    local init = assert(loadInit())
    local screen = mock.screen({ "/help", "/exit" })
    local code = init.main({}, screen)

    t.eq(code, 0, "the REPL exits zero on /exit")
    t.contains(screen.text, "opencode for ComputerCraft", "the banner is printed")
    t.contains(screen.text, "/model", "/help lists the commands")
    t.contains(screen.text, "/exit", "/help lists every command")
    t.contains(screen.text, "model: opencode/gpt-5", "the banner shows the model")
    t.eq(#mock.requests, 0, "commands do not call a model")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/model", "/model opencode/gpt-5-mini", "/model", "/exit" })
    init.main({}, screen)
    t.contains(screen.text, "opencode/gpt-5-mini", "/model <id> switches the model")
    t.eq(init.state.config.model, "opencode/gpt-5-mini", "the switch is kept in the state")
    t.eq(init.state.model.id, "gpt-5-mini", "the resolved model follows")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/model groq/llama", "/exit" })
    init.main({}, screen)
    t.contains(screen.text, "No API key", "an unusable model is refused with a reason")
    t.eq(init.state.config.model, "opencode/gpt-5", "the previous model is kept")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/models", "/exit" })
    init.main({}, screen)
    t.contains(screen.text, "No models are listed in the config", "an empty config explains itself")
    t.contains(screen.text, "opencode.json", "and says where to add one")
  end

  do
    local init = assert(loadInit())
    env.write(mock.root .. "/opencode.json", json.encode({
      env = { GROQ_API_KEY = "gsk-test" },
      provider = { groq = { models = { ["llama-3.3-70b"] = { name = "Llama 3.3 70B" } } } },
    }))
    local screen = mock.screen({ "/models", "/providers", "/exit" })
    init.main({}, screen)
    t.contains(screen.text, "groq/llama-3.3-70b", "/models lists configured models")
    t.contains(screen.text, "openrouter", "/providers lists the built-in providers")
    t.contains(screen.text, "(no api key)", "and marks the ones with no key")
    t.contains(screen.text, "no api key", "groq has a key, so it is not marked")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/agent", "/agent plan", "/agent", "/agent explore", "/agent nonsense", "/exit" })
    init.main({}, screen)
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
    init.main({}, screen)
    for _, id in ipairs({ "bash", "read", "glob", "grep", "edit", "write", "webfetch", "todowrite" }) do
      t.contains(screen.text, id, "/tools lists " .. id)
    end
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/new", "/new", "/exit" })
    init.main({}, screen)

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
    init.main({}, screen)
    t.contains(screen.text, "saved ", "/save reports the path")
    t.eq(#env.listDir(env.combine(mock.root, "opencode", "session")), 1, "/save wrote one file")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/nonsense", "/exit" })
    init.main({}, screen)
    t.contains(screen.text, "Unknown command /nonsense", "an unknown command is reported")
    t.contains(screen.text, "Try /help", "and points at the help")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "/", "   ", "/exit" })
    local code = init.main({}, screen)
    t.eq(code, 0, "a bare slash and a blank line are ignored rather than sent")
    t.eq(#mock.requests, 0, "nothing was sent to a model")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({})
    local code = init.main({}, screen)
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
    init.main({}, screen)

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
    init.main({}, screen)

    t.contains(screen.text, "  * write " .. mock.root .. "/new.txt", "the call is logged with its path")
    t.contains(screen.text, "    Created " .. mock.root .. "/new.txt", "a title that says more than the argument is logged")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "read a missing file", "/exit" })
    mock.respond(toolTurn("read", json.encode({ filePath = mock.root .. "/missing.txt" })))
    mock.respond(textTurn("It is not there."))
    init.main({}, screen)
    t.contains(screen.text, "File not found: " .. mock.root .. "/missing.txt", "a tool error names the file")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "list the files", "/exit" })
    mock.respond(toolTurn("nosuchtool", "{}"))
    mock.respond(textTurn("Sorry about that."))
    init.main({}, screen)
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
    init.main({}, screen)
    t.contains(screen.text, "(reasoning) weighing the options", "reasoning is shown, and set apart from the answer")
  end

  do
    local init = assert(loadInit())
    local screen = mock.screen({ "a long path", "/exit" })
    local path = mock.root .. "/" .. string.rep("deep/", 20) .. "file.txt"
    mock.respond(toolTurn("read", json.encode({ filePath = path })))
    mock.respond(textTurn("ok"))
    init.main({}, screen)

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
    init.main({}, screen)
    t.contains(screen.text, "  * todowrite", "a tool with no single obvious argument still logs something")
  end

  -- Screens

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
    local screen = mock.screen({ "/help", "/exit" })
    mock.attach({ monitor_1 = screen })
    local code = init.main({}, nil)

    t.eq(code, 0, "the REPL reads from the monitor when one is attached")
    t.contains(screen.text, "/exit", "the command list made it onto the monitor")
    t.eq(screen.cursorBlink, false, "the cursor is left not blinking after the last read")
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
end
