-- regionui: manage regions from a pocket computer (or any computer), with a
-- touch interface instead of commands. Talks to regiond over a wireless or
-- ender modem, so regiond must be running somewhere with a modem too.
--
-- Built with Basalt (lib/basalt.lua), for an advanced (color, touch) pocket
-- computer.
--
-- What it does:
--   - Lists regions, searchable by name, and shows which region(s) you're
--     standing in (updated every couple of seconds). Tap a region to open it.
--   - A region shows its corners, size and features. Teleport to it (to the
--     middle of its floor; a boundary you're confined by still applies unless
--     you're exempt, e.g. creative) or delete it.
--   - Add, change or remove features. Each feature's settings are switches and
--     text fields built from the feature's options, so new features appear
--     here automatically.
--   - Create a region by walking: stand at one corner and tap Set, then at
--     the opposite corner and tap Set. The server looks up where you are, so
--     no GPS is needed; it just needs your player name, asked for once.
--   - Settings: your player name, the server password (if the server has
--     one), and whether to open this app when the computer starts.
--
-- Usage:
--   regionui
--
-- The < in the top left (or Backspace) goes back; x in the top right quits.

package.path = "/lib/?.lua;" .. package.path
local basalt = require("basalt")
local rpc = require("rpc")

local APP = "Regions"
local PLAYER_SETTING = "region.player"
local STARTUP = "/startup/60-regionui.lua"
local TIMEOUT = 90 -- seconds; drawing far-away regions can take a while

local W, H = term.getSize()
local root = basalt.getMainFrame()

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
}

---------------------------------------------------------------------------
-- Helpers.

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function wrap(text, width)
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

local function player()
  return settings.get(PLAYER_SETTING)
end

local function dimName(dim)
  return (dim:gsub("^minecraft:", ""))
end

local function sizeOf(area)
  return string.format("%dx%dx%d", area[4] - area[1] + 1, area[5] - area[2] + 1, area[6] - area[3] + 1)
end

---------------------------------------------------------------------------
-- Screen plumbing. Each screen clears the root frame and builds its
-- elements; work that talks to the server runs in background tasks.

-- The current screen. token changes whenever the screen does, so background
-- tasks can tell they belong to a screen that's gone.
local screen = { token = 0 }

-- Run fn in the background; errors are shown as a toast.
local function task(fn, ...)
  local args = table.pack(...)
  basalt.schedule(function()
    local ok, err = pcall(fn, table.unpack(args, 1, args.n))
    if not ok and err ~= "Terminated" and screen.toast then
      screen.toast:error(tostring(err), 5)
    end
  end)
end

-- Call regiond (inside a task). Shows "Working..." meanwhile. Returns the
-- result (true if there is none), or nil after showing the error.
local function call(method, ...)
  local toast = screen.toast
  if toast then toast:info("Working...", 0) end
  local ok, result = rpc.call(method, TIMEOUT, ...)
  if toast then toast:hide() end
  if not ok then
    if screen.toast then screen.toast:error(tostring(result), 5) end
    return nil
  end
  if result == nil then return true end
  return result
end

-- Clear the root and draw the title bar: a < button if onBack, an x (quit)
-- button if quit. flash: optional { text, kind } toast for the new screen.
local function newScreen(title, onBack, flash, quit)
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
  if flash then screen.toast:show(flash[1], flash[2] or "success", 3) end
  return screen.token
end

-- Wrapped text from row y; returns the label and the next free row.
local function addText(y, text, color, x, width)
  x, width = x or 2, width or (W - 2)
  local lines = wrap(text, width)
  local label = root:addLabel({ x = x, y = y, width = width, height = #lines,
    text = table.concat(lines, "\n"), foreground = color or C.muted })
  return label, y + #lines
end

-- A button; kind is "primary", "danger" or "neutral". onClick runs in a task.
local function addButton(parent, x, y, width, text, kind, onClick, height)
  kind = kind or "neutral"
  local b = parent:addButton({ x = x, y = y, width = width, height = height or 1, text = text,
    background = C[kind], foreground = C[kind .. "Text"] })
  b:onClick(function() task(onClick) end)
  return b
end

-- A scrollable list from row y to row bottom (default: the last row).
local function addList(y, bottom, emptyText)
  return root:addList({ x = 1, y = y, width = W, height = (bottom or H) - y + 1,
    background = C.bg, foreground = C.text,
    selectionBackground = C.select, selectionForeground = C.selectText,
    emptyText = emptyText or "", emptyTextColor = C.faint })
end

