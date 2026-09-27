-- The interactive screen: a bounded GUI over the computer's own terminal.
--
-- The plain screen -- `environment.screen` -- is a printer's adapter: everything
-- handed to `write` goes onto the hardware, wrapped, in order, and there is no way
-- back to change any of it. That is enough for `opencode "what is 2 + 2"`, which
-- prints an answer and exits, and not much else. A REPL on a 51-column screen
-- scrolls a conversation off the top and keeps none of it, and nothing on the
-- screen can be scrolled back through, re-read, or pointed at.
--
-- This module is the other kind of screen. It keeps the conversation, wraps it to
-- the width it actually has, and shows a window of it: a title bar, a scrollback
-- pane, a hint line, and an input field. It is deliberately a drop-in for the
-- plain one -- `write`, `setTextColor`, `getSize` and the rest mean what they
-- always did -- so the agent, the tools and the permission prompt are written once
-- and do not know which screen they are drawing on.
--
-- ## Where it draws, and why not a monitor
--
-- On the terminal, always. CraftOS's keyboard belongs to the terminal, so a
-- screenful of controls drawn on a monitor is a screenful of controls nobody can
-- reach: `read` reads the terminal whatever the program is drawing on, and an
-- input field on a monitor cannot be typed into. `M.open` therefore takes the
-- console. A monitor is still what the plain screen prefers, and `--plain` is how
-- you get that instead.
--
-- ## What comes from CC-GUI, and what does not
--
-- The widgets are CC-GUI's: `GUI.createInput` owns the text, the caret and the
-- scroll window, `GUI.createButton` is a button, and `GUI.handleEvent` does the
-- editing and the hit-testing, so the field behaves as the library's own demos
-- do. What is here is everything around them.
--
-- The drawing is ours, and that is the point. CC-GUI does not enforce its own
-- boundaries: `GUI.drawText` writes whatever text it is handed at whatever
-- position it is handed, so a label one column wider than its column runs off the
-- edge, and `GUI.drawAll` clears every screen once per control in `pairs` order,
-- redrawing overlapping widgets in whatever order the hash table happens to
-- produce. On a real terminal a write past the right edge carries onto the next
-- row, so the damage is not a clipped label; it is the title bar drawn over the
-- transcript. So every draw here goes through `blit`, which clips to the box and
-- then to the screen, or `fill`, which clamps its box, and the layout is computed
-- rather than guessed. `GUI.drawText` and `GUI.fillRegion` are still what put the
-- characters down; they are simply never called with an argument that can escape.
--
-- The transcript is not a CC-GUI `List`. A list is an array of fixed rows in one
-- colour with a click-driven selection, and a conversation is none of those: its
-- rows are wrapped on the way in, each carries the colour the renderer chose for
-- it, it grows a piece at a time while a reply streams in, and it is capped. It
-- is a scrollback buffer, so that is what it is.

local util = require("util")
local env = require("environment")

local M = {}

--- CC-GUI, if it is installed.
--
-- An external file, like any other dependency, and optional in the sense that a
-- missing one is survivable: `M.open` answers nil and a reason, and the entry
-- point says the reason and falls back to the plain screen. A computer with no
-- `GUI.lua` beside the program gets a working program with a plainer screen, which
-- is a good deal better than a working program that dies on a require.
local haveGUI, GUI = pcall(require, "GUI")
M.GUI = haveGUI and GUI or nil

-- A computer's terminal is 51x19, and that is the size this has to look right at.
-- A screen smaller than this gets the plain screen instead: a title bar, a hint
-- line and an input field with two rows of conversation between them is a layout
-- nobody can read, which is worse than the plain one.
M.MIN_WIDTH = 24
M.MIN_HEIGHT = 8

-- How much conversation is kept. ComputerCraft's memory is the scarce resource
-- here, and a scrollback that grows for the life of a long session is the one
-- thing in this program that could bring it down. 1000 lines is a session's worth;
-- what falls off the top is counted and said on screen rather than lost quietly.
M.MAX_LINES = 1000
-- Trimmed in batches, because dropping one line at a time from a thousand-line
-- table is a thousand copies of a thousand entries.
M.TRIM_SLACK = 100

-- How many submitted lines the up and down keys walk through.
M.HISTORY = 50

-- How often the screen is repainted while text is arriving on its own.
--
-- A streamed reply comes in as a few hundred pieces, and a full repaint of a 51x19
-- screen is a few thousand cell writes, so repainting on each one would spend more
-- time drawing the answer than receiving it. Twenty a second is faster than the
-- eye can see a line appear, and costs one repaint in fifty pieces. Without a clock
-- to measure against -- a CraftOS too old for `os.timer`, or the test harness --
-- every write repaints, which is slower and never wrong.
M.REDRAW_INTERVAL = 0.05

-- Colour is used sparingly, as everywhere else in this project. The title bar and
-- the hint line are the two bars, and the buttons are lighter than the bar they sit
-- on so that they read as something to press rather than as more of the row.
--
-- The greys are chosen for contrast rather than for looks: CraftOS's `gray` is a
-- mid grey, `lightGray` a pale one and `darkGray` a near-black, so a title bar wants
-- `gray` under white text and a hint bar wants `darkGray` under `lightGray`.
local WHITE, BLACK = colors.white, colors.black
local LIGHT_GRAY, GRAY = colors.lightGray, colors.gray
local DARK_GRAY = colors.darkGray
local ACCENT = colors.lightBlue
local RED = colors.red

-- CraftOS key codes. The numbers are the stable part; `keys.getName` is consulted
-- afterwards for anything not in the table, so a binding survives a CraftOS that
-- spells its key names differently.
local KEY = {
  enter = 28,
  backspace = 14,
  tab = 43,
  del = 12,
  up = 208,
  down = 209,
  left = 210,
  right = 211,
  lshift = 256,
  rshift = 257,
  lctrl = 258,
  rctrl = 259,
  home = 274,
  fin = 275,
  pageup = 278,
  pagedown = 279,
}

