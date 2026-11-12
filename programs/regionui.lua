-- regionui: manage regions from a pocket computer (or any computer), with
-- menus instead of commands. Talks to regiond over a wireless or ender modem,
-- so regiond must be running somewhere with a modem too.
--
-- What it does:
--   - Lists regions; pick one to see it and its features.
--   - Add, change or remove features. Each feature's settings are shown as a
--     form; the form is built from the feature's options, so new features
--     appear here automatically.
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
-- Pocket computer needs a wireless or ender modem (craft it with one, or
-- equip it from the inventory). Ender modems work at any distance and across
-- dimensions.

package.path = "/lib/?.lua;" .. package.path
local tui = require("tui")
local rpc = require("rpc")

local APP = "Regions"
local PLAYER_SETTING = "region.player"
local STARTUP = "/startup/60-regionui.lua"
local TIMEOUT = 90 -- seconds; drawing far-away regions can take a while

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Call regiond, showing a busy screen. Returns the result (true if there is
-- none), or nil after showing the error.
local function call(method, ...)
  tui.busy(APP, "Talking to the server...")
  local ok, result = rpc.call(method, TIMEOUT, ...)
  if not ok then
    tui.message(APP, { "Something went wrong:", "", tostring(result) }, "bad")
    return nil
  end
  if result == nil then return true end
  return result
end

local function describe(r)
  local a = r.area
  return {
    string.format("%d,%d,%d to", a[1], a[2], a[3]),
    string.format("%d,%d,%d", a[4], a[5], a[6]),
    string.format("%dx%dx%d in %s", a[4] - a[1] + 1, a[5] - a[2] + 1, a[6] - a[3] + 1,
      (r.dim:gsub("^minecraft:", ""))),
  }
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

---------------------------------------------------------------------------
-- Feature settings form.

local function showValue(v)
  if v == true then return "on" end
  if v == false then return "off" end
  if v == nil then return "-" end
  return tostring(v)
end

local function optionLabel(o)
  return (o.name:gsub("-", " "))
end

