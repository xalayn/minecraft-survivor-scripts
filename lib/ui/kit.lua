-- ui/kit: shared screen building blocks for the control app and its modules
-- (Basalt-based). Modules get this as `kit` in their ui.lua's open(kit).
--
-- Screens: kit.newScreen(title, onBack) clears the screen and draws the title
-- bar; then add elements with kit.addText / addList / addButton / addCard /
-- addForm ... Work that talks to the server must run in a background task:
-- button and list actions already do; otherwise wrap it in kit.task(fn).
-- kit.call("<module>.<method>", ...) calls controld from inside a task,
-- showing "Working..." and any error as a toast.

local basalt = require("basalt")
local rpc = require("rpc")

local kit = {}

kit.basalt = basalt
kit.root = basalt.getMainFrame()
kit.W, kit.H = term.getSize()
local root, W, H = kit.root, kit.W, kit.H

kit.PLAYER_SETTING = "control.player"
kit.TIMEOUT = 90 -- seconds; some requests (drawing far-away regions) take a while

-- Colors.
local C = {
  bg = colors.black, text = colors.white, muted = colors.lightGray, faint = colors.gray,
  head = colors.blue, headText = colors.white, headIcon = colors.yellow,
  status = colors.gray, statusText = colors.white,
  card = colors.gray, cardText = colors.white, cardLabel = colors.lightGray,
  field = colors.gray, fieldText = colors.white,
  primary = colors.lime, primaryText = colors.black,
  danger = colors.red, dangerText = colors.white,
  neutral = colors.lightGray, neutralText = colors.black,
  select = colors.lightBlue, selectText = colors.black,
  warn = colors.orange,
}
kit.C = C

-- Minecraft text colors -> the closest computer colors.
kit.MC_COLORS = {
  white = colors.white, gray = colors.lightGray, dark_gray = colors.gray, black = colors.black,
  red = colors.red, dark_red = colors.red, gold = colors.orange, yellow = colors.yellow,
  green = colors.lime, dark_green = colors.green, aqua = colors.lightBlue, dark_aqua = colors.cyan,
  blue = colors.blue, dark_blue = colors.blue, light_purple = colors.pink, dark_purple = colors.purple,
}

---------------------------------------------------------------------------
-- Helpers.

function kit.sortedKeys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

