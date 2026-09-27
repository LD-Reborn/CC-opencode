-- Session message storage.
--
-- A session is a list of messages; each message has a list of parts. The part
-- union mirrors opencode's schema closely enough to keep the model wire format
-- correct: text, reasoning, tool (with a pending/running/completed/error state),
-- step-start, and step-finish.

local json = require("json")
local util = require("util")
local env = require("environment")

local M = {}

local function newSession(id, title)
  return {
    id = id,
    title = title,
    created = os.time(),
    messages = {},
    todos = {},
    permission = {},
  }
end

--- The title a session has until one is generated for it.
M.DEFAULT_TITLE = "New session"

function M.new(title)
  return newSession(util.id("ses"), title or M.DEFAULT_TITLE)
end

function M.latestUserMessage(session)
  for index = #session.messages, 1, -1 do
    if session.messages[index].role == "user" then
      return session.messages[index]
    end
  end
  return nil
end

function M.latestAssistantMessage(session)
  for index = #session.messages, 1, -1 do
    if session.messages[index].role == "assistant" then
      return session.messages[index]
    end
  end
  return nil
end

--- True when the most recent assistant reply belongs to the newest user message
--- and left nothing outstanding.
--
-- The parent check is what makes a second `agent.run` on the same session do
-- something: after a finished turn there *is* an assistant message, so without it
-- a follow-up question would look like a completed turn and the loop would exit
-- before making a request.
function M.isTurnComplete(session)
  local user = M.latestUserMessage(session)
  if not user then
    return true
  end
  local assistant = M.latestAssistantMessage(session)
  if not assistant or assistant.parentID ~= user.id or not assistant.finish then
    return false
  end
  if assistant.finish == "tool-calls" or assistant.finish == "unknown" then
    return false
  end
  for _, part in ipairs(assistant.parts) do
    if part.type == "tool" and not part.state.providerExecuted and part.state.status ~= "error" then
      return false
    end
  end
  return true
end

function M.addUser(session, text)
  local message = { id = util.id("msg"), role = "user", time = { created = os.time() }, parts = { { type = "text", text = text } } }
  session.messages[#session.messages + 1] = message
  return message
end

--- The first thing the user asked, which is what a session title is built from.
function M.firstUserMessage(session)
  for _, message in ipairs(session.messages) do
    if message.role == "user" and not message.summary then
      return message
    end
  end
  return nil
end

--- The concatenated text of a message, or the empty string.
function M.text(message)
  if not message then
    return ""
  end
  local parts = {}
  for _, part in ipairs(message.parts or {}) do
    if part.type == "text" then
      parts[#parts + 1] = part.text
    end
  end
  return table.concat(parts)
end

function M.addAssistant(session, model)
  local user = M.latestUserMessage(session)
  local message = {
    id = util.id("msg"),
    role = "assistant",
    -- Which user turn this replies to, so a finished turn is not mistaken for an
    -- answer to the next question.
    parentID = user and user.id or nil,
    time = { created = os.time() },
    model = model,
    parts = {},
    cost = 0,
    tokens = { input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
  }
  message.parts[#message.parts + 1] = { type = "step-start", time = { start = os.time() } }
  session.messages[#session.messages + 1] = message
  return message
end

function M.addText(message, text)
  local part = { type = "text", text = text, time = { start = os.time() } }
  message.parts[#message.parts + 1] = part
  return part
end

function M.addReasoning(message, text)
  local part = { type = "reasoning", text = text, time = { start = os.time() } }
  message.parts[#message.parts + 1] = part
  return part
end

function M.addToolPart(message, call)
  local part = {
    type = "tool",
    callID = call.id or util.id("call"),
    tool = call.name,
    state = { status = "pending", input = {}, raw = call.arguments or "" },
  }
  message.parts[#message.parts + 1] = part
  return part
end

function M.startTool(part, input)
  part.state.status = "running"
  part.state.input = input
  part.state.time = { start = os.time() }
end

function M.completeTool(part, result)
  part.state.status = "completed"
  part.state.output = result.output
  part.state.title = result.title
  part.state.metadata = result.metadata or {}
  part.state.time = part.state.time or { start = os.time() }
  part.state.time["end"] = os.time()
end

function M.failTool(part, message)
  part.state.status = "error"
  part.state.error = message
  part.state.metadata = part.state.metadata or {}
  part.state.time = part.state.time or { start = os.time() }
  part.state.time["end"] = os.time()
end

function M.finishStep(message, finish, usage)
  message.finish = finish
  if usage then
    message.tokens = usage
  end
  message.parts[#message.parts + 1] = { type = "step-finish", reason = finish, tokens = message.tokens }
  message.time.completed = os.time()
  return message
end

--- Concatenated assistant text across every step of a message.
function M.messageText(message)
  local parts = {}
  for _, part in ipairs(message.parts or {}) do
    if part.type == "text" then
      parts[#parts + 1] = part.text
    end
  end
  return table.concat(parts)
end

--- True when the message is mostly tool bookkeeping and carries no user-facing text.
function M.isSilent(message)
  return #M.messageText(message) == 0
end

local function serialisable(session)
  return {
    id = session.id,
    title = session.title,
    created = session.created,
    todos = session.todos,
    permission = session.permission,
    messages = session.messages,
  }
end

function M.directory()
  return env.combine(env.cwd(), "opencode", "session")
end

function M.save(session)
  local path = env.combine(M.directory(), session.id .. ".json")
  if not env.mkdirs(env.dirname(path)) then
    return nil, "could not create " .. env.dirname(path)
  end
  local encoded = json.encode(serialisable(session), "  ")
  if not encoded then
    return nil, "could not encode the session"
  end
  if not env.write(path, encoded) then
    return nil, "could not write " .. path
  end
  return path
end

function M.load(id)
  local path = env.combine(M.directory(), id .. ".json")
  local content = env.read(path)
  if not content then
    return nil
  end
  local decoded = json.decode(content)
  if type(decoded) ~= "table" then
    return nil
  end
  decoded.permission = decoded.permission or {}
  return decoded
end

--- Every saved session id, newest first.
function M.list()
  local ids = {}
  for _, name in ipairs(env.listDir(M.directory())) do
    local id = name:match("^(ses_[%w]+)%.json$")
    if id then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids, function(a, b) return a > b end)
  return ids
end

return M