-- Edit one option. Returns the new value (or the old one if unchanged).
local function editOption(title, o, value)
  if (o.type or "boolean") == "boolean" then return not value end
  local info = { o.desc or optionLabel(o) }
  if o.min or o.max then
    info[#info + 1] = string.format("(%s to %s)", tostring(o.min or "any"), tostring(o.max or "any"))
  end
  if o.default == nil then info[#info + 1] = "Enter - to clear." end
  local text = tui.prompt(title, info, value ~= nil and tostring(value) or nil)
  if text == nil then return value end
  if text == "-" and o.default == nil then return nil end
  if o.type == "number" then
    local n = tonumber(text)
    if not n then
      tui.message(title, { "'" .. text .. "' isn't a number." }, "bad")
      return value
    end
    return n
  end
  return text
end

-- Show the form for a feature on a region. current: its settings if already
-- added. Returns when done.
local function featureForm(region, info, current)
  local title = region .. ": " .. info.name
  local values = {}
  for _, o in ipairs(info.options) do
    local v = current and current[o.name]
    if v == nil then v = o.default end
    if v == nil and (o.type or "boolean") == "boolean" then v = false end
    values[o.name] = v
  end
  local sel = 1
  while true do
    local items = {}
    for i, o in ipairs(info.options) do
      items[#items + 1] = { label = optionLabel(o) .. ": " .. showValue(values[o.name]), value = i }
    end
    items[#items + 1] = { label = current and "Save changes" or ("Add " .. info.name),
      value = "save", color = tui.color("good") }
    if current then
      items[#items + 1] = { label = "Remove " .. info.name, value = "remove", color = tui.color("bad") }
    end
    items[#items + 1] = { label = "< Back", value = "back" }

    local choice = tui.menu(title, items, {
      info = { info.description or info.name, #info.options > 0 and "Tap a setting to change it." or nil },
      selected = sel,
    })
    if choice == nil or choice == "back" then return end

    if choice == "save" then
      local result = call("setFeature", region, info.name, values)
      if result then
        local lines = { (current and "Saved " or "Added ") .. info.name .. "." }
        if type(result) == "table" and result.message then lines[#lines + 1] = result.message end
        if type(result) == "table" and result.needsDaemon then
          lines[#lines + 1] = "Note: regiond isn't enforcing regions right now."
        end
        tui.message(title, lines, "good")
        return
      end
    elseif choice == "remove" then
      if tui.confirm(title, "Remove " .. info.name .. " from " .. region .. "?", "Remove") then
        if call("removeFeature", region, info.name) then
          tui.message(title, { "Removed " .. info.name .. "." }, "good")
          return
        end
      end
    else
      sel = choice
      local o = info.options[choice]
      values[o.name] = editOption(title, o, values[o.name])
    end
  end
end

---------------------------------------------------------------------------
-- Region screen.

local function regionScreen(name)
  while true do
    local r = call("get", name)
    if not r then return end
    local all = features()
    if not all then return end

    local items = {}
    for _, fname in ipairs(sortedKeys(r.features)) do
      items[#items + 1] = { label = "* " .. fname, value = { edit = fname } }
    end
    items[#items + 1] = { label = "+ Add feature", value = "add", color = tui.color("accent") }
    items[#items + 1] = { label = "Delete region", value = "delete", color = tui.color("bad") }
    items[#items + 1] = { label = "< Back", value = "back" }

    local choice = tui.menu(r.name, items, { info = describe(r) })
    if choice == nil or choice == "back" then return end

    if choice == "add" then
      local options, descriptions = {}, {}
      for _, fname in ipairs(sortedKeys(all)) do
        if not r.features[fname] then
          options[#options + 1] = { label = fname, value = fname }
          descriptions[#descriptions + 1] = fname .. ": " .. (all[fname].description or "")
        end
      end
      if #options == 0 then
        tui.message(r.name, { "All features are already added." })
      else
        options[#options + 1] = { label = "< Back", value = "back" }
        local fname = tui.menu(r.name .. ": add", options, { info = descriptions })
        if fname and fname ~= "back" then featureForm(r.name, all[fname], nil) end
      end
    elseif choice == "delete" then
      if tui.confirm(r.name, { "Delete region " .. r.name .. "?", "Its features are removed too." }, "Delete") then
        if call("delete", r.name) then
          tui.message(APP, { "Deleted " .. r.name .. "." }, "good")
          return
        end
      end
    elseif type(choice) == "table" then
      local info = all[choice.edit]
      if info then
        featureForm(r.name, info, r.features[choice.edit])
      else
        tui.message(r.name, { "Unknown feature: " .. choice.edit }, "bad")
      end
    end
  end
end

---------------------------------------------------------------------------
-- New region wizard.

-- Ask the player to stand at a corner. Returns { x, y, z, dim } or nil.
local function setCorner(title, which, first)
  local player = settings.get(PLAYER_SETTING)
  while true do
    local info = { "Stand at the " .. which .. " corner of the region, then choose Set." }
    if first then
      info[#info + 1] = string.format("First corner: %d,%d,%d", first[1], first[2], first[3])
    end
    local choice = tui.menu(title, {
      { label = "Set " .. which .. " corner", value = "set", color = tui.color("good") },
      { label = "Cancel", value = "cancel" },
    }, { info = info })
    if choice ~= "set" then return nil end
    local pos = call("playerPos", player)
    if pos then return pos end
  end
end

local function newRegion()
  local name = tui.prompt("New region", { "Name for the new region:", "(letters, numbers, - and _)" })
  if not name or name == "" then return end
  local title = "New: " .. name
  local p1 = setCorner(title, "first")
  if not p1 then return end
  local p2 = setCorner(title, "second", p1)
  if not p2 then return end
  if p1.dim ~= p2.dim then
    tui.message(title, { "Both corners must be in the same dimension." }, "bad")
    return
  end
  local preview = {
    name = name, dim = p1.dim,
    area = {
      math.min(p1[1], p2[1]), math.min(p1[2], p2[2]), math.min(p1[3], p2[3]),
      math.max(p1[1], p2[1]), math.max(p1[2], p2[2]), math.max(p1[3], p2[3]),
    },
  }
  local info = describe(preview)
  table.insert(info, 1, "Create this region?")
  if not tui.confirm(title, info, "Create") then return end
  local r = call("create", name, { p1[1], p1[2], p1[3] }, { p2[1], p2[2], p2[3] }, p1.dim)
  if r then regionScreen(r.name) end
end

---------------------------------------------------------------------------
-- Settings.

local function askPlayer()
  while true do
    local name = tui.prompt("Your player name", {
      "What's your Minecraft player name?",
      "It's used to find where you are when setting corners.",
    }, settings.get(PLAYER_SETTING))
    if name and name:match("^[%w_]+$") then
      settings.set(PLAYER_SETTING, name)
      settings.save()
      return name
    end
    tui.message("Your player name", { "That doesn't look like a player name." }, "bad")
  end
end

local function settingsScreen()
  local sel = 1
  while true do
    local hasSecret = (settings.get(rpc.SECRET_SETTING) or "") ~= ""
    local onBoot = fs.exists(STARTUP)
    local choice = tui.menu("Settings", {
      { label = "Player: " .. tostring(settings.get(PLAYER_SETTING)), value = 1 },
      { label = "Password: " .. (hasSecret and "set" or "none"), value = 2 },
      { label = "Open on startup: " .. (onBoot and "on" or "off"), value = 3 },
      { label = "< Back", value = "back" },
    }, { selected = sel })
    if choice == nil or choice == "back" then return end
    sel = choice
    if choice == 1 then
      askPlayer()
    elseif choice == 2 then
      local secret = tui.prompt("Password", {
        "Only needed if the server has a password (region.secret).",
        "Leave empty to keep it, - to remove it.",
      }, nil, { mask = "*" })
      if secret == "-" then settings.unset(rpc.SECRET_SETTING)
      elseif secret and secret ~= "" then settings.set(rpc.SECRET_SETTING, secret) end
      settings.save()
    elseif choice == 3 then
      if onBoot then
        fs.delete(STARTUP)
      else
        local f = fs.open(STARTUP, "w")
        f.write('shell.run("/bin/regionui")\n')
        f.close()
      end
    end
  end
end

---------------------------------------------------------------------------
-- Main menu.

local function main()
  local _, modemErr = rpc.openModem()
  if modemErr then
    tui.message(APP, { modemErr }, "bad")
    return
  end
  if not settings.get(PLAYER_SETTING) then askPlayer() end

  while true do
    local items = {}
    local all = call("list")
    if all then
      for _, name in ipairs(sortedKeys(all)) do
        local feats = sortedKeys(all[name].features)
        items[#items + 1] = {
          label = name .. (#feats > 0 and (" (" .. table.concat(feats, ", ") .. ")") or ""),
          value = { region = name },
        }
      end
      items[#items + 1] = { label = "+ New region", value = "new", color = tui.color("accent") }
    else
      items[#items + 1] = { label = "Try again", value = "retry" }
    end
    items[#items + 1] = { label = "Settings", value = "settings" }
    items[#items + 1] = { label = "Quit", value = "quit" }

    local info = all and next(all) == nil and { "No regions yet." } or nil
    local choice = tui.menu(APP, items, { info = info })
    if choice == nil or choice == "quit" then return end
    if choice == "new" then newRegion()
    elseif choice == "settings" then settingsScreen()
    elseif type(choice) == "table" then regionScreen(choice.region)
    end
  end
end

local ok, err = pcall(main)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
