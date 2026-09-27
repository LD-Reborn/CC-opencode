-- Provider and model resolution.
--
-- Model ids are `provider/model`, split on the FIRST slash only, so nested ids
-- like `openrouter/anthropic/claude-sonnet-4` resolve to provider `openrouter`
-- with model id `anthropic/claude-sonnet-4`.

local config = require("config")
local util = require("util")

local M = {}

M.DEFAULT_LIMIT = { context = 128 * 1024, output = 8 * 1024 }

M.SSE_PATH = "/chat/completions"

--- Re-exported so callers only need this module to resolve a credential.
M.apiKey = config.apiKey

--- Split a model string into its provider and model halves.
function M.parseModel(model)
  local slash = model:find("/", 1, true)
  if not slash then
    return model, ""
  end
  return model:sub(1, slash - 1), model:sub(slash + 1)
end

--- Merge a built-in profile with any user override of the same provider id.
local function buildProfile(id, override)
  local profile = config.PROFILES[id] or {}
  local merged = util.deepCopy(profile)
  merged.id = id
  merged.base = (override and override.api) or profile.base
  merged.name = (override and override.name) or profile.name or id
  merged.env = (override and override.env) or profile.env
  merged.apiKey = profile.apiKey
  if override and override.options then
    merged.options = util.deepCopy(override.options)
  end
  return merged
end

--- All known providers: built-in profiles overlaid with `config.provider`.
function M.list(configValue)
  local providers = {}
  for id, _ in pairs(config.PROFILES) do
    providers[id] = buildProfile(id, (configValue.provider or {})[id])
  end
  for id, override in pairs(configValue.provider or {}) do
    providers[id] = buildProfile(id, override)
  end
  return providers
end

--- Resolved provider entry: base url, credential, and model metadata.
function M.get(configValue, providerID)
  local providers = M.list(configValue)
  local provider = providers[providerID]
  if not provider then
    return nil, "Unknown provider '" .. providerID .. "'. Add it under \"provider\" in opencode.json."
  end
  if not provider.base then
    return nil, "Provider '" .. providerID .. "' has no baseURL. Set options.baseURL in opencode.json."
  end
  local key = config.apiKey(configValue, provider)
  if not key then
    local names = table.concat(provider.env or {}, ", ")
    return nil, "No API key for provider '" .. providerID .. "'. Set options.apiKey, options.apiKeyFile, or env."
      .. (names ~= "" and (" (" .. names .. ")") or "")
  end
  provider.apiKeyResolved = key
  return provider
end

local function mergeOptions(providerOptions, modelOptions)
  local out = util.deepCopy(providerOptions or {})
  for key, value in pairs(modelOptions or {}) do
    out[key] = value
  end
  return out
end

--- Metadata for one model within a provider, merged with the provider defaults.
function M.model(configValue, providerID, modelID)
  local provider = M.get(configValue, providerID)
  if not provider then
    return nil, select(2, M.get(configValue, providerID))
  end
  local override = ((configValue.provider or {})[providerID] or {}).models or {}
  local entry = override[modelID] or {}
  return {
    providerID = providerID,
    id = modelID,
    name = entry.name or modelID,
    base = provider.base,
    apiKey = provider.apiKeyResolved,
    api = provider.api,
    limit = entry.limit or M.DEFAULT_LIMIT,
    options = mergeOptions(provider.options, entry.options),
    headers = entry.headers or (provider.options or {}).headers,
  }
end

--- Resolve a full `provider/model` string, including default-model selection.
function M.resolve(configValue, modelString)
  if not modelString or modelString == "" then
    return nil, "No model configured. Set \"model\" in opencode.json, e.g. \"openrouter/anthropic/claude-sonnet-4\"."
  end
  local providerID, modelID = M.parseModel(modelString)
  if modelID == "" then
    return nil, "Model '" .. modelString .. "' has no model part. Use the form provider/model."
  end
  local model, err = M.model(configValue, providerID, modelID)
  if not model then
    return nil, err
  end
  return model
end

--- Full request url for a model: base with trailing slashes trimmed, plus the path.
function M.url(model, path)
  return model.base:gsub("/+$", "") .. (path or M.SSE_PATH)
end

--- Every `provider/model` pair the config can reach, for model pickers.
function M.availableModels(configValue)
  local out = {}
  for id, provider in pairs(M.list(configValue)) do
    local configured = ((configValue.provider or {})[id] or {}).models
    if configured and util.count(configured) > 0 then
      for modelID, entry in pairs(configured) do
        out[#out + 1] = {
          id = id .. "/" .. modelID,
          name = entry.name or modelID,
          provider = provider.name or id,
          available = config.apiKey(configValue, provider) ~= nil,
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

return M