-- Add a list item whose action runs in a background task.
local function addItem(list, text, action, fg)
  list:addItem({ text = " " .. text, fg = fg, callback = function()
    if action then task(action) end
  end })
end

-- A gray card with "label  value" rows. Returns the next free row.
local function addCard(y, rows)
  local card = root:addFrame({ x = 2, y = y, width = W - 2, height = #rows + 2, background = C.card })
  for i, row in ipairs(rows) do
    card:addLabel({ x = 2, y = i + 1, text = row[1], foreground = C.cardLabel })
    card:addLabel({ x = 8, y = i + 1, text = row[2], foreground = C.cardText })
  end
  return y + #rows + 2
end

-- Text prompt dialog. callback(text) runs in a task if confirmed.
local function prompt(title, message, default, callback)
  screen.dialog:prompt(title, message, default or "", function(text)
    if text ~= nil then task(callback, text) end
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

local function confirm(title, message, callback)
  screen.dialog:confirm(title, message, function(yes)
    if yes then task(callback) end
  end)
end

-- Forward declarations.
local mainScreen, regionScreen

---------------------------------------------------------------------------
-- Feature settings.

local featureCache
local function features()
  if not featureCache then
    local list = call("features")
    if not list then return nil end
    featureCache = {}
    for _, f in ipairs(list) do featureCache[f.name] = f end
  end
  return featureCache
end

local function optionLabel(o)
  local s = o.name:gsub("-", " ")
  return s:sub(1, 1):upper() .. s:sub(2)
end

-- The settings of one feature on a region, as switches and text fields.
-- current: its settings if it's already added.
local function featureForm(regionName, info, current)
  local title = regionName .. " - " .. info.name
  newScreen(title, function() task(regionScreen, regionName) end)

  local _, y = addText(3, info.description or info.name)
  local form = root:addFrame({ x = 1, y = y + 1, width = W, height = H - y - 2,
    background = C.bg, scrollable = true })

  -- One row per option: label on the left, control on the right.
  local controls = {}
  local row = 1
  for _, o in ipairs(info.options) do
    local value = current and current[o.name]
    if value == nil then value = o.default end
    form:addLabel({ x = 2, y = row, text = optionLabel(o), foreground = C.text })
    if (o.type or "boolean") == "boolean" then
      controls[o.name] = form:addSwitch({ x = W - 5, y = row, width = 4, checked = value == true,
        onColor = C.primary, offColor = C.faint })
    else
      controls[o.name] = form:addInput({ x = W - 11, y = row, width = 10,
        text = value ~= nil and tostring(value) or "", placeholder = o.default == nil and "none" or "",
        background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
    end
    row = row + 2
  end

  -- Read the controls into a settings table, or nil and an error.
  local function values()
    local v = {}
    for _, o in ipairs(info.options) do
      local c = controls[o.name]
      if (o.type or "boolean") == "boolean" then
        v[o.name] = c.checked
      else
        local text = c.text
        if text == "" then
          v[o.name] = nil -- server fills in the default
        elseif o.type == "number" then
          v[o.name] = tonumber(text)
          if not v[o.name] then return nil, optionLabel(o) .. " must be a number." end
        else
          v[o.name] = text
        end
      end
    end
    return v
  end

  local bw = current and math.floor((W - 3) / 2) or (W - 2)
  addButton(root, 2, H, bw, current and "Save" or ("Add " .. info.name), "primary", function()
    local v, err = values()
    if not v then return screen.toast:error(err, 4) end
    local result = call("setFeature", regionName, info.name, v)
    if not result then return end
    local text = (current and "Saved " or "Added ") .. info.name
    if type(result) == "table" and result.needsDaemon then
      regionScreen(regionName, { text .. ", but regiond isn't running.", "warning" })
    else
      regionScreen(regionName, { text .. ".", "success" })
    end
  end)
  if current then
    addButton(root, W - bw, H, bw, "Remove", "danger", function()
      confirm(title, "Remove " .. info.name .. " from " .. regionName .. "?", function()
        if call("removeFeature", regionName, info.name) then
          regionScreen(regionName, { "Removed " .. info.name .. ".", "success" })
        end
      end)
    end)
  end
end

-- Pick a feature to add to a region: names with their descriptions.
local function featurePicker(r, all)
  newScreen(r.name .. " - add", function() task(regionScreen, r.name) end)
  addText(3, "Tap a feature to add it.")
  local list = addList(5, H, "All features are added.")
  for _, fname in ipairs(sortedKeys(all)) do
    if not r.features[fname] then
      list:addItem({ text = " " .. fname, callback = function() task(featureForm, r.name, all[fname], nil) end })
      for _, line in ipairs(wrap(all[fname].description or "", W - 3)) do
        list:addItem({ text = "  " .. line, fg = C.muted, selectable = false })
      end
      list:addItem({ text = "", selectable = false })
    end
  end
end

---------------------------------------------------------------------------
-- Region screen.

function regionScreen(name, flash)
  local token = newScreen(name, function() task(mainScreen) end, flash)
  local r = call("get", name)
  local all = r and features()
  if screen.token ~= token or not r or not all then return end

  local a = r.area
  local y = addCard(3, {
    { "From", string.format("%d, %d, %d", a[1], a[2], a[3]) },
    { "To", string.format("%d, %d, %d", a[4], a[5], a[6]) },
    { "Size", sizeOf(a) },
    { "World", dimName(r.dim) },
  })

  root:addLabel({ x = 2, y = y + 1, text = "Features", foreground = C.muted })
  addButton(root, W - 7, y + 1, 7, "+ Add", "primary", function() featurePicker(r, all) end)
  local list = addList(y + 3, H - 2, "No features yet.")
  for _, fname in ipairs(sortedKeys(r.features)) do
    addItem(list, fname, function()
      if all[fname] then featureForm(r.name, all[fname], r.features[fname])
      else screen.toast:error("Unknown feature: " .. fname, 4) end
    end)
  end

  local bw = math.floor((W - 3) / 2)
  addButton(root, 2, H, bw, "Teleport", "neutral", function()
    local dest = call("teleport", player(), r.name)
    if dest then
      screen.toast:success(string.format("Teleported to %.1f, %d, %.1f", dest[1], dest[2], dest[3]), 3)
    end
  end)
  addButton(root, W - bw, H, bw, "Delete", "danger", function()
    confirm(r.name, "Delete region " .. r.name .. "? Its features are removed too.", function()
      if call("delete", r.name) then mainScreen({ "Deleted " .. r.name .. ".", "success" }) end
    end)
  end)
end

---------------------------------------------------------------------------
-- New region: walk to two corners.

local function cornerScreen(name, first)
  newScreen("New: " .. name, function() task(mainScreen) end)
  root:addLabel({ x = 2, y = 3, text = first and "Step 2 of 2" or "Step 1 of 2", foreground = C.muted })
  local _, y = addText(5, "Stand at the " .. (first and "opposite" or "first") ..
    " corner of the region, then tap Set.", C.text)
  if first then
    y = addCard(y + 1, { { "First", string.format("%d, %d, %d", first[1], first[2], first[3]) } })
  end

  addButton(root, 2, y + 1, W - 2, "Set " .. (first and "second" or "first") .. " corner", "primary", function()
    local pos = call("playerPos", player())
    if not pos then return end
    if not first then return cornerScreen(name, pos) end
    if pos.dim ~= first.dim then
      return screen.toast:error("Both corners must be in the same dimension.", 4)
    end
    local area = {
      math.min(first[1], pos[1]), math.min(first[2], pos[2]), math.min(first[3], pos[3]),
      math.max(first[1], pos[1]), math.max(first[2], pos[2]), math.max(first[3], pos[3]),
    }
    confirm("New: " .. name, string.format("Create %s? %s in %s.", name, sizeOf(area), dimName(pos.dim)), function()
      local r = call("create", name, { first[1], first[2], first[3] }, { pos[1], pos[2], pos[3] }, pos.dim)
      if r then regionScreen(r.name, { "Created " .. r.name .. ".", "success" }) end
    end)
  end, 3)
end

local function newRegion()
  prompt("New region", "Name for the new region (letters, numbers, - and _):", "", function(name)
    if name ~= "" then cornerScreen(name, nil) end
  end)
end

---------------------------------------------------------------------------
-- Settings.

local function validPlayer(name)
  return name:match("^[%w_]+$") ~= nil
end

local function settingsScreen()
  newScreen("Settings", function() task(mainScreen) end)

  root:addLabel({ x = 2, y = 3, text = "Player name", foreground = C.muted })
  local playerInput = root:addInput({ x = 2, y = 4, width = W - 2, text = player() or "",
    background = C.field, foreground = C.fieldText })

  root:addLabel({ x = 2, y = 6, text = "Server password", foreground = C.muted })
  local hasSecret = (settings.get(rpc.SECRET_SETTING) or "") ~= ""
  local secretInput = root:addInput({ x = 2, y = 7, width = W - 2, replaceChar = "*",
    placeholder = hasSecret and "(unchanged)" or "none",
    background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
  addText(8, "Only if the server has one.", C.faint)

  root:addLabel({ x = 2, y = 10, text = "Open on startup", foreground = C.text })
  local bootSwitch = root:addSwitch({ x = W - 5, y = 10, width = 4, checked = fs.exists(STARTUP),
    onColor = C.primary, offColor = C.faint })

  if hasSecret then
    addButton(root, 2, 12, W - 2, "Remove password", "neutral", function()
      settings.unset(rpc.SECRET_SETTING)
      settings.save()
      secretInput.placeholder = "none"
      screen.toast:success("Password removed.", 3)
    end)
  end

  addButton(root, 2, H, W - 2, "Save", "primary", function()
    if not validPlayer(playerInput.text) then
      return screen.toast:error("That doesn't look like a player name.", 4)
    end
    settings.set(PLAYER_SETTING, playerInput.text)
    if secretInput.text ~= "" then settings.set(rpc.SECRET_SETTING, secretInput.text) end
    settings.save()
    if bootSwitch.checked and not fs.exists(STARTUP) then
      local f = fs.open(STARTUP, "w")
      f.write('shell.run("/bin/regionui")\n')
      f.close()
    elseif not bootSwitch.checked and fs.exists(STARTUP) then
      fs.delete(STARTUP)
    end
    mainScreen({ "Settings saved.", "success" })
  end)
end

---------------------------------------------------------------------------
-- Main screen: search + region list.

function mainScreen(flash)
  local token = newScreen(APP, nil, flash, true)
  local status = root:addLabel({ x = 1, y = 2, width = W, height = 1, text = " Locating you...",
    background = C.status, foreground = C.statusText })

  local search = root:addInput({ x = 2, y = 4, width = W - 2, placeholder = "Search regions",
    background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
  local count = root:addLabel({ x = 2, y = 5, text = "", foreground = C.faint })
  local list = addList(6, H - 2, "Loading...")

  addButton(root, 2, H, 10, "+ New", "primary", newRegion)
  addButton(root, W - 10, H, 10, "Settings", "neutral", settingsScreen)

  local all = call("list")
  if screen.token ~= token then return end
  local names = sortedKeys(all)

  local function fill()
    local query = search.text:lower()
    list:clear()
    local shown = 0
    for _, name in ipairs(names) do
      if query == "" or name:lower():find(query, 1, true) then
        addItem(list, name, function() regionScreen(name) end)
        shown = shown + 1
      end
    end
    if not all then
      list.emptyText = "Couldn't load regions."
    elseif #names == 0 then
      list.emptyText = "No regions yet. Tap + New."
    else
      list.emptyText = "No matches."
    end
    count.text = query == "" and (#names .. " region" .. (#names == 1 and "" or "s"))
      or (shown .. " of " .. #names)
  end
  search:onChange(fill)
  fill()

  -- Keep "You're in" up to date while this screen is shown.
  while screen.token == token do
    local ok, here = rpc.call("regionsAt", 5, player())
    if screen.token ~= token then return end
    if not ok then
      status.text = " Location unknown"
    elseif #here == 0 then
      status.text = " Not in a region"
    else
      status.text = (" You're in: " .. table.concat(here, ", ")):sub(1, W)
    end
    sleep(2)
  end
end

---------------------------------------------------------------------------
-- Start.

-- Backspace goes back (unless typing in a text field or a dialog is open).
basalt.schedule(function()
  while true do
    local _, key = os.pullEvent("key")
    local focused = root:getFocused()
    local typing = focused and focused.__name == "Input"
    if key == keys.backspace and screen.back and not typing
        and not (screen.dialog and screen.dialog.visible) then
      screen.back()
    end
  end
end)

local function welcomeScreen()
  newScreen("Welcome", nil, nil, true)
  local _, y = addText(3, "Enter your Minecraft player name. It's used to find where you are.", C.text)
  local input = root:addInput({ x = 2, y = y + 1, width = W - 2, placeholder = "Player name",
    background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
  local function done()
    if not validPlayer(input.text) then
      return screen.toast:error("That doesn't look like a player name.", 4)
    end
    settings.set(PLAYER_SETTING, input.text)
    settings.save()
    mainScreen()
  end
  input:onEnter(function() task(done) end)
  addButton(root, 2, y + 3, W - 2, "Continue", "primary", done)
  input:focus()
end

local _, modemErr = rpc.openModem()
if modemErr then
  newScreen(APP, nil, nil, true)
  addText(3, modemErr, colors.red)
elseif not player() then
  welcomeScreen()
else
  task(mainScreen)
end

basalt.run()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
