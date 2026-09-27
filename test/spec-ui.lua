-- The interface: layout, boundaries, the scrollback, and the keys.
--
-- What is worth testing here is not that the screen has a title bar. It is that
-- nothing escapes the screen, that a long line comes back whole, that the
-- conversation can be scrolled through, and that a reply appears while it is still
-- arriving — the four things the plain screen got wrong, and the four a mock with a
-- cell grid and an event queue can actually say something about.
--
-- A screen that records what it was handed as one long string cannot answer any of
-- them: a layout is geometry, and a wrapping bug is about what a terminal did with
-- a row that was too long. So every assertion below reads the grid, row by row, or
-- counts the cells that were dropped.

return function(t, mock)
  t.suite("ui")

  if not t.ccgui then
    print("  (ui) skipped: CC-GUI is not installed, so there is no interface to test")
    return
  end

  local util = require("util")

  --- A UI on a terminal of `size`, defaulting to a computer's.
  --
  -- The mock's transient state is put back each time, because the event queue is
  -- what the keys below are read from: a test that left events behind would have the
  -- next one start mid-typing.
  local function screen(size, inputs)
    mock.reset()
    return mock.console(size or { 51, 19 }, inputs)
  end

  --- A UI, or a failed assertion.
  local function open(size, options)
    local raw = screen(size)
    local ui, err = require("ui").open(raw, options)
    if not ui then
      t.ok(false, "the interface would not open: " .. tostring(err))
      return nil
    end
    return ui, raw
  end

  --- The whole screen as one string, rows joined.
  --
  -- `frame` picks a frame that has ended rather than what is on the screen now: 1
  -- is the first, -1 the last. A dialog is drawn, read, and taken off again inside
  -- one call, so the live grid is the one thing about it that says nothing -- and so
  -- is the field after a submission, which is cleared on the way out.
  local function shown(raw, frame)
    return mock.gridText(raw, frame)
  end

  --- Every cell the screen was handed outside its own bounds.
  local function escaped(raw)
    return raw.outside
  end

  -- Opening
  --
  -- The reasons it can decline are worth pinning down, because they are the three
  -- ways a person in front of a computer finds out why their screen looks wrong,
  -- and each wants a different answer from them.

  do
    local ui = require("ui")
    local result, reason = ui.open(nil)
    t.eq(result, nil, "there is no interface without a terminal")
    t.contains(tostring(reason), "terminal", "and the reason says so")
  end

  do
    local ui = require("ui")
    local result, reason = ui.open(mock.console({ 12, 5 }))
    t.eq(result, nil, "a terminal too small for a title bar and a hint line is refused")
    t.contains(tostring(reason), "too small", "and the reason says which")
  end

  do
    -- The smallest terminal that is still given a GUI, drawn on, and read back.
    local ui, raw = open({ require("ui").MIN_WIDTH, require("ui").MIN_HEIGHT })
    t.ok(ui ~= nil, "the smallest usable terminal is given an interface")
    if ui then
      ui:write("hello\n")
      ui:draw()
      t.contains(shown(raw), "hello", "and it draws the conversation")
      t.eq(escaped(raw), 0, "with nothing outside it")
      t.eq(#ui.buttons, 0, "and no buttons, which would not fit beside the hint")
    end
  end

  do
    local ui = require("ui")
    t.eq(ui.isUI(screen()), false, "a plain screen is not an interface")
    t.eq(ui.isUI(open()), true, "and an interface knows that it is one")
  end

  -- The layout
  --
  -- A computer's terminal is 51x19, and three rows of that are chrome, so the
  -- conversation gets sixteen. Every one of these is a claim about a specific row.

  do
    local ui, raw = open()
    ui:write("opencode for ComputerCraft\n")
    ui:write("a question\n")
    ui:draw()
    local grid = shown(raw)

    t.eq(mock.row(raw, 1):sub(1, 8), "opencode", "row 1 is the title bar")
    t.contains(grid, "opencode for ComputerCraft", "the conversation is on screen")
    t.contains(mock.row(raw, raw.size[2]), ">", "the last row is the input field")
    t.contains(mock.row(raw, raw.size[2] - 1), "enter sends", "the one above it is the hint line")
    t.eq(mock.row(raw, 2):sub(1, 26), "opencode for ComputerCraft", "and row 2 is the top of the conversation")
  end

  do
    local ui, raw = open()
    ui:setSubtitle("opencode/gpt-5-nano  build")
    ui:setStatus("thinking", colors.lightGray)
    ui:draw()

    local header = mock.row(raw, 1)
    t.contains(header, "opencode/gpt-5-nano", "the title bar names the model")
    t.contains(header, "build", "and the agent")
    t.contains(header, "thinking", "and what it is doing")
    t.eq(mock.fg(raw, raw.size[1], 1), colors.lightGray, "the status is drawn in the colour it was given")
  end

  do
    -- A model id is longer than the row. The title yields and the subtitle is cut,
    -- because what the program is talking to is the half that is worth having when
    -- the conversation has scrolled: the name is in the banner and in the shell's
    -- history. The important part is that neither overflows.
    local ui, raw = open()
    ui:setSubtitle(string.rep("x", 80))
    ui:draw()
    local header = mock.row(raw, 1)
    t.notContains(header, "opencode", "the program gives up its name rather than the model")
    t.contains(header, string.rep("x", 20), "and the subtitle is cut to the room left")
    t.eq(escaped(raw), 0, "with nothing drawn past the right edge")
  end

  do
    local ui, raw = open()
    ui:draw()
    local hint = raw.size[2] - 1
    local exit = ui.buttons[4]
    t.contains(mock.row(raw, hint), "Help", "the buttons are on the hint line")
    t.contains(mock.row(raw, hint), "Exit", "all four of them")
    t.eq(mock.bg(raw, 1, 1), colors.gray, "the title bar is mid grey")
    t.eq(mock.bg(raw, 1, hint), colors.darkGray, "and the hint bar is the darker one, for contrast")
    -- Inside the last button, on its label: a column of padding has a background but
    -- no character drawn on it, so reading the colour there reads the filler.
    t.eq(mock.bg(raw, exit.x + 1, hint), colors.lightGray, "and the buttons on it are lighter, so they read as pressable")
    t.eq(mock.fg(raw, exit.x + 1, hint), colors.black, "with the label in the colour that reads on them")
  end

  -- Boundaries
  --
  -- The reason `blit` and `fill` exist. CC-GUI writes whatever text it is handed
  -- wherever it is handed it, and on a real terminal a write past the right edge
  -- carries onto the next row and shreds whatever was there. So the assertion is
  -- about cells the screen never received, not about strings.

  do
    local ui, raw = open()
    ui:write(string.rep("a long line that has to wrap because it is longer than the screen ", 4) .. "\n")
    ui:setStatus(string.rep("s", 200), colors.yellow)
    ui:setSubtitle(string.rep("b", 200))
    ui:setInputText(string.rep("i", 200))
    ui:draw()

    t.eq(escaped(raw), 0, "a long line, a long status and a long field draw nothing outside the screen")
    local widest = 0
    for _, row in ipairs(raw.drawn) do
      widest = math.max(widest, #row)
    end
    t.ok(widest <= raw.size[1], "and no single write was longer than the screen")
  end

  do
    -- The same, at every size a computer can be. A layout that fits at 51x19 and
    -- overflows at 40x14 is a layout that only works on the machine it was written
    -- on.
    local sizes = { { 24, 8 }, { 31, 11 }, { 40, 14 }, { 51, 19 }, { 60, 24 }, { 80, 30 } }
    for _, size in ipairs(sizes) do
      local ui, raw = open(size)
      ui:setSubtitle("opencode/space-bunny-free  build")
      ui:setStatus("writing", colors.lightGray)
      ui:setInputText("what is the answer to this, and to that, and to the other thing?")
      for index = 1, 20 do
        ui:write(("  * read /very/long/path/number/%d/that/keeps/going"):format(index) .. "\n")
      end
      ui:write("An answer long enough to wrap several times over, at " .. size[1] .. " columns.\n")
      ui:draw()
      t.eq(escaped(raw), 0, size[1] .. "x" .. size[2] .. ": nothing escaped the screen")
    end
  end

  do
    -- A model name is whatever the user put in the config, and the status is
    -- whatever the tool's name is. Both are arbitrary strings, and the one place
    -- that must hold against them is a box narrower than they are.
    local ui, raw = open({ 30, 12 })
    ui:setTitle(string.rep("T", 200))
    ui:setSubtitle(string.rep("S", 200))
    ui:setStatus(string.rep("E", 200), colors.red)
    ui:draw()
    t.eq(escaped(raw), 0, "a title, a subtitle and a status all longer than the screen")
  end

  -- Wrapping
  --
  -- The complaint the interface exists for: a reply wider than the screen lost
  -- everything past the right edge. Here the whole of it has to be readable, and
  -- read as one sentence rather than as several.

  do
    local ui, raw = open()
    local sentence = "These are the files: /rom/modules/nested_a/one.lua /rom/modules/nested_a/two.lua"
    ui:write(sentence .. "\n")
    ui:draw()

    local grid = shown(raw)
    for word in sentence:gmatch("%S+") do
      t.contains(grid, word, "every word of a long line is on the screen: " .. word)
    end
    t.eq(escaped(raw), 0, "and nothing was drawn outside it")
  end

  do
    -- A tool log line is indented, and a wrapped one whose continuation lands back
    -- in column one reads as though the model had said four separate things.
    local ui, raw = open()
    ui:write("  * read /very/long/path/that/keeps/going/and/going/until/it/must/wrap\n")
    ui:draw()
    local grid = shown(raw)
    local rows = {}
    for line in (grid .. "\n"):gmatch("([^\n]*)\n") do
      rows[#rows + 1] = line
    end
    local continuation
    for index = 3, 6 do
      if (rows[index] or ""):find("until", 1, true) then
        continuation = rows[index]
      end
    end
    t.ok(continuation ~= nil, "the long tool line wrapped")
    if continuation then
      t.ok(continuation:match("^    ") ~= nil, "and the continuation hangs under the tool line's own indent")
    end
  end

  do
    -- A line with no spaces in it at all is the case wrapping has to get right
    -- without anywhere to break.
    local ui, raw = open()
    ui:write(string.rep("x", 300) .. "\n")
    ui:draw()
    t.eq(escaped(raw), 0, "a 300-character word does not escape the screen")
    t.contains(shown(raw), "x", "and is on it")
  end

  do
    -- Prose is not always ASCII, and a cut in the middle of a multi-byte character
    -- leaves the replacement glyph on screen at the end of every wrapped line.
    local ui, raw = open()
    local accented = ("caf\195\169 na\195\175ve r\195\188sum\195\169 "):rep(4)
    ui:write(accented .. "\n")
    ui:draw()
    t.eq(escaped(raw), 0, "accented text wraps inside the screen")
    for _, row in ipairs(ui.vlines) do
      t.ok(row.text:match("[\128\191\192\223]") == nil, "no line ends in half a character")
    end
  end

  -- The scrollback
  --
  -- A conversation that scrolls off the top of a 19-row screen and is gone is the
  -- other half of the reason for this. The buffer keeps it, the viewport windows
  -- it, and what fell off the end is said out loud rather than dropped quietly.

  do
    local ui, raw = assert(open())
    for index = 1, 100 do
      ui:write("line " .. index .. "\n")
    end
    t.eq(#ui.lines, 100, "a hundred lines are kept")

    ui:draw()
    t.contains(mock.gridText(raw), "line 100", "and the newest is the one in view")
    t.notContains(mock.gridText(raw), "line 1\n", "while the oldest has scrolled off")
  end

  do
    local ui, raw = assert(open())
    for index = 1, 100 do
      ui:write("line " .. index .. "\n")
    end
    ui:scrollToStart()
    ui:draw()
    local grid = mock.gridText(raw)
    t.contains(grid, "line 1", "scrolled to the start, the oldest is in view")
    t.notContains(grid, "line 100", "and the newest is not")
  end

  do
    local ui, raw = assert(open())
    for index = 1, 100 do
      ui:write("line " .. index .. "\n")
    end
    ui:scrollToStart()
    ui:scrollBy(1)
    ui:draw()
    t.contains(mock.row(raw, 2), "line 2", "one row down")
    ui:scrollBy(-1)
    ui:draw()
    t.contains(mock.row(raw, 2), "line 1", "and one row back")
    ui:scrollBy(-50)
    ui:draw()
    t.contains(mock.row(raw, 2), "line 1", "and past the start is the start")
  end

  do
    -- The cap. ComputerCraft's memory is the scarce resource, and a buffer that
    -- grows for the life of a long session is the one thing here that could bring
    -- the program down.
    local ui, raw = assert(open(nil, { maxLines = 20 }))
    for index = 1, 200 do
      ui:write("line " .. index .. "\n")
    end
    t.ok(#ui.lines <= 20 + 100, "the buffer is trimmed back to the cap")
    t.ok(#ui.lines >= 20, "and to the cap, not below it")
    t.eq(ui.lines[#ui.lines].text, "line 200", "the newest line is the one that is kept")
    t.eq(ui.dropped, 200 - #ui.lines, "and what went is counted")
  end

  do
    local ui, raw = assert(open(nil, { maxLines = 20 }))
    for index = 1, 200 do
      ui:write("line " .. index .. "\n")
    end
    ui:draw()
    t.contains(mock.gridText(raw), "earlier lines dropped", "and the drop is said on screen")
    t.contains(mock.gridText(raw), ui.dropped .. " earlier", "with the number of them")
  end

  do
    -- A short conversation sits at the top of its space rather than being
    -- stretched down it, so the newest line is not floating in the middle of a
    -- screen with the answer on the row above the hint line.
    local ui, raw = open()
    ui:write("just the one line\n")
    ui:draw()
    t.contains(mock.row(raw, 2), "just the one line", "a short conversation is at the top of the viewport")
  end

  -- Streaming
  --
  -- A reply arrives in pieces, and the last piece with no newline after it is the
  -- live end of the conversation: drawn as it is written, and committed as one line
  -- when the turn ends.

  do
    local ui, raw = open()
    ui:write("The answer ")
    ui:draw()
    t.contains(mock.gridText(raw), "The answer", "what has arrived is on screen")
    ui:write("is forty-two.")
    ui:draw()
    t.contains(mock.gridText(raw), "is forty-two.", "and so is the rest of it")
    t.eq(#ui.lines, 0, "neither piece has been committed as a line yet")
  end

  do
    local ui, raw = open()
    ui:write("The answer is forty-two.")
    ui:draw()
    ui:write("\n")
    t.eq(#ui.lines, 1, "the newline commits it")
    t.eq(ui.lines[1].text, "The answer is forty-two.", "as one line, not two")
    t.eq(ui.pending.text, "", "and the next line starts empty")
  end

  do
    -- The reply has to appear while the turn is still running, which is the whole
    -- reason `write` repaints. A reply that only shows up when the turn ends is a
    -- reply that looks like the program hung.
    local ui, raw = open()
    mock.clockStep = 1 -- a machine fast enough that nothing is throttled
    ui:draw()
    local before = raw.cleared
    ui:write("a piece of the answer")
    t.ok(raw.cleared > before, "a write repaints the screen")
  end

  do
    -- And the throttle, which is what stops a few hundred pieces from costing a
    -- few hundred repaints. The clock here does not move, which is the worst case:
    -- every piece arrives inside the interval, and so none of them repaints. The
    -- turn still ends in a repaint, because committing a line draws.
    local ui, raw = open()
    mock.clockStep = 0
    ui:draw()
    local before = raw.cleared
    for _ = 1, 20 do
      ui:write("a piece of the answer")
    end
    t.eq(raw.cleared, before, "twenty writes on a still clock are no repaint")
    mock.clockStep = 1
    mock.clock = mock.clock + 1
    ui:write("and then the clock moves")
    t.eq(raw.cleared, before + 1, "and the next write repaints again")
  end

  do
    -- A colour change is a line break, because that is the only way a line-based
    -- transcript can carry a colour: the tool log is grey and the answer is white,
    -- and the two of them are two different lines. Which is also the only shape the
    -- renderer ever writes in -- it sets the colour, writes the whole line, and puts
    -- white back -- so a change lands between two lines and never inside one.
    local ui = assert(open())
    ui:write("It has two lines.\n")
    ui.setTextColor(colors.lightGray)
    ui:write("  * read /notes.txt\n")
    t.eq(#ui.lines, 2, "the colour change ended the first line")
    t.eq(ui.lines[1].colour, colors.white, "the answer is in the colour it was written in")
    t.eq(ui.lines[2].colour, colors.lightGray, "and the tool log in the colour it was written in")
  end

  -- The input field
  --
  -- CC-GUI's field owns the text, the caret and the scroll window; this only says
  -- how wide the window is and where it goes.
  --
  -- Nearly every one of these ends with enter, and reads what came back rather than
  -- what is in the field. `readLine` clears the field on the way out -- that is the
  -- next prompt's business, not the last one's -- so a test that typed two
  -- characters and looked at the field afterwards would be asserting on the
  -- clearing, and pass or fail with nothing to do with the typing.

  do
    local ui, raw = open()
    mock.queue({ "char", "h" }, { "char", "i" }, { "key", 28 })
    t.eq(ui:readLine(), "hi", "what was typed is the answer")
    t.contains(mock.row(raw, raw.size[2], -1), "hi", "and it was drawn in the field while it was being typed")
    t.eq(mock.row(raw, raw.size[2]), "> " .. string.rep(" ", raw.size[1] - 2), "and the field is empty on the next prompt")
  end

  do
    -- The field is a window onto the text, not the whole of it. A line longer than
    -- the field has to scroll rather than run off the right edge.
    local ui, raw = open()
    local long = string.rep("z", 200)
    mock.queue({ "char", long }, { "key", 28 })
    ui:readLine()
    t.eq(#ui.lines, 0, "the long line is the answer, not a command")
    t.eq(escaped(raw), 0, "and it was drawn without escaping")
    t.ok(#mock.row(raw, raw.size[2]) <= raw.size[1], "the field row is the screen's width")
  end

  do
    local ui, raw = open()
    for index = 1, 3 do
      mock.queue({ "char", tostring(index) })
    end
    mock.queue({ "key", 28 })
    ui:readLine()
    t.eq(mock.row(raw, raw.size[2], -1):sub(3, 5), "123", "the field starts after the prompt marker")
  end

  do
    local ui, raw = open()
    ui:setInputText("abcdef")
    ui:draw()
    t.contains(mock.row(raw, raw.size[2]), "abcdef", "text set from outside is drawn")
    t.eq(mock.bg(raw, 3, raw.size[2]), colors.white, "the caret is a block on the first character")
    t.eq(mock.fg(raw, 3, raw.size[2]), colors.black, "in the text's own colour, so the character under it reads")
    t.eq(mock.bg(raw, 4, raw.size[2]), colors.black, "and the character after it is not part of the block")
  end

  -- History
  --
  -- `read` is not used here, so CraftOS's own history is not available either. This
  -- is the part of it worth having: what this session was asked.

  -- Each of these types and submits on its own `readLine`, because a submission is
  -- what puts a line in the history, and the field is cleared on the way out. Three
  -- submissions in one queue is one line of history and two characters typed.

  --- A UI with `count` one-character lines in its history already, oldest first.
  local function asked(count)
    local ui = assert(open())
    for index = 1, count do
      mock.queue({ "char", string.char(96 + index) }, { "key", 28 })
      ui:readLine()
    end
    return ui
  end

  do
    local ui = asked(3)
    mock.queue({ "key", 208 }, { "key", 28 })
    t.eq(ui:readLine(), "c", "up brings back the last thing asked")
  end

  do
    local ui = asked(3)
    mock.queue({ "key", 208 }, { "key", 208 }, { "key", 28 })
    t.eq(ui:readLine(), "b", "and the one before it")
  end

  do
    local ui = asked(3)
    mock.queue({ "key", 208 }, { "key", 208 }, { "key", 208 }, { "key", 208 }, { "key", 28 })
    t.eq(ui:readLine(), "a", "and the oldest of them, with one more press staying put")
  end

  do
    local ui = asked(2)
    -- Whatever is half-typed when the operator reaches for history is stashed, so
    -- walking to the oldest entry and back again does not lose it.
    mock.queue({ "char", "w" }, { "key", 208 }, { "key", 208 }, { "key", 209 }, { "key", 209 }, { "key", 28 })
    t.eq(ui:readLine(), "w", "and the line being typed is put back")
  end

  do
    local ui = asked(2)
    -- Down at the line being typed is the end of the walk, not a step back into the
    -- history. Treating it as another step makes the walk a ring rather than a walk:
    -- down past the newest entry puts the typed line back, and down again throws it
    -- away and goes into the history a second time.
    mock.queue({ "char", "w" }, { "key", 208 }, { "key", 209 }, { "key", 209 }, { "key", 28 })
    t.eq(ui:readLine(), "w", "down past the newest entry stops at the line being typed")
  end

  do
    local ui = assert(open(nil, { history = 2 }))
    for index = 1, 3 do
      mock.queue({ "char", string.char(96 + index) }, { "key", 28 })
      ui:readLine()
    end
    t.eq(#ui.history, 2, "the history is capped")
    t.eq(ui.history[1], "c", "keeping the newest")
  end

  do
    local ui = assert(open())
    mock.queue({ "char", "a" }, { "key", 28 })
    ui:readLine()
    mock.queue({ "char", "a" }, { "key", 28 })
    ui:readLine()
    t.eq(#ui.history, 1, "asking the same thing twice is one entry")
  end

  -- Keys
  --
  -- The keys this screen has an opinion about are answered here and everything else
  -- goes to CC-GUI, which owns the text in the field.
  --
  -- The editing keys arrive as `key_up`, not `key`, because that is what CC-GUI
  -- listens for: it ignores the press and does its work on the release, so a `key`
  -- event for backspace is a keypress this screen has never heard of. That is worth
  -- a test of its own, since every other one of these would pass just as well if the
  -- text were simply never edited.

  do
    local ui, raw = open()
    mock.queue({ "char", "a" }, { "char", "b" }, { "key_up", 14 }, { "key", 28 })
    t.eq(ui:readLine(), "a", "backspace is taken off the field, on the release")
  end

  do
    local ui, raw = open()
    mock.queue({ "char", "x" }, { "key_up", 14 }, { "key", 28 })
    t.eq(ui:readLine(), "", "and a backspace with nothing to delete submits nothing")
  end

  do
    local ui, raw = open()
    mock.queue({ "char", "a" }, { "key_up", 210 }, { "key_up", 210 }, { "key_up", 14 }, { "key", 28 })
    t.eq(ui:readLine(), "a", "left, left, backspace, and what is left is the first character")
  end

  do
    local ui, raw = open()
    mock.queue({ "char", "a" }, { "key_up", 210 }, { "key_up", 211 }, { "char", "b" }, { "key", 28 })
    t.eq(ui:readLine(), "ab", "left, right, and a character lands at the caret")
  end

  do
    -- The keys this screen answers itself are answered on the press and not on the
    -- release, or holding one of them does the thing twice.
    local ui, raw = open()
    mock.queue({ "char", "a" }, { "key", 28 }, { "char", "b" }, { "key", 28 }, { "char", "c" }, { "key", 28 })
    ui:readLine()
    mock.queue({ "key", 208 }, { "key_up", 208 }, { "key", 209 }, { "key_up", 209 }, { "key", 28 })
    t.eq(ui:readLine(), "b", "a press and its release are one step through the history, not two")
  end

  do
    local ui, raw = open()
    for index = 1, 60 do
      ui:write("line " .. index .. "\n")
    end
    ui:draw()
    -- Read before the scroll rather than after: a viewport pinned to the newest row
    -- shows its last screenful, so the first row is the newest sixteen lines less
    -- one, and that is the number page up has to be measured from.
    local atBottom = tonumber(mock.row(raw, 2):match("line (%d+)"))
    t.ok(atBottom == 45, "a conversation longer than the screen is pinned to its last screenful")
    t.contains(mock.row(raw, 17), "line 60", "with the newest line at the bottom of it")

    mock.queue({ "key", 278 }, { "key", 28 })
    t.eq(ui:readLine(), "", "page up scrolls back, and the empty field submits nothing")
    t.eq(tonumber(mock.row(raw, 2):match("line (%d+)")), atBottom - 15, "by one screenful less the row they share")

    mock.queue({ "key", 278 }, { "key", 278 }, { "key", 278 }, { "key", 28 })
    ui:readLine()
    t.contains(mock.row(raw, 2), "line 1", "page up eventually reaches the start of the conversation")
    t.eq(ui.follow, false, "and does not pin itself back to the newest row")

    mock.queue({ "key", 279 }, { "key", 279 }, { "key", 279 }, { "key", 28 })
    ui:readLine()
    t.eq(tonumber(mock.row(raw, 2):match("line (%d+)")), atBottom, "and page down comes back to the end")
    t.eq(ui.follow, true, "and pins itself to the newest row again")
  end

  do
    local ui, raw = open()
    for index = 1, 60 do
      ui:write("line " .. index .. "\n")
    end
    mock.queue({ "key", 278 }, { "key", 28 })
    ui:readLine()
    t.eq(ui.follow, false, "page up has unpinned the conversation")
    mock.queue({ "key", 275 }, { "key", 28 })
    ui:readLine()
    t.eq(ui.follow, true, "end follows the conversation again")
    t.contains(mock.row(raw, 17), "line 60", "with the newest line back in view")
  end

  do
    -- A click in the gap between two buttons must not press the one to its left.
    -- CC-GUI's hit test is a column wider than the button it drew, and that column
    -- is the gap.
    local ui, raw = open()
    local buttons = ui.buttons
    t.ok(#buttons >= 2, "there are buttons to click")
    if #buttons >= 2 then
      local first, second = buttons[1], buttons[2]
      local gap = first.x + first.w
      t.eq(ui:hitButton(gap, first.y), false, "the column between two buttons hits nothing")
      t.eq(ui:hitButton(first.x, first.y), true, "and the button itself does")
      t.eq(ui:hitButton(first.x, first.y + 1), false, "a row below the hint line hits nothing")
    end
  end

  do
    local ui = assert(open())
    local help = ui.buttons[3]
    mock.queue({ "mouse_click", 1, help.x + 1, help.y })
    local text = ui:readLine()
    t.eq(text, "/help", "clicking the button answers with the command it stands for")
  end

  -- The permission dialog
  --
  -- The question used to be written to a screen and the answer typed at the
  -- terminal, which on a computer with a monitor is a question nobody read. The
  -- dialog is what puts it in front of the operator.

  do
    local ui, raw = open()
    mock.queue({ "key", 28 })
    local reply = ui:ask({
      permission = "read",
      patterns = { mock.root .. "/notes.txt" },
      title = "read a file",
    })
    t.eq(reply, "", "enter with nothing in the field answers the empty line, which is a refusal")

    -- The frame before the last, which is the one the dialog was drawn in: by now it
    -- has been taken off again, and the live grid says nothing about whether it ever
    -- appeared. Looking at the wrong frame here is how a dialog that was never
    -- drawn passes.
    local grid = shown(raw, -1)
    t.ok(#raw.frames >= 2, "which there is, because the dialog drew before it was dismissed")
    t.contains(grid, "Permission: read", "the dialog names the permission")
    t.contains(grid, "/notes.txt", "and the pattern being asked about")
    t.contains(grid, "read a file", "and what the tool wanted to do")
    t.notContains(shown(raw), "Permission:", "and it is off the screen once answered")
    t.eq(escaped(raw), 0, "and draws nothing outside the screen")
  end

  do
    local ui, raw = open()
    mock.queue({ "char", "y" }, { "key", 28 })
    t.eq(ui:ask({ permission = "read", patterns = { "*" } }), "y", "typing y and pressing enter")
  end

  do
    -- A refusal can carry an explanation, which the agent feeds back to the model
    -- so it can correct course instead of retrying blindly. So the field under the
    -- dialog is not decoration.
    local said = "do not read that"
    local ui, raw = open()
    for index = 1, #said do
      mock.queue({ "char", said:sub(index, index) })
    end
    mock.queue({ "key", 28 })
    t.eq(ui:ask({ permission = "read", patterns = { "*" } }), said, "anything else is what was said")
  end

  do
    local ui, raw = open()
    mock.queue({ "char", "n" }, { "key", 28 })
    t.eq(ui:ask({ permission = "bash", patterns = { "*" } }), "n", "and n is a refusal")
  end

  do
    -- Six patterns is more than a dialog on nineteen rows can show, and a question
    -- whose patterns are off the bottom is a question answered unread.
    local ui, raw = open()
    local patterns = {}
    for index = 1, 12 do
      patterns[index] = "/very/long/path/number/" .. index .. "/file.txt"
    end
    mock.queue({ "key", 28 })
    ui:ask({ permission = "read", patterns = patterns, title = "read a file" })
    t.contains(shown(raw, -1), "more", "the question says that there is more below")
    t.eq(escaped(raw), 0, "and the dialog still draws inside the screen")
  end

  do
    local ui, raw = open()
    local patterns = {}
    for index = 1, 12 do
      patterns[index] = "/very/long/path/number/" .. index .. "/file.txt"
    end
    mock.queue({ "key", 208 }, { "key", 28 })
    ui:ask({ permission = "read", patterns = patterns })
    t.ok(ui.modal == nil, "up scrolls the question and enter answers it")
  end

  do
    local ui, raw = open()
    mock.queue({ "char", "a" }, { "key", 28 })
    t.eq(ui:ask({ permission = "write", patterns = { "*" } }), "a", "a is a refusal too, and means always")
  end

  do
    -- A terminal that has gone away is the end of input, which CraftOS's `read`
    -- reports by returning nil and the REPL exits on. A key loop that cannot hear
    -- it does not exit: it spins on a nil event forever, which is the difference
    -- between a program and a program that is stuck.
    local ui = assert(open())
    mock.close()
    t.eq(ui:readLine(), nil, "a closed terminal ends the read")
    mock.closed = false
  end

  do
    -- A nil answer, which is what a closed terminal looks like, is a refusal and
    -- not a crash: the safe direction to fail.
    local ui = assert(open())
    mock.close()
    t.eq(ui:ask({ permission = "read", patterns = { "*" } }), "", "an unattended question is the empty one")
    t.eq(ui.modal, nil, "and the dialog is taken off the screen")
    mock.closed = false
  end

  -- Clearing
  --
  -- `/new` is not in the hint buttons but the transcript has to be droppable, and
  -- the buttons on the hint line have to stop saying "/new" if it is not wired.

  do
    local ui, raw = open()
    ui:write("something that was said\n")
    ui:draw()
    ui:clearTranscript()
    ui:draw()
    t.notContains(shown(raw), "something that was said", "the conversation can be cleared")
    t.eq(#ui.lines, 0, "and the buffer is empty")
    t.eq(ui.dropped, 0, "with nothing counted as dropped, which is not a drop")
  end

  do
    -- A terminal resized while the program is running. Everything about the layout
    -- is recomputed on each redraw, and the wrapped transcript is the one stored
    -- wrapped, so it is the one that has to be told.
    local ui, raw = open()
    ui:write(string.rep("word ", 40) .. "\n")
    t.eq(#ui.vlines, 4, "wrapped to the width it had")
    raw.size = { 30, 19 }
    ui:draw()
    t.eq(escaped(raw), 0, "a narrower terminal draws inside itself")
    t.ok(#ui.vlines > 4, "and the transcript was re-wrapped for the new width")
  end

  do
    local utilTrim = util.trim
    t.eq(utilTrim("  x  "), "x", "the module the interface needs is the project's own")
  end
end
