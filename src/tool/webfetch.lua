-- The `webfetch` tool: retrieve a URL and return its content as text.

local util = require("util")
local http = require("http")
local registry = require("tool/registry")

local MAX_BYTES = 5 * 1024 * 1024
local MAX_TIMEOUT = 120

local DESCRIPTION = [[Fetches content from a URL and returns it as text.

Usage notes:
  - The URL must be fully formed, including the scheme. http:// is upgraded to https://
  - The format may be "text" (default) or "html". HTML is returned as source.
  - Only the body is returned; navigation links and framing are stripped.
  - This tool is read-only and does not modify any files.
  - Large pages are truncated. Fetch a more specific URL when the result is cut off.]]

--- Very small HTML-to-text conversion: drop script/style/nav noise and tags.
local function htmlToText(html)
  local text = html
  for _, tag in ipairs({ "script", "style", "noscript", "svg", "head" }) do
    text = text:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. ">", " ")
  end
  text = text:gsub("<!--.-%-%->", " ")
  text = text:gsub("<br%s*/?>", "\n")
  text = text:gsub("</p>", "\n\n")
  text = text:gsub("</h[1-6]>", "\n\n")
  text = text:gsub("</li>", "\n")
  text = text:gsub("<li[^>]*>", "- ")
  text = text:gsub("<a[^>]*href=\"([^\"]*)\"[^>]*>(.-)</a>", function(_, href, label)
    return util.trim(label) ~= "" and string.format("[%s](%s)", util.trim(label), href) or " "
  end)
  text = text:gsub("<[^>]+>", " ")
  text = text:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
  text = text:gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
  text = text:gsub("[ \t]+", " ")
  text = text:gsub(" *\n *", "\n")
  text = text:gsub("\n{3,}", "\n\n")
  return util.trim(text)
end

registry.define({
  id = "webfetch",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      url = { type = "string", description = "The URL to fetch" },
      format = { type = "string", description = "Either \"text\" (default) or \"html\"" },
      timeout = { type = "number", description = "Timeout in seconds, up to 120. Defaults to 30." },
    },
    required = { "url" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local url = args.url
    if type(url) ~= "string" or url == "" then
      error("The url argument is required.", 0)
    end
    if url:match("^http://") then
      url = "https://" .. url:sub(8)
    end
    if not url:match("^https://") then
      error("The url must start with http:// or https://, got: " .. args.url, 0)
    end

    local timeout = math.min(tonumber(args.timeout) or 30, MAX_TIMEOUT)
    local response, err = http.request(url, { timeout = timeout, maxBytes = MAX_BYTES })
    if not response then
      error("Could not fetch " .. url .. ": " .. tostring(err), 0)
    end
    if response.status < 200 or response.status >= 300 then
      error("Could not fetch " .. url .. ": " .. http.errorMessage(response), 0)
    end

    local body = args.format == "html" and response.body or htmlToText(response.body or "")
    if body == "" then
      body = "(empty response)"
    end

    return {
      title = url,
      metadata = { url = url, status = response.status, bytes = #(response.body or "") },
      output = string.format("<url>%s</url>\n<status>%d</status>\n<content>\n%s\n</content>", url, response.status, body),
    }
  end,
})

return true
