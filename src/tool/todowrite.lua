-- The `todowrite` tool: maintain a structured task list for the session.

local json = require("json")
local registry = require("tool/registry")

local DESCRIPTION = [[Create and maintain a structured task list for the current session. Tracks progress, organizes multi-step work, and surfaces status to the user.

## When to use
Use proactively when:
- The task requires 3 or more distinct steps or actions (not 3 tool calls for one conceptual step)
- The work is non-trivial and benefits from planning
- The user provides multiple tasks (numbered or comma-separated) or asks for a todo list
- New instructions arrive: capture them as todos
- You start a task: mark it in_progress (only one at a time) before working
- You finish a task: mark it completed and add any follow-ups you discovered

## When NOT to use
Skip when:
- The work is a single straightforward task (or fewer than 3 trivial steps)
- The request is purely informational or conversational
- Tracking adds no organizational value

## States
- pending: not started
- in_progress: actively working (exactly ONE at a time)
- completed: finished successfully

## Rules
- Update status in real time; do not batch completions
- Mark completed only after the work is actually done and verified, never based on intent
- Keep exactly one in_progress while work remains
- If blocked or partial, keep it in_progress and add a follow-up todo describing the blocker

## Examples

Use it:
- "Add a dark mode toggle and run the tests" -> multi-step work with explicit verification
- "Rename X to Y across the repo" -> search reveals 5 occurrences in 3 files
- "Implement authentication, catalog, cart, and checkout" -> several complex features

Skip it:
- "How do I print Hello World?" -> informational
- "Add a single comment to a function" -> one edit
- "Run npm install and report what happened" -> one command

When in doubt, use it.]]

local VALID_STATUS = { pending = true, in_progress = true, completed = true, cancelled = true }
local VALID_PRIORITY = { high = true, medium = true, low = true }

registry.define({
  id = "todowrite",
  description = DESCRIPTION,
  parameters = {
    type = "object",
    properties = {
      todos = {
        type = "array",
        description = "The complete updated todo list. Send every todo, not just the ones that changed.",
        items = {
          type = "object",
          properties = {
            content = { type = "string", description = "The task description" },
            status = { type = "string", description = "One of: pending, in_progress, completed, cancelled" },
            priority = { type = "string", description = "One of: high, medium, low" },
          },
          required = { "content", "status", "priority" },
          additionalProperties = false,
        },
      },
    },
    required = { "todos" },
    additionalProperties = false,
  },
  execute = function(args, ctx)
    local todos = args.todos
    if type(todos) ~= "table" then
      error("The todos argument is required and must be an array.", 0)
    end

    local normalised = {}
    local active = 0
    for index, todo in ipairs(todos) do
      if type(todo) ~= "table" or type(todo.content) ~= "string" or todo.content == "" then
        error("Each todo needs a non-empty content string; todo " .. index .. " is invalid.", 0)
      end
      local status = VALID_STATUS[todo.status] and todo.status or "pending"
      if status == "in_progress" then
        active = active + 1
      end
      normalised[#normalised + 1] = {
        content = todo.content,
        status = status,
        priority = VALID_PRIORITY[todo.priority] and todo.priority or "medium",
      }
    end

    if active > 1 then
      error("Exactly one todo may be in_progress at a time, but " .. active .. " were.", 0)
    end

    registry.guard(ctx, "todowrite", { "*" }, { "*" })
    ctx.session.todos = normalised

    return {
      title = string.format("%d todos", #normalised),
      metadata = { todos = normalised },
      output = json.encode(normalised, "  "),
    }
  end,
})

return true
