-- Configuration loading.
--
-- Precedence, lowest to highest: built-in defaults, `opencode.json` in the
-- working directory, `/opencode.json`, then runtime overrides passed by the CLI.

local json = require("json")
local util = require("util")
local env = require("environment")

local M = {}

-- Both of these are ids the gateway actually serves, which is worth stating
-- because the obvious guess for a small model is not one of them: titles and
-- compaction summaries go to the small model on every saved session, and a
-- retired id fails the whole turn rather than degrading to a worse title.
M.DEFAULT_MODEL = "opencode/gpt-5"
M.DEFAULT_SMALL_MODEL = "opencode/gpt-5-nano"

M.DEFAULTS = {
  model = M.DEFAULT_MODEL,
  small_model = M.DEFAULT_SMALL_MODEL,
  tool_output = { max_lines = 2000, max_bytes = 50 * 1024 },
  compaction = { auto = true, reserved = 20 * 1024 },
  -- Name a session from its first question when it is saved. Set to false to
  -- skip the extra request.
  title = true,
  agent = {
    build = { steps = 25 },
    general = { steps = 15 },
    plan = { steps = 25 },
  },
  permission = {
    { permission = "*", pattern = "*", action = "allow" },
    { permission = "doom_loop", pattern = "*", action = "ask" },
    { permission = "external_directory", pattern = "*", action = "ask" },
    { permission = "read", pattern = "*.env", action = "ask" },
    { permission = "read", pattern = "*.env.*", action = "ask" },
    { permission = "read", pattern = "*.env.example", action = "allow" },
  },
}

--- Built-in OpenAI-compatible providers, mirroring opencode's profile table.
-- `env` lists the variable names the credential is read from in `config.env`,
-- which stands in for a real process environment.
M.PROFILES = {
  -- The gateway is on opencode.ai, not on models.opencode.ai. That looks like a
  -- near-miss and is not one: models.opencode.ai is the models.dev website, and
  -- it answers every path under it with a 302 to its front page, so a base url
  -- pointing there connects and then hands back HTML where a JSON reply should
  -- be. It needs a key like any other provider; the key is issued on opencode.ai
  -- and goes in `env.OPENCODE_API_KEY`.
  opencode = { name = "opencode zen", base = "https://opencode.ai/zen/v1", env = { "OPENCODE_API_KEY" } },
  openai = { name = "OpenAI", base = "https://api.openai.com/v1", env = { "OPENAI_API_KEY" } },
  openrouter = { name = "OpenRouter", base = "https://openrouter.ai/api/v1", env = { "OPENROUTER_API_KEY" } },
  groq = { name = "Groq", base = "https://api.groq.com/openai/v1", env = { "GROQ_API_KEY" } },
  cerebras = { name = "Cerebras", base = "https://api.cerebras.ai/v1", env = { "CEREBRAS_API_KEY" } },
  deepinfra = { name = "DeepInfra", base = "https://api.deepinfra.com/v1/openai", env = { "DEEPINFRA_API_KEY" } },
  deepseek = { name = "DeepSeek", base = "https://api.deepseek.com/v1", env = { "DEEPSEEK_API_KEY" } },
  fireworks = { name = "Fireworks", base = "https://api.fireworks.ai/inference/v1", env = { "FIREWORKS_API_KEY" } },
  togetherai = { name = "Together AI", base = "https://api.together.xyz/v1", env = { "TOGETHER_API_KEY" } },
  xai = { name = "xAI", base = "https://api.x.ai/v1", env = { "XAI_API_KEY" } },
  ollama = { name = "Ollama", base = "http://localhost:11434/v1", env = { "OLLAMA_API_KEY" }, apiKey = "ollama" },
  lmstudio = { name = "LM Studio", base = "http://localhost:1234/v1", env = { "LMSTUDIO_API_KEY" }, apiKey = "lmstudio" },
}

--- Search paths for opencode.json, relative entries resolved against the cwd.
M.CONFIG_PATHS = { "opencode.json", "/opencode.json", "/.opencode/opencode.json" }

local function readConfigFile(path)
  local content = env.read(path)
  if not content then
    return nil
  end
  return json.decode(content)
end

local function merge(target, source)
  for key, value in pairs(source) do
    if type(value) == "table" and type(target[key]) == "table" then
      merge(target[key], value)
    else
      target[key] = value
    end
  end
  return target
end

local function readAll(cwd)
  local config = {}
  for _, candidate in ipairs(M.CONFIG_PATHS) do
    local path = util.startswith(candidate, "/") and candidate or env.combine(cwd, candidate)
    local parsed = readConfigFile(path)
    if type(parsed) == "table" then
      merge(config, parsed)
      config.__source = config.__source or path
    end
  end
  return config
end

--- Load configuration, applying `overrides` from the command line on top.
function M.load(cwd, overrides)
  local config = merge(util.deepCopy(M.DEFAULTS), readAll(cwd or env.cwd()))
  if overrides then
    merge(config, overrides)
  end
  config.cwd = cwd or env.cwd()
  return config
end

--- Read an API key from the config, a key file, or `config.env`.
function M.apiKey(config, provider)
  local options = provider.options or {}
  if type(options.apiKey) == "string" and options.apiKey ~= "" then
    return options.apiKey
  end
  if type(options.apiKeyFile) == "string" and options.apiKeyFile ~= "" then
    local path = util.startswith(options.apiKeyFile, "/") and options.apiKeyFile
      or env.combine(config.cwd, options.apiKeyFile)
    local content = env.read(path)
    if content then
      return util.trim(content)
    end
  end
  for _, name in ipairs(provider.env or {}) do
    local value = (config.env or {})[name]
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  -- Profiles that need no real credential (a public key, or a local server that
  -- ignores the header) carry one. It is the last resort so a supplied
  -- credential always wins.
  if type(provider.apiKey) == "string" and provider.apiKey ~= "" then
    return provider.apiKey
  end
  return nil
end

function M.toolOutputLimits(config)
  local options = config.tool_output or {}
  return {
    max_lines = options.max_lines or M.DEFAULTS.tool_output.max_lines,
    max_bytes = options.max_bytes or M.DEFAULTS.tool_output.max_bytes,
  }
end

return M
