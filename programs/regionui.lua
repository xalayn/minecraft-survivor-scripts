-- regionui: manage regions from a pocket computer (or any computer), with a
-- touch interface instead of commands. Talks to regiond over a wireless or
-- ender modem, so regiond must be running somewhere with a modem too.
--
-- Built with Basalt (lib/basalt.lua). Best on an advanced (color, touch)
-- pocket computer: lists work with arrow keys + Enter too, but dialog buttons
-- need a tap.
--
-- What it does:
--   - Lists regions, and shows which region(s) you're standing in (updated
--     every couple of seconds); tap a region to see it and its features.
--   - Teleport to a region (to the middle of its floor). A boundary you're
--     confined by still applies, unless you're exempt (e.g. creative).
--   - Add, change or remove features. Each feature's settings are shown as a
--     list; it's built from the feature's options, so new features appear
--     here automatically.
--   - Create a region by walking: stand at one corner and tap Set, then at
--     the opposite corner and tap Set. The server looks up where you are, so
--     no GPS is needed; it just needs to know your player name, which this
--     asks for once.
--   - Settings: your player name, the server password (if the server has
--     one), and whether to open this app when the computer starts.
--
-- Usage:
--   regionui
--
-- The < in the top left (or Backspace) goes back.

package.path = "/lib/?.lua;" .. package.path
local basalt = require("basalt")
local rpc = require("rpc")

local APP = "Regions"
local PLAYER_SETTING = "region.player"
local STARTUP = "/startup/60-regionui.lua"
local TIMEOUT = 90 -- seconds; drawing far-away regions can take a while

local W, H = term.getSize()
local root = basalt.getMainFrame()

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

local function describe(r)
  local a = r.area
  return string.format("%d,%d,%d to %d,%d,%d\n%dx%dx%d in %s",
    a[1], a[2], a[3], a[4], a[5], a[6],
    a[4] - a[1] + 1, a[5] - a[2] + 1, a[6] - a[3] + 1, (r.dim:gsub("^minecraft:", "")))
end

---------------------------------------------------------------------------
-- Screens. Each screen clears the root frame and builds its elements; work
-- that talks to the server runs in background tasks so the UI stays live.

-- The current screen. token changes whenever the screen does, so background
-- tasks can tell they belong to a screen that's gone.
local screen = { token = 0 }

