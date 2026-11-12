-- tui: simple full-screen menus and prompts, for keyboard and touch/mouse.
-- Sized for pocket computers, but works on any screen.
--
--   local tui = require("tui")
--   local choice = tui.menu("Title", { { label = "One", value = 1 }, ... },
--                           { info = { "Text shown above the menu" } })
--   local text = tui.prompt("Title", { "Question" }, "default")
--   tui.message("Title", { "Something happened" })
--   if tui.confirm("Title", "Sure?") then ... end
--
-- Menus: up/down + Enter, or tap an item; Backspace goes back (returns nil).

local M = {}

local C

local function palette()
  if term.isColor() then
    C = {
      bg = colors.black, fg = colors.white, dim = colors.lightGray,
      headBg = colors.blue, headFg = colors.white,
      selBg = colors.lightBlue, selFg = colors.black,
      good = colors.lime, bad = colors.red, accent = colors.yellow,
    }
  else
    C = {
      bg = colors.black, fg = colors.white, dim = colors.lightGray,
      headBg = colors.white, headFg = colors.black,
      selBg = colors.white, selFg = colors.black,
      good = colors.white, bad = colors.white, accent = colors.white,
    }
  end
end

--- Named colors for item labels: "good", "bad", "accent", "dim".
function M.color(name)
  palette()
  return C[name]
end

--- Word-wrap text to a width. Returns a list of lines.
function M.wrap(text, width)
  local lines = {}
  for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      while #word > width do
        if line ~= "" then lines[#lines + 1] = line; line = "" end
        lines[#lines + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if line == "" then line = word
      elseif #line + 1 + #word <= width then line = line .. " " .. word
      else lines[#lines + 1] = line; line = word end
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- Clear the screen and draw the title bar. Returns width, height.
local function screen(title)
  palette()
  local w, h = term.getSize()
  term.setCursorBlink(false)
  term.setBackgroundColor(C.bg)
  term.clear()
  term.setCursorPos(1, 1)
  term.setBackgroundColor(C.headBg)
  term.setTextColor(C.headFg)
  term.clearLine()
  term.write((" " .. title):sub(1, w))
  term.setBackgroundColor(C.bg)
  term.setTextColor(C.fg)
  return w, h
end

-- Draw wrapped info lines from row y. Returns the next free row.
local function drawInfo(lines, y, w, color)
  for _, text in ipairs(lines or {}) do
    for _, l in ipairs(M.wrap(text, w - 2)) do
      term.setCursorPos(2, y)
      term.setTextColor(color or C.fg)
      term.write(l)
      y = y + 1
    end
  end
  term.setTextColor(C.fg)
  return y
end

local function hint(text)
  local w, h = term.getSize()
  term.setCursorPos(1, h)
  term.setTextColor(C.dim)
  term.write(text:sub(1, w))
  term.setTextColor(C.fg)
end

--- Show a menu. items: list of { label, value, color }. opts.info: lines of
-- text above the items; opts.selected: initially selected index.
-- Returns the chosen item's value, or nil if the user went back.
function M.menu(title, items, opts)
  opts = opts or {}
  local sel, scroll = math.min(opts.selected or 1, #items), 0
  while true do
    local w, h = screen(title)
    local top = drawInfo(opts.info, 2, w, C.dim)
    if opts.info and #opts.info > 0 then top = top + 1 end
    local rows = math.max(1, h - top)
    if sel - scroll > rows then scroll = sel - rows end
    if sel - scroll < 1 then scroll = sel - 1 end
    for i = 1, rows do
      local idx = i + scroll
      local item = items[idx]
      if not item then break end
      term.setCursorPos(1, top + i - 1)
      if idx == sel then
        term.setBackgroundColor(C.selBg)
        term.setTextColor(C.selFg)
        term.clearLine()
      else
        term.setTextColor(item.color or C.fg)
      end
      term.write((" " .. item.label):sub(1, w))
      term.setBackgroundColor(C.bg)
      term.setTextColor(C.fg)
    end
    hint("Tap/Enter pick, Bksp back")

    local ev, a, _, y = os.pullEvent()
    if ev == "key" then
      if a == keys.up then sel = sel > 1 and sel - 1 or #items
      elseif a == keys.down then sel = sel < #items and sel + 1 or 1
      elseif a == keys.enter or a == keys.numPadEnter then return items[sel].value
      elseif a == keys.backspace then return nil
      end
    elseif ev == "mouse_click" then
      local idx = y - top + 1 + scroll
      if y >= top and y < top + rows and items[idx] then return items[idx].value end
    elseif ev == "mouse_scroll" then
      sel = math.max(1, math.min(#items, sel + a))
    end
  end
end

--- Ask for a line of text. info: lines shown above the input. Returns the
-- text (default if left empty), or nil if left empty with no default.
-- opts.mask: character to show instead of the typed text (passwords).
function M.prompt(title, info, default, opts)
  opts = opts or {}
  local w, h = screen(title)
  local y = drawInfo(info, 2, w)
  hint("Enter to confirm")
  term.setCursorPos(2, y + 1)
  term.setTextColor(C.accent)
  term.write("> ")
  term.setTextColor(C.fg)
  local text = read(opts.mask, nil, nil, default)
  if text == "" then return default end
  return text
end

--- Show a message and wait for Enter or a tap.
function M.message(title, lines, color)
  local w = screen(title)
  drawInfo(type(lines) == "table" and lines or { lines }, 3, w, color and C[color] or nil)
  hint("Tap/Enter to continue")
  while true do
    local ev, a = os.pullEvent()
    if ev == "mouse_click" or (ev == "key" and (a == keys.enter or a == keys.numPadEnter or a == keys.backspace)) then
      return
    end
  end
end

--- Ask a yes/no question. Returns true for yes.
function M.confirm(title, question, yesLabel)
  return M.menu(title, {
    { label = yesLabel or "Yes", value = true },
    { label = "No", value = false },
  }, { info = type(question) == "table" and question or { question }, selected = 2 }) == true
end

--- Show a "working" screen (returns immediately).
function M.busy(title, text)
  local w = screen(title)
  drawInfo({ text or "Working..." }, 3, w, C.dim)
end

return M