function kit.wrap(text, width)
  local lines = {}
  for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      if line == "" then line = word
      elseif #line + 1 + #word <= width then line = line .. " " .. word
      else lines[#lines + 1] = line; line = word end
    end
    lines[#lines + 1] = line
  end
  return lines
end

--- The player name set in the app's settings.
function kit.player()
  return settings.get(kit.PLAYER_SETTING) or settings.get("region.player")
end

function kit.dimName(dim)
  return (dim:gsub("^minecraft:", ""))
end

---------------------------------------------------------------------------
-- Screens and tasks.

-- The current screen. token changes whenever the screen does, so background
-- tasks can tell they belong to a screen that's gone.
local screen = { token = 0 }
kit.screen = screen

--- Whether the screen with this token is still shown.
function kit.isCurrent(token)
  return screen.token == token
end

--- Run fn(...) in the background; errors are shown as a toast.
function kit.task(fn, ...)
  local args = table.pack(...)
  basalt.schedule(function()
    local ok, err = pcall(fn, table.unpack(args, 1, args.n))
    if not ok and err ~= "Terminated" and screen.toast then
      screen.toast:error(tostring(err), 5)
    end
  end)
end

--- Call controld (inside a task). Shows "Working..." meanwhile. Returns the
-- result (true if there is none), or nil after showing the error.
function kit.call(method, ...)
  local toast = screen.toast
  if toast then toast:info("Working...", 0) end
  local ok, result = rpc.call(method, kit.TIMEOUT, ...)
  if toast then toast:hide() end
  if not ok then
    if screen.toast then screen.toast:error(tostring(result), 5) end
    return nil
  end
  if result == nil then return true end
  return result
end

--- Call controld without any UI; returns ok, result.
function kit.callQuiet(method, timeout, ...)
  return rpc.call(method, timeout or 5, ...)
end

--- Toast helpers: kit.toast("text", "success"|"error"|"info"|"warning").
function kit.toast(text, kind, seconds)
  if screen.toast then screen.toast:show(text, kind or "info", seconds or 3) end
end

--- Clear the screen and draw the title bar: a < button if onBack, an x
-- (quit) button if quit. flash: optional { text, kind, seconds } toast to show.
-- Returns the screen's token (see kit.isCurrent).
function kit.newScreen(title, onBack, flash, quit)
  screen.token = screen.token + 1
  local children = root:getChildren()
  for i = #children, 1, -1 do
    local child = children[i]
    if child.destroy then child:destroy() end
    if children[i] == child then root:removeChild(child) end
  end
  root.background = C.bg

  root:addLabel({ x = 1, y = 1, width = W, height = 1, text = "", background = C.head })
  local x = 2
  if onBack then
    root:addButton({ x = 1, y = 1, width = 3, height = 1, text = "<",
      background = C.head, foreground = C.headIcon }):onClick(function() onBack() end)
    x = 4
  end
  root:addLabel({ x = x, y = 1, width = W - x - 2, height = 1, text = title,
    background = C.head, foreground = C.headText })
  if quit then
    root:addButton({ x = W - 2, y = 1, width = 3, height = 1, text = "x",
      background = C.head, foreground = C.headIcon }):onClick(function() basalt.stop() end)
  end

  screen.back = onBack
  screen.dialog = root:addDialog()
  screen.toast = root:addToast()
  if flash then screen.toast:show(flash[1], flash[2] or "success", flash[3] or (flash[2] == "warning" and 6 or 3)) end
  return screen.token
end

--- A back action that opens fn(...) in a task.
function kit.backTo(fn, ...)
  local args = table.pack(...)
  return function() kit.task(fn, table.unpack(args, 1, args.n)) end
end

---------------------------------------------------------------------------
-- Elements.

--- Wrapped text from row y; returns the label and the next free row.
function kit.addText(y, text, color, x, width)
  x, width = x or 2, width or (W - 2)
  local lines = kit.wrap(text, width)
  local label = root:addLabel({ x = x, y = y, width = width, height = #lines,
    text = table.concat(lines, "\n"), foreground = color or C.muted })
  return label, y + #lines
end

--- A button; kind is "primary", "danger" or "neutral". onClick runs in a task.
function kit.addButton(parent, x, y, width, text, kind, onClick, height)
  kind = kind or "neutral"
  local b = parent:addButton({ x = x, y = y, width = width, height = height or 1, text = text,
    background = C[kind], foreground = C[kind .. "Text"] })
  b:onClick(function() kit.task(onClick) end)
  return b
end

--- Two buttons side by side on the bottom row (right one optional).
function kit.addBottomButtons(left, right)
  if not right then
    return kit.addButton(root, 2, H, W - 2, left[1], left[2], left[3])
  end
  local bw = math.floor((W - 3) / 2)
  kit.addButton(root, 2, H, bw, left[1], left[2], left[3])
  kit.addButton(root, W - bw, H, bw, right[1], right[2], right[3])
end

--- A scrollable list from row y to row bottom (default: the last row).
function kit.addList(y, bottom, emptyText)
  return root:addList({ x = 1, y = y, width = W, height = (bottom or H) - y + 1,
    background = C.bg, foreground = C.text,
    selectionBackground = C.select, selectionForeground = C.selectText,
    emptyText = emptyText or "", emptyTextColor = C.faint })
end

--- Add a list item whose action runs in a background task.
function kit.addItem(list, text, action, fg)
  list:addItem({ text = " " .. text, fg = fg, callback = function()
    if action then kit.task(action) end
  end })
end

--- A gray card with "label  value" rows ({ label, value, valueColor }).
-- Returns the next free row.
function kit.addCard(y, rows)
  local card = root:addFrame({ x = 2, y = y, width = W - 2, height = #rows + 2, background = C.card })
  for i, row in ipairs(rows) do
    card:addLabel({ x = 2, y = i + 1, text = row[1], foreground = C.cardLabel })
    card:addLabel({ x = 8, y = i + 1, text = row[2], foreground = row[3] or C.cardText })
  end
  return y + #rows + 2
end

--- Text prompt dialog. callback(text) runs in a task if confirmed.
function kit.prompt(title, message, default, callback)
  screen.dialog:prompt(title, message, default or "", function(text)
    if text ~= nil then kit.task(callback, text) end
  end)
  -- Dialog:prompt doesn't expose its input; find it to put the cursor after
  -- the prefilled text (it starts at the beginning).
  local function find(el)
    if el.__name == "Input" then return el end
    for _, c in ipairs(el.getChildren and el:getChildren() or {}) do
      local found = find(c)
      if found then return found end
    end
  end
  local input = find(screen.dialog)
  if input then input:_moveCursor(#input.text + 1) end
end

--- Yes/no dialog; callback runs in a task on yes.
function kit.confirm(title, message, callback)
  screen.dialog:confirm(title, message, function(yes)
    if yes then kit.task(callback) end
  end)
end

--- A field label that shows a hint when tapped.
function kit.addHintLabel(parent, x, y, text, hint, color)
  local label = parent:addLabel({ x = x, y = y, text = text, foreground = color or C.text })
  label:onClick(function() screen.toast:info(hint, 6) end)
  return label
end

---------------------------------------------------------------------------
-- Settings forms, built from option definitions (see lib/args.lua).

function kit.optionLabel(o)
  local s = o.name:gsub("-", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
end

function kit.optionHint(o)
  local hint = o.hint or o.desc or kit.optionLabel(o)
  if type(o.default) == "table" then
    hint = hint .. " Default: " .. (#o.default > 0 and table.concat(o.default, ", ") or "none") .. "."
  elseif o.default ~= nil and (o.type or "boolean") ~= "boolean" then
    hint = hint .. " Default: " .. tostring(o.default) .. "."
  end
  return hint
end

-- A button cycling through o.choices; Minecraft color choices are shown in
-- their color.
local function choiceButton(form, x, y, width, o, value)
  local index = 1
  for i, c in ipairs(o.choices) do if c == value then index = i end end
  local b = form:addButton({ x = x, y = y, width = width, height = 1 })
  local function show()
    local v = o.choices[index]
    local color = kit.MC_COLORS[v]
    b.text = v:sub(1, width)
    b.background = color or C.field
    b.foreground = (color == colors.black or color == colors.blue or color == colors.purple
      or color == colors.gray or color == colors.green or color == colors.red
      or color == colors.cyan or not color) and colors.white or colors.black
  end
  b:onClick(function()
    index = index % #o.choices + 1
    show()
  end)
  show()
  return { get = function() return o.choices[index] end }
end

---------------------------------------------------------------------------
-- Overlays: full-screen panels on top of the current screen (so its
-- unsaved state survives), e.g. editors opened from a form. Back closes the
-- top one.

local overlays = {}

--- Open an overlay with a title bar; returns its frame. Close it with
-- kit.closeOverlay(); onClose (optional) runs when it's closed.
function kit.openOverlay(title, onClose)
  local frame = root:addFrame({ x = 1, y = 1, width = W, height = H, background = C.bg,
    z = 500 + #overlays })
  frame:addLabel({ x = 1, y = 1, width = W, height = 1, text = "", background = C.head })
  frame:addButton({ x = 1, y = 1, width = 3, height = 1, text = "<",
    background = C.head, foreground = C.headIcon }):onClick(function() kit.closeOverlay() end)
  frame:addLabel({ x = 4, y = 1, width = W - 3, height = 1, text = title,
    background = C.head, foreground = C.headText })
  overlays[#overlays + 1] = { frame = frame, onClose = onClose, token = screen.token }
  return frame
end

--- Close the top overlay (if any). Returns true if one was closed.
function kit.closeOverlay()
  local top = table.remove(overlays)
  if not top then return false end
  if top.frame.parent then root:removeChild(top.frame) end
  if top.onClose then top.onClose() end
  return true
end

--- Whether an overlay of the current screen is open.
function kit.overlayOpen()
  while #overlays > 0 and overlays[#overlays].token ~= screen.token do table.remove(overlays) end
  return #overlays > 0
end

---------------------------------------------------------------------------
-- Player rule editor (see lib/predicate.lua): match all/any of a list of
-- conditions, each optionally negated. onDone(rule) gets the result.

local predicate = require("predicate")

local function ruleItems(rule)
  -- The editor handles: everyone, one condition (maybe negated), or all/any of
  -- such conditions. Returns mode, conditions; or nil if it's more complex.
  if rule == nil then return "all", {} end
  local function simple(r) return r.type or (r["not"] and r["not"].type) end
  if simple(rule) then return "all", { rule } end
  local mode = rule.all and "all" or rule.any and "any"
  if not mode then return nil end
  for _, r in ipairs(rule[mode]) do if not simple(r) then return nil end end
  local copy = {}
  for i, r in ipairs(rule[mode]) do copy[i] = r end
  return mode, copy
end

local function conditionForm(onAdd)
  local _, types = predicate.types()
  local picker = kit.openOverlay("Add condition")
  local list = picker:addList({ x = 1, y = 3, width = W, height = H - 2, background = C.bg,
    foreground = C.text, selectionBackground = C.select, selectionForeground = C.selectText })
  for _, t in ipairs(types) do
    list:addItem({ text = " " .. (t.description or t.name), callback = function()
      local form = kit.openOverlay(t.description or t.name)
      local read = kit.addForm(3, H - 4, t.params, nil, form)
      local negate
      if t.negatable then
        kit.addHintLabel(form, 2, H - 2, "Not", "Match players who DON'T meet this condition.")
        negate = form:addSwitch({ x = W - 5, y = H - 2, width = 4, onColor = C.primary, offColor = C.faint })
      end
      kit.addButton(form, 2, H, W - 2, "Add", "primary", function()
        local p, err = read()
        if not p then return kit.toast(err, "error", 4) end
        p.type = t.name
        local node = (negate and negate.checked) and { ["not"] = p } or p
        local ok, verr = pcall(function()
          local v, e = predicate.validate(node)
          if e then error(e, 0) end
          return v
        end)
        if not ok then return kit.toast(tostring(verr), "error", 4) end
        kit.closeOverlay() -- form
        kit.closeOverlay() -- picker
        onAdd(node)
      end)
    end })
  end
end

--- Open the rule editor for a rule; onDone(rule) runs with the new rule
-- (nil = everyone) when the user taps Done.
function kit.editRule(title, rule, onDone)
  local frame = kit.openOverlay(title)
  local mode, items = ruleItems(rule)
  if not mode then
    frame:addLabel({ x = 2, y = 3, text = "Too complex to edit here:", foreground = C.muted })
    frame:addLabel({ x = 2, y = 5, width = W - 2, height = 3,
      text = table.concat(kit.wrap(predicate.toText(rule), W - 2), "\n"), foreground = C.text })
    kit.addButton(frame, 2, H, W - 2, "Clear (everyone)", "danger", function()
      kit.closeOverlay()
      onDone(nil)
    end)
    return
  end

  local modeButton = frame:addButton({ x = 2, y = 3, width = W - 2, height = 1,
    background = C.field, foreground = C.fieldText })
  local list = frame:addList({ x = 1, y = 5, width = W, height = H - 7, background = C.bg,
    foreground = C.text, selectionBackground = C.select, selectionForeground = C.selectText,
    emptyText = "Everyone (no conditions)", emptyTextColor = C.faint })

  local refresh
  local function result()
    if #items == 0 then return nil end
    if #items == 1 then return items[1] end
    return { [mode] = items }
  end
  function refresh()
    modeButton.text = #items < 2 and "Tap a condition to remove it"
      or ("Match: " .. (mode == "all" and "ALL of these" or "ANY of these"))
    list:clear()
    for i, node in ipairs(items) do
      list:addItem({ text = " " .. predicate.describe(node), callback = function()
        kit.confirm("Remove", "Remove \"" .. predicate.describe(node) .. "\"?", function()
          table.remove(items, i)
          refresh()
        end)
      end })
    end
  end
  modeButton:onClick(function()
    if #items >= 2 then
      mode = mode == "all" and "any" or "all"
      refresh()
    end
  end)
  refresh()

  local bw = math.floor((W - 3) / 2)
  kit.addButton(frame, 2, H - 1, W - 2, "+ Add condition", "neutral", function()
    conditionForm(function(node)
      items[#items + 1] = node
      refresh()
    end)
  end)
  kit.addButton(frame, 2, H, bw, "Everyone", "neutral", function()
    items = {}
    refresh()
  end)
  kit.addButton(frame, W - bw, H, bw, "Done", "primary", function()
    kit.closeOverlay()
    onDone(result())
  end)
end


--- A checklist overlay for an option with several of a fixed set of values
-- (o.choices; o.choiceInfo can describe each). onDone(list) gets the result.
function kit.editChoices(title, o, current, onDone)
  local frame = kit.openOverlay(title)
  local set = {}
  for _, v in ipairs(current) do set[v] = true end
  local info = frame:addLabel({ x = 2, y = 3, width = W - 2, height = 2, text = "Tap to tick or untick.",
    foreground = C.muted })
  local list = frame:addList({ x = 1, y = 6, width = W, height = H - 6, background = C.bg,
    foreground = C.text, selectionBackground = C.select, selectionForeground = C.selectText })
  local function rowText(v) return (set[v] and " [x] " or " [ ] ") .. v end
  for _, v in ipairs(o.choices) do
    list:addItem({ text = rowText(v), callback = function(_, entry)
      set[v] = not set[v]
      entry:setText(rowText(v))
    end })
  end
  -- Describe the highlighted value.
  list:onSelect(function(_, index)
    local v = o.choices[index]
    local d = v and o.choiceInfo and o.choiceInfo[v]
    if d then info.text = table.concat(kit.wrap(v .. ": " .. d, W - 2), "\n") end
  end)
  kit.addButton(frame, 2, H, W - 2, "Done", "primary", function()
    local out = {}
    for _, v in ipairs(o.choices) do if set[v] then out[#out + 1] = v end end
    kit.closeOverlay()
    onDone(out)
  end)
end
--- A scrollable form from row y to row bottom with one row per option: a
-- tappable name (shows the hint) and a control (switch, text field, a
-- button cycling through choices, or a player-rule button). values: current
-- values (defaults used for missing ones). parent: the frame to add it to
-- (default: the screen). Returns read(), which returns the entered values,
-- or nil and an error message.
function kit.addForm(y, bottom, options, values, parent)
  parent = parent or root
  local form = parent:addFrame({ x = 1, y = y, width = W, height = bottom - y + 1,
    background = C.bg, scrollable = true })
  local controls = {}
  local row = 1
  for _, o in ipairs(options) do
    local value = values and values[o.name]
    if value == nil then value = o.default end
    kit.addHintLabel(form, 2, row, kit.optionLabel(o), kit.optionHint(o))
    if o.type == "predicate" then
      -- A rule: a button showing it; tapping opens the rule editor.
      local rule = value
      local b = form:addButton({ x = 2, y = row + 1, width = W - 3, height = 1,
        background = C.field, foreground = C.fieldText })
      local function show()
        local d = predicate.describe(rule)
        b.text = (#d > W - 3) and (d:sub(1, W - 6) .. "...") or d
      end
      b:onClick(function()
        kit.editRule(kit.optionLabel(o), rule, function(newRule)
          rule = newRule
          show()
        end)
      end)
      show()
      controls[o.name] = { get = function() return rule end }
      row = row + 1
    elseif o.type == "list" and o.choices then
      -- Several of a fixed set: a button showing them; tapping opens a checklist.
      local chosen = {}
      for _, v in ipairs(type(value) == "table" and value or {}) do chosen[#chosen + 1] = v end
      local b = form:addButton({ x = 2, y = row + 1, width = W - 3, height = 1,
        background = C.field, foreground = C.fieldText })
      local function show()
        local s = #chosen == 0 and "none" or table.concat(chosen, ", ")
        b.text = (#s > W - 3) and (s:sub(1, W - 6) .. "...") or s
      end
      b:onClick(function()
        kit.editChoices(kit.optionLabel(o), o, chosen, function(newList)
          chosen = newList
          show()
        end)
      end)
      show()
      controls[o.name] = { get = function() return chosen end }
      row = row + 1
    elseif o.type == "list" then
      -- Several free values (e.g. player names): comma-separated text.
      local input = form:addInput({ x = 2, y = row + 1, width = W - 3,
        text = table.concat(type(value) == "table" and value or {}, ", "), placeholder = "none",
        background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
      controls[o.name] = { get = function()
        local list = {}
        for w in input.text:gmatch("[^,%s]+") do list[#list + 1] = w end
        return list
      end }
      row = row + 1
    elseif (o.type or "boolean") == "boolean" then
      local sw = form:addSwitch({ x = W - 5, y = row, width = 4, checked = value == true,
        onColor = C.primary, offColor = C.faint })
      controls[o.name] = { get = function() return sw.checked end }
    elseif o.choices then
      controls[o.name] = choiceButton(form, W - 13, row, 12, o, value)
    else
      local input = form:addInput({ x = W - 11, y = row, width = 10,
        text = value ~= nil and tostring(value) or "", placeholder = o.default == nil and "none" or "",
        background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
      controls[o.name] = { get = function()
        local text = input.text
        if text == "" then return nil end -- the server fills in the default
        if o.type == "number" then
          local n = tonumber(text)
          if not n then error(kit.optionLabel(o) .. " must be a number.", 0) end
          return n
        end
        return text
      end }
    end
    row = row + 2
  end
  return function()
    local result = {}
    for _, o in ipairs(options) do
      local ok, v = pcall(controls[o.name].get)
      if not ok then return nil, v end
      result[o.name] = v
    end
    return result
  end
end

return kit