-- CC-GUI names its keys through `keys.getName`, which spells some of these
-- differently, so both spellings are accepted. Every name compared against goes
-- through this.
local KEY_ALIASES = {
  ["page up"] = "pageup",
  ["page down"] = "pagedown",
  pageUp = "pageup",
  pageDown = "pagedown",
  pgup = "pageup",
  pgdn = "pagedown",
  ["return"] = "enter",
  escape = "esc",
  delete = "del",
  back = "backspace",
  shift = "lshift",
  ctrl = "lctrl",
}

-- CC-GUI redraws every control itself when it handles an event, with the unclipped
-- drawing described above. The redraw is the only part to neutralise: the click
-- dispatch and the input editing it does are both wanted, and this module redraws
-- the whole screen straight afterwards anyway.
local function noop() end

--- The first `width` bytes of `text`, never splitting a UTF-8 character.
--
-- A model writes prose, and prose is not always ASCII. Cutting a line at a byte in
-- the middle of a multi-byte character leaves the replacement glyph on screen,
-- which on a font with one is a black box at the end of every wrapped line. A
-- continuation byte is `10xxxxxx`, so walking back while the byte after the cut is
-- one lands on the start of the character instead.
local function cut(text, width)
  text = tostring(text or "")
  if #text <= width then
    return text
  end
  if width < 1 then
    return ""
  end
  local at = width
  while at > 1 do
    local byte = string.byte(text, at + 1)
    if not byte or byte < 0x80 or byte >= 0xC0 then
      break
    end
    at = at - 1
  end
  return text:sub(1, at)
end