-- Run fn in the background; errors are shown as a toast.
local function task(fn)
  basalt.schedule(function()
    local ok, err = pcall(fn)
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

-- Clear the root and draw the title bar (with a back button if onBack).
-- flash: optional { text, kind } toast to show on the new screen.
local function newScreen(title, onBack, flash)
  screen.token = screen.token + 1
  local children = root:getChildren()
  for i = #children, 1, -1 do
    local child = children[i]
    if child.destroy then child:destroy() end
    if children[i] == child then root:removeChild(child) end
  end
  root.background = colors.black

  local x = 1
  if onBack then
    root:addButton({ x = 1, y = 1, width = 3, height = 1, text = "<",
      background = colors.blue, foreground = colors.yellow }):onClick(function() onBack() end)
    x = 4
  end
  root:addLabel({ x = x, y = 1, width = W - x + 1, height = 1, text = " " .. title,
    background = colors.blue, foreground = colors.white })

  screen.back = onBack
  screen.dialog = root:addDialog()
  screen.toast = root:addToast()
  if flash then screen.toast:show(flash[1], flash[2] or "success", 3) end
  return screen.token
end

-- Add wrapped text from row y; returns the label and the next free row.
local function addText(y, text, color)
  local lines = wrap(text, W - 2)
  local label = root:addLabel({ x = 2, y = y, width = W - 2, height = #lines,
    text = table.concat(lines, "\n"), foreground = color or colors.lightGray })
  return label, y + #lines
end

-- Add a list filling the screen from row y, focused for keyboard use.
-- items: { text, fg, action } where action runs in a background task.
local function addMenu(y, items, emptyText)
  local list = root:addList({ x = 1, y = y, width = W, height = H - y + 1,
    emptyText = emptyText or "" })
  local function add(item)
    list:addItem({
      text = item.text, fg = item.fg,
      callback = function()
        if item.action then task(item.action) end
      end,
    })
  end
  for _, item in ipairs(items or {}) do add(item) end
  list:focus()
  return list, add
end

-- Text prompt dialog. callback(text) runs in a task if confirmed.
local function prompt(title, message, default, callback, mask)
  screen.dialog:prompt(title, message, default or "", function(text)
    if text ~= nil then task(function() callback(text) end) end
  end)
  -- Dialog:prompt doesn't expose its input; find it to put the cursor after
  -- the prefilled text (it starts at the beginning) and to mask passwords.
  local function find(el)
    if el.__name == "Input" then return el end
    for _, c in ipairs(el.getChildren and el:getChildren() or {}) do
      local found = find(c)
      if found then return found end
    end
  end
  local input = find(screen.dialog)
  if input then
    input:_moveCursor(#input.text + 1)
    if mask then input.replaceChar = mask end
  end
end

local function confirm(title, message, callback)
  screen.dialog:confirm(title, message, function(yes)
    if yes then task(callback) end
  end)
end

-- Forward declarations.
local mainScreen, regionScreen, featureForm, settingsScreen

---------------------------------------------------------------------------
-- Feature settings.

local function showValue(v)
  if v == true then return "on" end
  if v == false then return "off" end
  if v == nil then return "-" end
  return tostring(v)
end

local function optionLabel(o)
  return (o.name:gsub("-", " "))
end

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

-- The settings of one feature on a region. current: its settings if it's
-- already added.
function featureForm(regionName, info, current)
  local title = regionName .. ": " .. info.name
  newScreen(title, function() task(function() regionScreen(regionName) end) end)

  local values = {}
  for _, o in ipairs(info.options) do
    local v = current and current[o.name]
    if v == nil then v = o.default end
    if v == nil and (o.type or "boolean") == "boolean" then v = false end
    values[o.name] = v
  end

  local _, y = addText(3, (info.description or info.name) ..
    (#info.options > 0 and "\nTap a setting to change it." or ""))
  local list = addMenu(y + 1)

  local function rowText(o)
    return optionLabel(o) .. ": " .. showValue(values[o.name])
  end

  for i, o in ipairs(info.options) do
    list:addItem({
      text = rowText(o),
      callback = function(_, entry)
        if (o.type or "boolean") == "boolean" then
          values[o.name] = not values[o.name]
          entry:setText(rowText(o))
          return
        end
        local message = o.desc or optionLabel(o)
        if o.min or o.max then
          message = message .. string.format(" (%s to %s)", tostring(o.min or "any"), tostring(o.max or "any"))
        end
        if o.default == nil then message = message .. ". Empty to clear." end
        prompt(optionLabel(o), message, values[o.name] ~= nil and tostring(values[o.name]) or "", function(text)
          if text == "" and o.default == nil then
            values[o.name] = nil
          elseif text == "" then
            return
          elseif o.type == "number" then
            local n = tonumber(text)
            if not n then
              screen.toast:error("'" .. text .. "' isn't a number.", 4)
              return
            end
            values[o.name] = n
          else
            values[o.name] = text
          end
          entry:setText(rowText(o))
        end)
      end,
    })
  end

  list:addItem({
    text = current and "Save changes" or ("Add " .. info.name), fg = colors.lime,
    callback = function()
      task(function()
        local result = call("setFeature", regionName, info.name, values)
        if not result then return end
        local text = (current and "Saved " or "Added ") .. info.name
        if type(result) == "table" and result.needsDaemon then
          regionScreen(regionName, { text .. ", but regiond isn't running.", "warning" })
        else
          regionScreen(regionName, { text .. ".", "success" })
        end
      end)
    end,
  })
  if current then
    list:addItem({
      text = "Remove " .. info.name, fg = colors.red,
      callback = function()
        confirm(title, "Remove " .. info.name .. " from " .. regionName .. "?", function()
          if call("removeFeature", regionName, info.name) then
            regionScreen(regionName, { "Removed " .. info.name .. ".", "success" })
          end
        end)
      end,
    })
  end
end

-- Pick a feature to add to a region.
local function featurePicker(r, all)
  newScreen(r.name .. ": add", function() task(function() regionScreen(r.name) end) end)
  local names = {}
  for _, fname in ipairs(sortedKeys(all)) do
    if not r.features[fname] then names[#names + 1] = fname end
  end
  local desc, y = addText(3, "Pick a feature.\n ")
  local items = {}
  for _, fname in ipairs(names) do
    items[#items + 1] = { text = fname, action = function() featureForm(r.name, all[fname], nil) end }
  end
  local list = addMenu(y + 1, items, "All features are added.")
  -- Show the description of the highlighted feature.
  list:onSelect(function(_, index)
    local f = all[names[index]]
    if f then desc.text = table.concat(wrap(f.name .. ": " .. (f.description or ""), W - 2), "\n") end
  end)
end

---------------------------------------------------------------------------
-- Region screen.

function regionScreen(name, flash)
  local token = newScreen(name, function() task(mainScreen) end, flash)
  local loading = addText(3, "Loading...")
  local r = call("get", name)
  local all = r and features()
  if screen.token ~= token then return end
  if not r or not all then return end
  loading.text = ""

  local _, y = addText(3, describe(r))
  local items = {}
  for _, fname in ipairs(sortedKeys(r.features)) do
    items[#items + 1] = { text = "* " .. fname, action = function()
      if all[fname] then featureForm(r.name, all[fname], r.features[fname])
      else screen.toast:error("Unknown feature: " .. fname, 4) end
    end }
  end
  items[#items + 1] = { text = "+ Add feature", fg = colors.yellow, action = function()
    featurePicker(r, all)
  end }
  items[#items + 1] = { text = "Teleport here", action = function()
    local dest = call("teleport", player(), r.name)
    if dest then
      screen.toast:success(string.format("Teleported to %.1f, %d, %.1f", dest[1], dest[2], dest[3]), 3)
    end
  end }
  items[#items + 1] = { text = "Delete region", fg = colors.red, action = function()
    confirm(r.name, "Delete region " .. r.name .. "? Its features are removed too.", function()
      if call("delete", r.name) then mainScreen({ "Deleted " .. r.name .. ".", "success" }) end
    end)
  end }
  addMenu(y + 1, items)
end

---------------------------------------------------------------------------
-- New region: walk to two corners.

local function cornerScreen(name, first)
  local which = first and "second" or "first"
  newScreen("New: " .. name, function() task(mainScreen) end)
  local text = "Stand at the " .. which .. " corner of the region, then tap Set."
  if first then text = text .. string.format("\nFirst corner: %d,%d,%d", first[1], first[2], first[3]) end
  local _, y = addText(3, text, colors.white)
  addMenu(y + 1, {
    { text = "Set " .. which .. " corner", fg = colors.lime, action = function()
      local pos = call("playerPos", player())
      if not pos then return end
      if not first then return cornerScreen(name, pos) end
      if pos.dim ~= first.dim then
        screen.toast:error("Both corners must be in the same dimension.", 4)
        return
      end
      local preview = { dim = pos.dim, area = {
        math.min(first[1], pos[1]), math.min(first[2], pos[2]), math.min(first[3], pos[3]),
        math.max(first[1], pos[1]), math.max(first[2], pos[2]), math.max(first[3], pos[3]),
      } }
      confirm("New: " .. name, "Create " .. name .. "? " .. describe(preview):gsub("\n", ", "), function()
        local r = call("create", name, { first[1], first[2], first[3] }, { pos[1], pos[2], pos[3] }, pos.dim)
        if r then regionScreen(r.name, { "Created " .. r.name .. ".", "success" }) end
      end)
    end },
    { text = "Cancel", action = function() mainScreen() end },
  })
end

local function newRegion()
  prompt("New region", "Name for the new region (letters, numbers, - and _):", "", function(name)
    if name ~= "" then cornerScreen(name, nil) end
  end)
end

---------------------------------------------------------------------------
-- Settings.

local function setPlayer(name, after)
  if not name:match("^[%w_]+$") then
    screen.toast:error("That doesn't look like a player name.", 4)
    return false
  end
  settings.set(PLAYER_SETTING, name)
  settings.save()
  if after then after() end
  return true
end

function settingsScreen()
  newScreen("Settings", function() task(mainScreen) end)
  local list = addMenu(3)
  local function playerText() return "Player: " .. tostring(player()) end
  local function passwordText()
    return "Password: " .. (((settings.get(rpc.SECRET_SETTING) or "") ~= "") and "set" or "none")
  end
  local function bootText() return "Open on startup: " .. (fs.exists(STARTUP) and "on" or "off") end

  list:addItem({ text = playerText(), callback = function(_, entry)
    prompt("Player", "Your Minecraft player name:", player(), function(name)
      setPlayer(name, function() entry:setText(playerText()) end)
    end)
  end })
  list:addItem({ text = passwordText(), callback = function(_, entry)
    prompt("Password", "Only needed if the server has one (region.secret). Empty removes it.", "", function(secret)
      if secret == "" then settings.unset(rpc.SECRET_SETTING) else settings.set(rpc.SECRET_SETTING, secret) end
      settings.save()
      entry:setText(passwordText())
    end, "*")
  end })
  list:addItem({ text = bootText(), callback = function(_, entry)
    if fs.exists(STARTUP) then
      fs.delete(STARTUP)
    else
      local f = fs.open(STARTUP, "w")
      f.write('shell.run("/bin/regionui")\n')
      f.close()
    end
    entry:setText(bootText())
  end })
end

---------------------------------------------------------------------------
-- Main screen.

function mainScreen(flash)
  local token = newScreen(APP, nil, flash)
  local here = addText(3, "Locating you...")
  local list, add = addMenu(5, {}, "Loading...")

  local all = call("list")
  if screen.token ~= token then return end
  for _, name in ipairs(sortedKeys(all)) do
    local feats = sortedKeys(all[name].features)
    add({ text = name .. (#feats > 0 and (" (" .. table.concat(feats, ", ") .. ")") or ""),
      action = function() regionScreen(name) end })
  end
  if all then
    add({ text = "+ New region", fg = colors.yellow, action = newRegion })
  else
    add({ text = "Try again", action = function() mainScreen() end })
  end
  add({ text = "Settings", action = function() settingsScreen() end })
  add({ text = "Quit", action = function() basalt.stop() end })
  list.emptyText = ""

  -- Keep "You're in" up to date while this screen is shown.
  while screen.token == token do
    local ok, names = rpc.call("regionsAt", 5, player())
    if screen.token ~= token then return end
    if not ok then
      here.text = "Your location: unknown"
    elseif #names == 0 then
      here.text = "You're not in a region."
    else
      here.text = ("You're in: " .. table.concat(names, ", ")):sub(1, W - 2)
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

local _, modemErr = rpc.openModem()
if modemErr then
  newScreen(APP)
  addText(3, modemErr, colors.red)
  addMenu(6, { { text = "Quit", action = function() basalt.stop() end } })
elseif not player() then
  newScreen("Welcome")
  addText(3, "Your Minecraft player name is used to find where you are when setting corners.", colors.white)
  local function ask()
    prompt("Player", "Your Minecraft player name:", "", function(name)
      if setPlayer(name) then mainScreen() else ask() end
    end)
  end
  ask()
else
  task(mainScreen)
end

basalt.run()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
