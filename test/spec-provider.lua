-- provider: model id parsing and provider/credential resolution. Every failure
-- here is a failure the user sees before any request is made, so the messages
-- matter as much as the behaviour.

return function(t, mock)
  local provider = require("provider")
  local config = require("config")

  t.suite("provider")

  -- parseModel splits on the first slash only, so nested model ids survive.

  t.eq(select(1, provider.parseModel("openai/gpt-4")), "openai", "the provider is the first segment")
  t.eq(select(2, provider.parseModel("openai/gpt-4")), "gpt-4", "the model is the rest")
  t.eq(select(1, provider.parseModel("openrouter/anthropic/claude-sonnet-4")), "openrouter", "only the first slash splits")
  t.eq(select(2, provider.parseModel("openrouter/anthropic/claude-sonnet-4")), "anthropic/claude-sonnet-4", "the nested model id is kept whole")
  t.eq(select(1, provider.parseModel("gpt-4")), "gpt-4", "a bare model has no provider")
  t.eq(select(2, provider.parseModel("gpt-4")), "", "a bare model has an empty model part")

  -- A config with an inline key, which is the simplest custom provider.

  local inline = {
    cwd = mock.root,
    provider = {
      openai = { options = { apiKey = "sk-test" } },
      ["local"] = {
        name = "My Server",
        api = "http://localhost:8080/v1",
        options = { apiKey = "abc123" },
        models = { ["my-model"] = { name = "My Model" } },
      },
    },
  }

  local models = provider.availableModels(inline)
  t.eq(#models, 1, "only providers with a models map are listed")
  t.eq(models[1].id, "local/my-model", "the picker shows provider/model")
  t.eq(models[1].name, "My Model", "the picker shows a friendly name")
  t.eq(models[1].available, true, "a provider with a key is marked available")

  local missing = provider.availableModels({ cwd = mock.root, provider = { ["local"] = { api = "http://x/v1", models = { m = {} } } } })
  t.eq(missing[1].available, false, "a provider without a key is marked unavailable")

  local resolved = provider.resolve(inline, "openai/gpt-4o")
  t.eq(resolved.id, "gpt-4o", "resolve returns the model id")
  t.eq(resolved.providerID, "openai", "resolve returns the provider id")
  t.eq(resolved.base, "https://api.openai.com/v1", "a built-in base url is used when none is configured")
  t.eq(resolved.apiKey, "sk-test", "an inline key is resolved")

  local custom = provider.resolve(inline, "local/my-model")
  t.eq(custom.base, "http://localhost:8080/v1", "a custom base url is used")
  t.eq(custom.name, "My Model", "the model's display name is used")

  -- Limits: a config may declare them, otherwise the default applies.

  t.eq(custom.limit.context, provider.DEFAULT_LIMIT.context, "the default context limit is applied")
  local limited = provider.resolve({
    cwd = mock.root,
    provider = { p = { api = "http://x/v1", options = { apiKey = "k" }, models = { m = { limit = { context = 1000, output = 100 } } } } },
  }, "p/m")
  t.eq(limited.limit.context, 1000, "a configured context limit wins")
  t.eq(limited.limit.output, 100, "a configured output limit wins")

  -- Errors

  t.eq(select(1, provider.resolve(inline, nil)), nil, "a missing model is an error")
  t.contains(select(2, provider.resolve(inline, nil)), "No model configured", "a missing model explains itself")
  t.contains(select(2, provider.resolve(inline, "openai")), "provider/model", "a model without a slash is rejected")

  local unknown, unknownMessage = provider.resolve(inline, "nope/some-model")
  t.eq(unknown, nil, "an unknown provider fails")
  t.contains(unknownMessage, "Unknown provider 'nope'", "an unknown provider names itself")

  local keyless, keylessMessage = provider.resolve({ cwd = mock.root, provider = { x = { api = "http://x/v1" } } }, "x/m")
  t.eq(keyless, nil, "a provider without a key fails")
  t.contains(keylessMessage, "No API key", "a missing key explains itself")

  local baseless, baselessMessage = provider.resolve({
    cwd = mock.root,
    provider = { y = { options = { apiKey = "k" } } },
  }, "y/m")
  t.eq(baseless, nil, "a provider without a base url fails")
  t.contains(baselessMessage, "no baseURL", "a missing base url explains itself")

  -- Credentials: env table, key file, and inline key, in that precedence.

  local fromEnv = provider.get({
    cwd = mock.root,
    env = { GROQ_API_KEY = "from-env" },
  }, "groq")
  t.eq(fromEnv.apiKeyResolved, "from-env", "a key is read from the env table by its documented name")

  t.eq(provider.get({ cwd = mock.root }, "ollama").apiKeyResolved, "ollama", "a provider with a built-in key needs no env")
  t.eq(provider.get({ cwd = mock.root }, "opencode").apiKeyResolved, "public", "the opencode profile ships a public key")
  t.eq(provider.get({ cwd = mock.root }, "lmstudio").apiKeyResolved, "lmstudio", "the lmstudio profile ships a local key")

  local keyPath = mock.root .. "/token.txt"
  mock.writtenFiles()
  local handle = assert(io.open(keyPath, "w"))
  handle:write("  file-key\n")
  handle:close()
  local fromFile = provider.get({
    cwd = mock.root,
    provider = { cerebras = { options = { apiKeyFile = "token.txt" } } },
  }, "cerebras")
  t.eq(fromFile.apiKeyResolved, "file-key", "a key file is read and trimmed")
  t.eq(provider.apiKey({ cwd = mock.root, env = { CEREBRAS_API_KEY = "env-key" } }, {
    env = { "CEREBRAS_API_KEY" },
    options = { apiKeyFile = "token.txt" },
  }), "file-key", "a key file takes precedence over the env table")

  t.eq(provider.apiKey({ cwd = mock.root }, { options = { apiKey = "inline" } }), "inline", "an inline key takes precedence over everything")
  t.eq(provider.apiKey({ cwd = mock.root }, { env = { "X" } }), nil, "no credential at all is nil, not an empty string")

  -- A provider override keeps the built-in env names so a key can still come
  -- from the env table when only the base url is overridden.

  local overridden = provider.get({ cwd = mock.root, env = { OPENAI_API_KEY = "sk-env" } }, "openai")
  t.eq(overridden.apiKeyResolved, "sk-env", "an override that only sets the base keeps the env names")

  -- url trims trailing slashes so a configured base with one still works.

  t.eq(provider.url({ base = "https://api.x.com/v1" }), "https://api.x.com/v1/chat/completions", "the chat path is appended")
  t.eq(provider.url({ base = "https://api.x.com/v1/" }), "https://api.x.com/v1/chat/completions", "a trailing slash is trimmed")
  t.eq(provider.url({ base = "https://api.x.com/v1///" }, "/models"), "https://api.x.com/v1/models", "an explicit path is used")

  -- list merges built-ins with overrides.
  local all = provider.list(inline)
  t.ok(all.groq, "built-in providers are listed")
  t.eq(all.groq.name, "Groq", "a built-in keeps its display name")
  t.ok(all["local"], "a custom provider is listed")
  t.eq(all["local"].name, "My Server", "a custom provider keeps its display name")

  -- config.load is exercised here too, since provider resolution depends on it.
  local loaded = config.load(mock.root, { model = "local/my-model" })
  t.eq(loaded.model, "local/my-model", "an override beats the built-in default")
  t.eq(loaded.cwd, mock.root, "the working directory is recorded")
  t.eq(config.load(mock.root).model, config.DEFAULT_MODEL, "the default model is used when nothing overrides it")
  t.eq(loaded.tool_output.max_bytes, 51200, "tool output limits come through the config")
  t.ok(#loaded.permission > 0, "the default permission ruleset is present")

  local handle2 = io.open(mock.root .. "/opencode.json", "w")
  handle2:write('{"model":"openai/gpt-4o","env":{"OPENAI_API_KEY":"sk-file"},"tool_output":{"max_lines":10}}')
  handle2:close()
  local fromFile2 = config.load(mock.root)
  t.eq(fromFile2.model, "openai/gpt-4o", "opencode.json overrides the default model")
  t.eq(fromFile2.env.OPENAI_API_KEY, "sk-file", "opencode.json supplies credentials")
  t.eq(fromFile2.tool_output.max_lines, 10, "opencode.json overrides nested values")
  t.eq(fromFile2.tool_output.max_bytes, 51200, "unrelated nested values keep their default")
  t.eq(fromFile2.__source, mock.root .. "/opencode.json", "the config records where it came from")

  local broken = io.open(mock.root .. "/opencode.json", "w")
  broken:write("{not json")
  broken:close()
  local survived = config.load(mock.root)
  t.eq(survived.model, config.DEFAULT_MODEL, "a malformed config falls back to the defaults")
end