--- `text` clipped to a box `width` wide and `height` rows tall.
--
-- A row too wide is cut and a row past the bottom is left out, which is what keeps
-- a widget inside its own space: nothing here can produce a string wider than
-- `width` or taller than `height` rows.
local function clip(text, width, height)
  if width < 1 or height < 1 then
    return ""
  end
  local rows, at = {}, 1
  while at <= #text and #rows < height do
    local stop = text:find("\n", at, true)
    rows[#rows + 1] = cut(stop and text:sub(at, stop - 1) or text:sub(at), width)
    if not stop then
      break
    end
    at = stop + 1
  end
  return table.concat(rows, "\n")
end

--- Break `text` to `width` columns, hanging the continuation lines under it.
--
-- The tool log indents its lines -- `"  * read /very/long/path"` -- and a wrapped
-- tool call whose every continuation lands back in column one reads as though the
-- model had said four separate things. So the line's own leading whitespace
-- becomes a hanging indent, widened by two. `util.wrap` does the breaking; this
-- only says where the pieces go.
local function wrapText(text, width)
  text = tostring(text or "")
  local indent = text:match("^[ \t]*") or ""
  local hanging = indent .. "  "
  local pieces = util.wrap(text:sub(#indent + 1), math.max(width - #indent, 8))
  local out = {}
  for index, piece in ipairs(pieces) do
    out[index] = (index == 1 and indent or hanging) .. piece
  end
  return out
end

local U = {}
U.__index = U

--- A UI over `raw`, or nil plus the reason there cannot be one.
--
-- The reasons are worth keeping apart, because they want different answers: no
-- `GUI.lua` is an install problem, a screen that is too small is a monitor that
-- is too small for this, and neither should stop the program running.
function M.open(raw, options)
  options = options or {}
  if not M.GUI then
    return nil, "CC-GUI (GUI.lua) is not installed beside the program"
  end
  if not raw or type(raw.getSize) ~= "function" then
    return nil, "there is no terminal to draw on"
  end
  local width, height = raw.getSize()
  if type(width) ~= "number" or type(height) ~= "number" then
    return nil, "the terminal did not report a size"
  end
  if width < M.MIN_WIDTH or height < M.MIN_HEIGHT then
    return nil, string.format("the terminal is only %dx%d, too small for the interface", width, height)
  end
  local system = env.system()
  if not system.pullEvent then
    return nil, "there is no event queue to read the keyboard from"
  end

  local self = setmetatable({}, U)
  self.screen = raw
  self.raw = raw -- so `environment.screen` hands a UI back unchanged
  self.system = system
  self.maxLines = options.maxLines or M.MAX_LINES
  self.historyLimit = options.history or M.HISTORY
  -- Whatever this machine calls the time. Read once here rather than per write,
  -- since the whole point is that the answer has to come from the same place every
  -- time, and `os.timer` is the wall clock where it exists and `os.clock` is not.
  self.now = system.timer or system.clock
  self.lastPaint = nil

  -- The transcript. `lines` are the logical ones, as the renderer produced them;
  -- `vlines` are the same conversation after wrapping, which is what the viewport
  -- indexes. Both are kept because wrapping is the expensive half: a redraw
  -- happens on every keystroke, and re-wrapping a thousand lines each time would
  -- make the interface slower than the program it is watching. A new line appends to
  -- both, `vstart` says where in `vlines` the logical one begins, and `trim` moves
  -- both together so the buffer stays as long as the cap says it is.
  self.lines = {}
  self.vlines = {}
  self.vcount = 0
  self.dropped = 0
  self.pending = { text = "", colour = WHITE }
  self.tail = nil -- the pending line, wrapped; nil when out of date
  self.bodyWidth = width
  self.fg, self.bg = WHITE, BLACK
  self.top = 1 -- first visible row of the buffer
  self.follow = true -- whether the viewport is pinned to the newest line
  self.history = {}
  self.historyIndex = 0
  self.stash = "" -- what was being typed when the operator reached for history

  self.prompt = "> "
  self.status = nil
  self.title = "opencode"
  self.subtitle = ""
  self.buttons = {}
  self.controls = {}
  self.modal = nil
  self.answer = nil
  self.clicked = nil
  self.choices = nil

  -- The screen surface, called with a dot or a colon.
  --
  -- ComputerCraft calls a screen's methods with a dot — `term.write(text)`, not
  -- `term:write(text)` — and so does the adapter this object is standing in for,
  -- which is the contract every caller in this program is already written against.
  -- The implementations stay on the metatable, where they read as methods and can
  -- reach the state; what goes on the instance is a closure that passes it on. One
  -- table, so a caller can hold it as a screen and as the thing that has a
  -- `readLine`, and neither of those is a different object from the other.
  --
  -- Both call forms are taken, because only one of them working is how `ui:write`
  -- ends up appending the word "table" to a conversation: the first argument of a
  -- colon call is the screen itself, and a text argument is a string, so one
  -- pointer comparison tells them apart. It is the same answer either way, which is
  -- the point -- a screen's methods are called both ways in the wild, and the one
  -- that quietly did nothing was the reason this needed finding.
  for name in pairs({
    write = true,
    clear = true,
    scroll = true,
    setCursorBlink = true,
    setCursorPos = true,
    getCursorPos = true,
    getSize = true,
    setTextColor = true,
    setBackgroundColor = true,
  }) do
    local method = U[name]
    self[name] = function(...)
      local first = ...
      if first == self then
        return method(self, select(2, ...))
      end
      return method(self, ...)
    end
  end
  -- A field, not a method, because the adapter's is a field too and this stands in
  -- for it. False is the whole of the answer: a GUI on a monitor is a GUI nobody
  -- can type into.
  self.isMonitor = false

  -- CC-GUI's input field. Its `textOffset` is the start of the visible window, so
  -- the field draws itself as a window onto whatever is typed, and this module only
  -- has to say how wide that window is.
  self.field = GUI.createInput("", 1, 1, 1, 1, BLACK, WHITE)
  self.field.borderColor = BLACK -- the library's border is a row either side, and
  -- the rows either side of this one are the hint line and the bottom of the screen
  self.field.monitor = raw
  self.field.cursorPos = 1

  self:relayout()
  return self
end

--- Whether this screen is a UI, so a caller can branch on the two at once.
function M.isUI(screen)
  return getmetatable(screen) == U
end

-- The screen surface
--
-- Below here is what the rest of the program sees. These are the methods
-- `environment.screen` produces, meaning what they always meant -- and they are
-- also how the transcript is filled, because `write` is the whole of it.

--- Append `text` to the conversation, honouring the newlines in it.
--
-- The tail with no newline after it is held back rather than committed, because a
-- streamed reply arrives in pieces and committing each one would put a line break
-- in the middle of every sentence. It is drawn as the live end of the
-- conversation instead, so the answer appears as it is written and still ends up
-- one line when it is finished.
function U:write(text)
  if text == nil then
    return nil
  end
  text = tostring(text)
  local at = 1
  while true do
    local stop = text:find("\n", at, true)
    self:append(stop and text:sub(at, stop - 1) or text:sub(at))
    if not stop then
      break
    end
    self:commit()
    at = stop + 1
  end
  -- Not `draw`: nothing here is waiting for a key, so there is nothing to force a
  -- repaint, and the whole reason a streamed answer appears as it is written is
  -- that this happens while the turn is still running.
  self:touch()
  return true
end

--- Repaint, unless one happened very recently.
--
-- Called from `write` rather than from the event loop because the two are not the
-- same: the event loop runs when the operator does something, and a reply that
-- arrives over the network arrives with nobody having touched anything. The clock
-- is what tells the two apart, and a machine without one simply repaints every
-- time.
function U:touch()
  if self.lastPaint and self.now() - self.lastPaint < M.REDRAW_INTERVAL then
    return false
  end
  self:draw()
  return true
end

--- Add to the line being built, breaking it if the colour changed.
--
-- A colour change is a line break, because that is what it is on a terminal: the
-- renderer writes the tool log in grey and the answer in white, and the whole point
-- of the two is that they are two different lines.
function U:append(piece)
  if piece == "" then
    return
  end
  if #self.pending.text > 0 and self.pending.colour ~= self.fg then
    self:commit()
  end
  self.pending.colour = self.fg
  self.pending.text = self.pending.text .. piece
  self.tail = nil
end

--- Finish the line being built, and start the next.
function U:commit()
  local line = { text = self.pending.text, colour = self.pending.colour, vstart = self.vcount + 1 }
  self.lines[#self.lines + 1] = line
  for _, piece in ipairs(wrapText(line.text, self.bodyWidth)) do
    self.vcount = self.vcount + 1
    self.vlines[self.vcount] = { text = piece, colour = line.colour }
  end
  self.pending.text = ""
  self.tail = nil
  self:trim()
end

--- Drop the oldest lines once there are enough of them to be worth the shifting.
--
-- Both tables move, and the second one is the reason. `vlines` is the larger of the
-- two -- a line of prose is often two or three rows -- so leaving the dropped rows in
-- it would mean the cap bounds the smaller table and a session that ran for hours
-- grew without limit in the one place the cap exists to stop it. So the rows go too,
-- and the line that says which row of the buffer each logical line starts at is
-- renumbered to match.
--
-- `lines` is left dense as well, which is not tidiness. `#` on a table with a hole
-- at the front returns whatever border the interpreter finds, and both this
-- function and the caller that wants the newest line want a count: with a hole,
-- `#self.lines` is 120 where there are 1000 lines, and nothing here can be trusted.
function U:trim()
  local count = #self.lines
  if count <= self.maxLines + M.TRIM_SLACK then
    return
  end
  local drop = count - self.maxLines
  local kept = count - drop
  -- How many rows the dropped lines took, which is how far everything moves up.
  local shift = self.lines[drop + 1].vstart - 1

  for index = 1, kept do
    self.lines[index] = self.lines[index + drop]
  end
  for index = kept + 1, count do
    self.lines[index] = nil
  end
  for _, line in ipairs(self.lines) do
    line.vstart = line.vstart - shift
  end

  local rows = self.vcount - shift
  for index = 1, rows do
    self.vlines[index] = self.vlines[index + shift]
  end
  for index = rows + 1, self.vcount do
    self.vlines[index] = nil
  end
  self.vcount = rows

  self.dropped = self.dropped + drop
  self.top = math.max(self.top, 1)
end

--- The conversation still being written, wrapped, as the rows it takes on screen.
--
-- Cached, because the tail is re-wrapped on every redraw otherwise and it is the
-- one part of the buffer that changes as the model speaks.
function U:tailLines()
  if self.pending.text == "" then
    return {}
  end
  if not self.tail then
    self.tail = {}
    for _, piece in ipairs(wrapText(self.pending.text, self.bodyWidth)) do
      self.tail[#self.tail + 1] = { text = piece, colour = self.pending.colour }
    end
  end
  return self.tail
end

--- Row `index` of the whole conversation, tail included.
function U:row(index)
  local line = self.vlines[index]
  if line then
    return line
  end
  return self:tailLines()[index - self.vcount]
end

--- How many rows the whole conversation takes.
--
-- Named for what it counts rather than what it is: `self.rows` is the layout, and
-- a method of the same name on the same object is the one that gets called.
function U:rowCount()
  return self.vcount + #self:tailLines()
end

--- Re-wrap everything, after the screen changed width.
--
-- A monitor can be resized while a program is running, and a transcript wrapped for
-- the old width would keep the old line breaks. Everything else about the layout is
-- recomputed on each redraw; this is the one part that is stored wrapped, so it is
-- the one part that has to be told.
function U:rewrap()
  self.vlines = {}
  self.vcount = 0
  for _, line in ipairs(self.lines) do
    line.vstart = self.vcount + 1
    for _, piece in ipairs(wrapText(line.text, self.bodyWidth)) do
      self.vcount = self.vcount + 1
      self.vlines[self.vcount] = { text = piece, colour = line.colour }
    end
  end
  self.tail = nil
  self.top = math.max(self.top, 1)
end

--- Forget the conversation, for `/clear` and for a fresh session.
function U:clearTranscript()
  self.lines = {}
  self.vlines = {}
  self.vcount = 0
  self.dropped = 0
  self.pending.text = ""
  self.tail = nil
  self.top = 1
  self.follow = true
end

--- The screen surface, as ComputerCraft and the adapter both call it.
--
-- These take `self` and are reached through the wrappers `M.open` puts on the
-- instance, so that `monitor.write(text)` finds a function whose only argument is
-- `text`. The wrappers are the boundary: a screen's methods are called with a dot --
-- `term.write(text)`, not `term:write(text)` -- and so are the adapter's, and this
-- object is standing in for one. Everything else in this module is called with a
-- colon, as the rest of Lua is.
--
-- `scroll` answers nil rather than scrolling, and that is not a gap: the
-- conversation is a buffer windowed onto the screen, so there is no scrolled-off
-- hardware state here to scroll, and a caller that asks is asking a question this
-- screen has a different word for.

function U:scroll()
  return nil
end

function U:clear()
  return self.screen.clear and self.screen.clear()
end

function U:setCursorBlink(state)
  return self.screen.setCursorBlink and self.screen.setCursorBlink(state)
end

function U:setCursorPos(x, y)
  return self.screen.setCursorPos and self.screen.setCursorPos(x, y)
end

function U:getCursorPos()
  return self.screen.getCursorPos()
end

function U:getSize()
  return self.screen.getSize()
end

function U:setTextColor(colour)
  self.fg = colour
end

function U:setBackgroundColor(colour)
  self.bg = colour
end

-- Chrome
--
-- What the operator sees around the conversation. All of it is a function of the
-- current size and the current state, and none of it is stored, so a redraw after a
-- resize comes out the same as a redraw after a keystroke.

--- Work out where everything goes, and how wide the input field is.
function U:relayout()
  local width, height = self.screen.getSize()
  local moved = width ~= self.width or height ~= self.height
  self.width, self.height = width, height
  self.rows = {
    header = 1,
    view = 2,
    -- Three rows are chrome: the title bar, the hint line, and the input. A
    -- computer's terminal is 19 rows, so the conversation gets 16 of them, which is
    -- most of a screen and rather more than the plain screen ever showed at once.
    viewHeight = math.max(height - 3, 1),
    hint = height - 1,
    input = height,
  }
  self.bodyWidth = width
  -- After the new width, not before. `rewrap` measures against `bodyWidth`, so
  -- calling it on the way in re-wraps the transcript to the width the screen just
  -- stopped being -- which looks correct until the next resize, where it is one
  -- size behind again and stays there.
  if moved then
    self:rewrap()
  end
  self:placeButtons()
  self:placeField()
end

--- The buttons on the hint line, right-aligned, created once and then moved.
--
-- Created once because CC-GUI keeps every control it has ever made in one list and
-- walks it on every click, so a button rebuilt on every redraw would make each
-- click slower than the last, without end. Dropped whole when they would leave no
-- room for the hint: half a row of buttons is half a row of buttons with no room
-- in them to read the labels.
function U:placeButtons()
  self.buttons = {}
  local wanted = {
    { label = "New", command = "/new" },
    { label = "Save", command = "/save" },
    { label = "Help", command = "/help" },
    { label = "Exit", command = "/exit" },
  }
  local needed = 0
  for _, button in ipairs(wanted) do
    needed = needed + #button.label + 3
  end
  needed = needed - 1
  -- Recorded rather than recomputed, because `drawHint` has to leave exactly the
  -- space the buttons took and a second count of the same thing is a second chance
  -- to get it wrong by a column.
  self.buttonsWidth = needed
  if needed + 12 > self.width then
    self.buttonsWidth = 0
    return
  end
  if #self.controls ~= #wanted then
    self.controls = {}
    for index, button in ipairs(wanted) do
      -- At rest `lightGray` on the `darkGray` bar, which is the one pairing on this
      -- screen with enough contrast to read at 51 columns; pressed, the other way
      -- round, so a press is visible while the timer that un-presses it runs.
      local control = GUI.createButton(button.label, 1, 1, #button.label + 2, 1,
        BLACK, LIGHT_GRAY, WHITE, GRAY)
      control.toggle = false -- a press, not a switch: it flashes and lets go
      control.timeout = 0.4
      control.monitor = self.screen
      control.onClick = function()
        self.clicked = wanted[index].command
      end
      self.controls[index] = control
    end
  end
  local x = self.width - needed + 1
  for index, button in ipairs(wanted) do
    local control = self.controls[index]
    control.x, control.y = x, self.rows.hint
    control.w, control.h = #button.label + 2, 1
    self.buttons[#self.buttons + 1] = {
      control = control,
      command = button.command,
      x = x,
      y = self.rows.hint,
      w = control.w,
      h = 1,
    }
    x = x + control.w + 1
  end
end

--- Put the input field after the prompt marker, running to the right edge.
--
-- The field's own width is what CC-GUI measures the text against, so it has to be
-- the real remaining width or its scroll window is off by the length of the marker.
function U:placeField()
  local marker = #self.prompt
  self.field.x = 1 + marker
  self.field.y = self.rows.input
  self.field.w = math.max(self.width - marker, 1)
  self.field.monitor = self.screen
end

--- The title bar: the program, what it is talking to, and what it is doing.
function U:drawHeader()
  local width = self.width
  self:fill(1, 1, width, 1, GRAY)

  -- The status is what changes and what is a guess about how long it will last, so
  -- it is what gets cut when the row is too narrow. Losing the middle of a model
  -- name is better than losing the word that says the program is still working.
  local status = self.status
  local statusText = status and (status.text or "") or ""
  local right = math.min(#statusText, math.floor(width / 2))
  local room = math.max(width - right - 1, 0)

  -- On a computer's terminal the model id is longer than the row, and the title
  -- would be the first thing to go: what the program is talking to is the useful
  -- half and the name is already in the shell's history and in the banner.
  local left = self.title
  if #left + 2 + #self.subtitle > room then
    left = ""
  end
  if left ~= "" then
    self:blit(1, 1, #left, 1, left, WHITE, GRAY)
  end
  if self.subtitle ~= "" and room > 4 then
    self:blit(#left + 2, 1, room - #left - 1, 1, self.subtitle, LIGHT_GRAY, GRAY)
  end
  if right > 0 then
    self:blit(width - right + 1, 1, right, 1, statusText, status and status.colour or WHITE, GRAY)
  end
end

--- The conversation, windowed.
function U:drawTranscript()
  local rows = self.rows
  local height = rows.viewHeight

  -- How many lines fell off the top is said on screen, in the one row that is about
  -- it, rather than the transcript simply starting in the middle of itself.
  local used = 0
  if self.dropped > 0 then
    used = 1
    self:blit(1, rows.view, self.width, 1,
      string.format("... %d earlier lines dropped", self.dropped), LIGHT_GRAY, BLACK)
  end

  local top = self:viewportTop(height - used)
  for offset = used, height - 1 do
    local line = self:row(top + offset - used)
    if not line then
      break
    end
    self:blit(1, rows.view + offset, self.width, 1, line.text, line.colour, BLACK)
  end
end

--- The hint line: what the keys do, and the buttons.
--
-- The bar under it is `darkGray` and the buttons on it are `lightGray`, the other
-- way round from the title bar. A `gray` bar with `gray` buttons on it is one grey
-- row with no distinction in it, and the point of the buttons is that they are the
-- parts of this screen you can press.
function U:drawHint()
  local row = self.rows.hint
  self:fill(1, row, self.width, row, DARK_GRAY)
  local room = math.max(self.width - self.buttonsWidth - 1, 0)
  if room > 0 then
    self:blit(1, row, room, 1, self:hint(), GRAY, DARK_GRAY)
  end
  for _, button in ipairs(self.buttons) do
    local control = button.control
    local background = control.state and control.activeBackgroundColor or control.backgroundColor
    local foreground = control.state and control.activeTextColor or control.textColor
    self:fill(button.x, button.y, button.x + button.w - 1, button.y, background)
    self:blit(button.x + 1, button.y, #control.text, 1, control.text, foreground, background)
  end
end

--- The text under the operator's hands, and the caret in it.
function U:drawInput()
  local row = self.rows.input
  self:fill(1, row, self.width, row, BLACK)
  self:blit(1, row, #self.prompt, 1, self.prompt, ACCENT, BLACK)

  local field = self.field
  -- CC-GUI keeps the scroll window itself, and walks it back while the caret moves
  -- left, so it can go negative before the caret reaches the start. Reading it
  -- clamped is cheaper than trying to follow the library's arithmetic.
  local offset = math.min(math.max(field.textOffset or 0, 0), math.max(#field.text - 1, 0))
  field.textOffset = offset
  local visible = cut(field.text:sub(offset + 1), field.w)
  if visible ~= "" then
    self:blit(field.x, row, field.w, 1, visible, field.textColor, field.backgroundColor)
  end

  -- The caret as a block, rather than as the terminal's own blinking cursor: the
  -- screen's cursor belongs to whatever drew last, and a field redrawn on every
  -- keystroke has no way to keep it still.
  local caret = math.min(math.max(field.cursorPos or 1, 1), #field.text + 1)
  local column = field.x + (caret - 1 - offset)
  if column >= field.x and column <= self.width then
    local char = field.text:sub(caret, caret)
    self:fill(column, row, column, row, field.textColor)
    self:blit(column, row, 1, 1, char == "" and " " or char, field.backgroundColor, field.textColor)
  end
  self.screen.setCursorPos(math.min(math.max(column, 1), self.width), row)
end

--- Where the permission dialog sits, and how big it is.
--
-- In one place, because the drawing and the click hit-test have to agree on it, and
-- a click test that is one row out would answer a different question from the one
-- on screen.
function U:modalBox()
  local modal = self.modal
  if not modal then
    return nil
  end
  local width, height = self.width, self.height
  local boxWidth = math.max(math.min(width - 4, 64), math.min(width, 16))
  local available = math.max(height - 3, 3)
  local contentRows = math.max(math.min(#modal.lines, available - 2), 1)
  local boxHeight = contentRows + 3 -- header, content, gap, choices
  local left = math.max(math.floor((width - boxWidth) / 2) + 1, 1)
  local top = math.max(math.min(math.floor((height - boxHeight) / 2), height - boxHeight), 1)
  return {
    left = left,
    top = top,
    right = left + boxWidth - 1,
    bottom = top + boxHeight - 1,
    width = boxWidth,
    contentTop = top + 1,
    contentRows = contentRows,
    choicesRow = top + boxHeight - 1,
  }
end

--- The dialog's own buttons, across its bottom row.
function U:modalChoices(box)
  local wanted = { { label = "y once", value = "y" }, { label = "a always", value = "a" }, { label = "n no", value = "n" } }
  local needed = 0
  for _, choice in ipairs(wanted) do
    needed = needed + #choice.label + 2
  end
  if needed > box.width - 2 then
    -- Too narrow for the words, so the letters alone; the hint line under the
    -- dialog says what each of them does.
    wanted = { { label = "y", value = "y" }, { label = "a", value = "a" }, { label = "n", value = "n" } }
    needed = 0
    for _, choice in ipairs(wanted) do
      needed = needed + #choice.label + 2
    end
  end
  local at = box.left + 1
  for _, choice in ipairs(wanted) do
    if at + #choice.label - 1 > box.right then
      break
    end
    choice.x, choice.y = at, box.choicesRow
    self.choices[#self.choices + 1] = choice
    at = at + #choice.label + 2
  end
end

--- The permission question, over the conversation.
function U:drawModal()
  local box = self:modalBox()
  if not box then
    return
  end
  local modal = self.modal

  self:fill(box.left, box.top, box.right, box.bottom, BLACK)
  self:fill(box.left, box.top, box.right, box.top, GRAY)
  self:blit(box.left + 1, box.top, box.width - 2, 1, modal.title, WHITE, GRAY)

  -- The question scrolls rather than being cut, and says how much is below,
  -- because a permission question whose patterns are off the bottom of a dialog is a
  -- question that gets answered without being read.
  local first = math.min(modal.scroll, math.max(#modal.lines - box.contentRows + 1, 1))
  for offset = 0, box.contentRows - 1 do
    local line = modal.lines[first + offset]
    if not line then
      break
    end
    self:blit(box.left + 1, box.contentTop + offset, box.width - 2, 1, line, WHITE, BLACK)
  end
  if #modal.lines > box.contentRows then
    local below = #modal.lines - (first + box.contentRows - 1)
    self:blit(box.left + 1, box.contentTop + box.contentRows - 1, box.width - 2, 1,
      string.format("... %d more line(s) below", below), LIGHT_GRAY, BLACK)
  end

  self.choices = {}
  self:modalChoices(box)
  self:fill(box.left, box.choicesRow, box.right, box.choicesRow, GRAY)
  for _, choice in ipairs(self.choices) do
    self:blit(choice.x, choice.y, #choice.label, 1, choice.label, BLACK, LIGHT_GRAY)
  end
  if modal.note and modal.note ~= "" then
    self:blit(box.left + 1, box.choicesRow - 1, box.width - 2, 1, modal.note, LIGHT_GRAY, BLACK)
  end
end

--- Everything, in order.
function U:draw()
  -- Recorded here rather than in `touch`, so that a repaint the event loop asked
  -- for counts as a repaint and `touch` does not immediately add a second one on
  -- top of it.
  self.lastPaint = self.now and self.now() or nil
  self:relayout()
  self.screen.clear()
  self.screen.setTextColor(WHITE)
  self.screen.setBackgroundColor(BLACK)
  self:drawHeader()
  self:drawTranscript()
  self:drawHint()
  self:drawInput()
  self:drawModal()
end

-- Bounded drawing
--
-- The two primitives everything above goes through, and the whole of the boundary
-- rule CC-GUI does not have. Both take already-bounded arguments, so a mistake in
-- the layout costs a truncated label rather than a screenful of somebody else's
-- text.

--- Write `text` at (x, y), inside a box `width` wide and `height` rows tall.
--
-- Clipped to the box first, so a widget cannot spill into its neighbour, and then
-- to the screen: an origin off the edge is dropped outright rather than clamped,
-- because a clamped origin would put the text somewhere the layout did not intend
-- and a write past the right edge carries onto the next row on a real terminal.
function U:blit(x, y, width, height, text, foreground, background)
  local screenWidth, screenHeight = self.width, self.height
  x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
  if x < 1 or y < 1 or x > screenWidth or y > screenHeight then
    return false
  end
  width = math.min(math.floor(width or 0), screenWidth - x + 1)
  height = math.min(math.floor(height or 0), screenHeight - y + 1)
  local clipped = clip(text, width, height)
  if clipped == "" then
    return false
  end
  GUI.drawText(self.screen, x, y, foreground or WHITE, background or BLACK, clipped)
  return true
end

--- Fill a box, clamped to the screen.
function U:fill(x1, y1, x2, y2, colour)
  local width, height = self.width, self.height
  x1, x2 = math.min(x1, x2), math.max(x1, x2)
  y1, y2 = math.min(y1, y2), math.max(y1, y2)
  x1, y1 = math.max(x1, 1), math.max(y1, 1)
  x2, y2 = math.min(x2, width), math.min(y2, height)
  if x1 > x2 or y1 > y2 then
    return false
  end
  GUI.fillRegion(self.screen, x1, y1, x2, y2, colour)
  return true
end

-- The viewport
--
-- Which rows of the conversation are on screen, and how the operator moves through
-- them. `follow` is the whole of it: pinned to the newest row, so a reply that is
-- arriving stays in view, and released as soon as the operator scrolls back.

--- The newest row a viewport `height` rows tall can start at.
--
-- One definition, because the two places that need it have to agree. `drawTranscript`
-- worked this out as `rowCount() - height + 1` and the scroll arithmetic as
-- `rowCount() - (height - 1) + 1`, which is a different row: scrolling down to the
-- bottom of a full conversation then moved the view one row past it and said the
-- conversation was not scrolled when it was, so the next line to arrive pulled the
-- screen away from the answer.
function U:bottomRow(height)
  return math.max(self:rowCount() - math.max(height, 1) + 1, 1)
end

--- The first visible row of a viewport `height` rows tall.
--
-- The viewport is allowed to run past the end of the conversation -- there is
-- nothing to draw down there -- so a short one sits at the top of its space rather
-- than being stretched to fill it.
function U:viewportTop(height)
  if self.follow then
    return self:bottomRow(height)
  end
  return math.min(math.max(self.top, 1), self:bottomRow(height))
end

--- Move the viewport by `delta` rows.
function U:scrollBy(delta)
  local last = self:bottomRow(self.rows.viewHeight)
  if self.follow then
    self.top = last
  end
  self.top = math.min(math.max(self.top + delta, 1), last)
  -- Past the newest row is not "scrolled": the conversation is pinned again, so the
  -- next line to arrive stays in view.
  self.follow = self.top >= last
end

function U:scrollToEnd()
  self.follow = true
end

function U:scrollToStart()
  self.follow = false
  self.top = 1
end

-- State the rest of the program sets

--- What the title bar says the program is doing.
function U:setStatus(text, colour)
  if text == nil then
    self.status = nil
  else
    self.status = { text = tostring(text), colour = colour or LIGHT_GRAY }
  end
end

--- The model and the agent, beside the title.
function U:setSubtitle(text)
  self.subtitle = tostring(text or "")
end

function U:setTitle(text)
  self.title = tostring(text or "")
end

--- The hint line. A method, so a dialog can say what it wants instead.
function U:hint()
  if self.modal then
    return "y / a / n, or type why not"
  end
  if self.follow then
    return "enter sends  /help lists  pgup scrolls"
  end
  return "pgdn follows  enter sends  /help lists"
end

-- The field

function U:inputText()
  return self.field.text
end

function U:setInputText(text)
  self.field.text = text or ""
  self.field.textOffset = 0
  self.field.cursorPos = 1
end

function U:resetInput()
  self:setInputText("")
end

function U:submittedText()
  return util.trim(self.field.text)
end

-- Events

--- The name of a key code: the table first, `keys.getName` second.
--
-- The table is first because the numbers are documented and the names are a
-- convenience that spells half of them differently.
function U:keyName(code)
  for name, value in pairs(KEY) do
    if value == code then
      return name
    end
  end
  local name
  if self.system.keyName then
    local ok, named = pcall(self.system.keyName, code)
    if ok then
      name = named
    end
  end
  if name and name ~= "unknown" then
    return KEY_ALIASES[name] or name
  end
  return nil
end

--- Hand one event to CC-GUI, with its redraw switched off.
--
-- The click dispatch and the input editing are wanted; the redraw is not, because it
-- would repaint the screen with the unclipped drawing described at the top of this
-- file. `pcall` because a library error on a keystroke should show up on the screen
-- rather than take the program down in the middle of a conversation.
function U:delegate(event)
  local drawAll = GUI.drawAll
  GUI.drawAll = noop
  local ok, err = pcall(GUI.handleEvent, event)
  GUI.drawAll = drawAll
  if not ok then
    self:setStatus("input error: " .. tostring(err), RED)
    return false
  end
  return true
end

--- One event, and what it means here.
--
-- Returns a table with an `action`, or nil. The keys this screen has an opinion
-- about are answered here; everything else goes to CC-GUI, which owns the text in
-- the field. The result is a table rather than a loose value because there are six
-- different things an event can turn out to be, and a number that means "scroll
-- up" and a string that means "scroll up" are not distinguishable at the call site.
function U:handle(event)
  local name = event[1]

  if name == "mouse_click" then
    local x, y = event[3], event[4]
    for _, choice in ipairs(self.choices or {}) do
      if x >= choice.x and x < choice.x + #choice.label and y == choice.y then
        self.answer = choice.value
        return { action = "submit" }
      end
    end
    self.clicked = nil
    if not self:hitButton(x, y) then
      return nil
    end
    self:delegate(event)
    return self.clicked and { action = "command", text = self.clicked } or nil
  end

  if name == "monitor_touch" then
    -- The interface is on the terminal, so a touch on some other screen is not ours.
    -- CC-GUI would try to match the monitor against every widget's screen, find
    -- they differ, and dispatch nothing -- which is right, but for a long reason.
    return nil
  end

  if name == "key" or name == "key_up" then
    local key = self:keyName(event[2])
    -- On the press, never on the release. ComputerCraft sends both, and a key
    -- handled on both is a key that happens twice: holding the up arrow walks back
    -- through the history two entries per press, and holding enter submits the empty
    -- line twice. The release is CC-GUI's, and CC-GUI is the only thing that wants
    -- it -- it does the text editing on `key_up` and ignores `key` altogether.
    if name == "key_up" then
      self:delegate(event)
      return nil
    end
    if key == "enter" then
      return { action = "submit" }
    elseif key == "up" then
      return { action = "history", direction = -1 }
    elseif key == "down" then
      return { action = "history", direction = 1 }
    elseif key == "pageup" then
      return { action = "scroll", delta = -math.max(self.rows.viewHeight - 1, 1) }
    elseif key == "pagedown" then
      return { action = "scroll", delta = math.max(self.rows.viewHeight - 1, 1) }
    elseif key == "home" or key == "lctrl" or key == "rctrl" then
      return { action = "start" }
    elseif key == "fin" then
      return { action = "end" }
    end
    return nil
  end

  if name == "char" or name == "timer" then
    -- Timers are forwarded because that is how CC-GUI un-presses a button.
    self:delegate(event)
    return nil
  end

  return nil
end

--- True when (x, y) is one of this screen's own buttons.
--
-- Checked here as well as inside CC-GUI, whose hit test is one column and one row
-- wider than the button it drew. That extra column is the gap between two buttons,
-- and letting it through would mean a click in the gap could press the button to
-- the left of it.
function U:hitButton(x, y)
  for _, button in ipairs(self.buttons) do
    if x >= button.x and x < button.x + button.w and y >= button.y and y < button.y + button.h then
      return true
    end
  end
  return false
end

--- One blocking wait for something to happen, or nil if there will not be one.
--
-- Nil is the end of input, which is what CraftOS's `read` reports and what the REPL
-- exits on. A hand-rolled key loop has to be able to hear it too, or a terminal that
-- has gone away leaves the loop spinning on a nil event forever -- and the only thing
-- that tells a program from a program that is stuck is whether it comes back.
function U:pull()
  local event = { self.system.pullEvent() }
  if event[1] == nil then
    return nil
  end
  return event
end

--- Move through the submitted lines with the up and down keys.
--
-- Not CraftOS's history -- `read` is not used here, so there is no history to have.
-- This is a ring of what this session has been asked, which is the part of it worth
-- having. The entry being typed is stashed, so walking to the oldest and back again
-- does not lose it.
function U:historyStep(direction)
  local count = #self.history
  if count == 0 then
    return
  end
  -- Each end of the walk is its own end. Up at the oldest entry and down at the
  -- line being typed are both already as far as it goes, and one clamp serving both
  -- directions turns the walk into a ring: up past the oldest drops the operator out
  -- of the history and back onto the stashed line, and down onto the stashed line
  -- throws it away and steps into the history a second time.
  if self.historyIndex == 0 then
    if direction > 0 then
      return
    end
    self.stash = self.field.text
    self.historyIndex = 1
    self:setInputText(self.history[1])
    return
  end
  local next = self.historyIndex + (direction < 0 and 1 or -1)
  -- Down to nothing is the line being typed, which sits outside the history
  -- entirely; up past the oldest stays on the oldest. Both ends are a step too far,
  -- and the direction says which end it is -- so reading the direction rather than
  -- the index is what keeps a single clamp from serving both.
  if next < 1 then
    self.historyIndex = 0
    self:setInputText(self.stash)
    return
  end
  if next > count then
    self.historyIndex = count
    self:setInputText(self.history[count])
    return
  end
  self.historyIndex = next
  self:setInputText(self.history[next])
end

--- Remember a submitted line, newest first, without repeats.
function U:pushHistory(text)
  if text == nil or text == "" then
    return
  end
  for index = #self.history, 1, -1 do
    if self.history[index] == text then
      table.remove(self.history, index)
    end
  end
  table.insert(self.history, 1, text)
  while #self.history > self.historyLimit do
    table.remove(self.history)
  end
  self.historyIndex = 0
end

--- Run until the operator submits. Returns the text, or nil if the program is closing.
--
-- This is the `read` the plain screen uses, with the same job and none of the
-- terminal echo, so the field, the caret and the history are drawn where they can
-- be seen. A clicked button answers with the command it stands for, so there is one
-- implementation of `/help` rather than two.
function U:readLine(options)
  options = options or {}
  self.mode = "prompt"
  self.modal = nil
  self.answer = nil
  self.prompt = options.prompt or "> "
  self.choices = {}
  self:relayout()
  self:resetInput()
  if options.text then
    self:setInputText(options.text)
  end
  self.historyIndex = 0
  self:scrollToEnd()
  self:draw()

  while true do
    local event = self:pull()
    if not event then
      -- The terminal is gone, so there is nobody left to answer. The field is
      -- cleared and the conversation left as it is, because the REPL's exit path
      -- runs on this nil and a screen with the last line still in it is what the
      -- operator last saw.
      self:relayout()
      self:resetInput()
      self:draw()
      return nil
    end
    local result = self:handle(event)
    local action = result and result.action
    if action == "submit" then
      local text = self.field.text
      self:pushHistory(text)
      self:relayout()
      self:resetInput()
      self:draw()
      return text
    elseif action == "command" then
      self:relayout()
      self:resetInput()
      self:draw()
      return result.text
    elseif action == "history" then
      self:historyStep(result.direction)
    elseif action == "scroll" then
      self:scrollBy(result.delta)
    elseif action == "start" then
      self:scrollToStart()
    elseif action == "end" then
      self:scrollToEnd()
    end
    self:draw()
  end
end

--- Put the permission question on screen and wait for an answer.
--
-- `spec` is what the permission module would otherwise print, and the answer is the
-- same string `read` would have produced: `"y"`, `"a"`, `"n"`, or
-- `"feedback:<what the operator said>"`. Asking it here rather than through `read`
-- is what puts the question on the screen the operator is looking at: `read`
-- prints nothing, so the question went to a monitor nobody was reading while the
-- answer was typed blind at the terminal.
function U:ask(spec)
  spec = spec or {}
  self.mode = "ask"
  self.answer = nil
  self.modal = {
    title = string.format("Permission: %s", spec.permission or "?"),
    lines = self:questionLines(spec),
    note = spec.title,
    scroll = 1,
  }
  self.prompt = "> "
  self.choices = {}
  self:relayout()
  self:resetInput()
  self:draw()

  while true do
    local event = self:pull()
    if not event then
      -- Nobody left to ask, and the question cannot be answered. The dialog is taken
      -- off the screen and the empty answer goes back, which the permission module
      -- reads as a refusal: the safe direction to fail unattended.
      self.modal = nil
      self.choices = {}
      self:relayout()
      self:resetInput()
      self:draw()
      return ""
    end
    local result = self:handle(event)
    local action = result and result.action
    if action == "submit" then
      local reply = self.answer or self:submittedText()
      self.modal = nil
      self.answer = nil
      self.choices = {}
      self:relayout()
      self:resetInput()
      self:draw()
      return reply
    elseif action == "history" then
      -- Up and down scroll the question rather than the conversation behind it,
      -- because the part of the question that is off the bottom is the part being
      -- asked about.
      self.modal.scroll = math.max(1, self.modal.scroll + (result.direction < 0 and 1 or -1))
    elseif action == "scroll" then
      self.modal.scroll = math.max(1, self.modal.scroll + (result.delta < 0 and 1 or -1))
    end
    self:draw()
  end
end

--- The question, as the wrapped lines the dialog shows.
function U:questionLines(spec)
  local width = math.max(math.min(self.width - 6, 58), 10)
  local lines = {}
  local patterns = spec.patterns
  if patterns == nil or #patterns == 0 then
    patterns = { "*" }
  end
  for index, pattern in ipairs(patterns) do
    if index > 6 then
      lines[#lines + 1] = string.format("  ...and %d more", #patterns - 6)
      break
    end
    for _, piece in ipairs(wrapText("  " .. pattern, width)) do
      lines[#lines + 1] = piece
    end
  end
  return lines
end

return M
