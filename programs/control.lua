-- control: the control app, for managing the server's game-show tools from a
-- pocket computer (or any computer). The home screen has a tile per module
-- (Regions, Teams, ...); modules are folders in /lib/modules with a ui.lua
-- (see lib/control.lua).
--
-- Talks to controld over a wireless or ender modem, so controld must be
-- running somewhere with a modem too. Built with Basalt (lib/basalt.lua), for
-- an advanced (color, touch) pocket computer.
--
-- Settings (gear tile): your player name (used to find where you are), the
-- server password (if the server has one), and whether to open this app when
-- the computer starts.
--
-- Usage:
--   control
--
-- The < in the top left (or Backspace) goes back; x in the top right quits.

package.path = "/lib/?.lua;" .. package.path
local control = require("control")
local rpc = require("rpc")
local kit = require("ui.kit")

local STARTUP = "/startup/60-control.lua"
local C, W, H, root = kit.C, kit.W, kit.H, kit.root

local homeScreen

local function validPlayer(name)
  return name:match("^[%w_]+$") ~= nil and #name <= 16
end

---------------------------------------------------------------------------
-- Settings.

local function settingsScreen()
  kit.newScreen("Settings", kit.home)

  kit.addHintLabel(root, 2, 3, "Player name",
    "Your Minecraft name. Used to find where you are (region corners, You're in, teleport).", C.muted)
  local playerInput = root:addInput({ x = 2, y = 4, width = W - 2, text = kit.player() or "",
    background = C.field, foreground = C.fieldText })

  kit.addHintLabel(root, 2, 6, "Server password",
    "Must match control.secret on the controld computer, if it has one. Leave empty to keep the current one.",
    C.muted)
  local hasSecret = rpc.secret() ~= nil
  local secretInput = root:addInput({ x = 2, y = 7, width = W - 2, replaceChar = "*",
    placeholder = hasSecret and "(unchanged)" or "none",
    background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
  kit.addText(8, "Only if the server has one.", C.faint)

  kit.addHintLabel(root, 2, 10, "Open on startup", "Open this app automatically when this computer turns on.")
  local bootSwitch = root:addSwitch({ x = W - 5, y = 10, width = 4, checked = fs.exists(STARTUP),
    onColor = C.primary, offColor = C.faint })

  if hasSecret then
    kit.addButton(root, 2, 12, W - 2, "Remove password", "neutral", function()
      settings.unset(rpc.SECRET_SETTING)
      settings.unset(rpc.OLD_SECRET_SETTING)
      settings.save()
      secretInput.placeholder = "none"
      kit.toast("Password removed.", "success")
    end)
  end

  kit.addBottomButtons({ "Save", "primary", function()
    if not validPlayer(playerInput.text) then
      return kit.toast("That doesn't look like a player name.", "error", 4)
    end
    settings.set(kit.PLAYER_SETTING, playerInput.text)
    if secretInput.text ~= "" then settings.set(rpc.SECRET_SETTING, secretInput.text) end
    settings.save()
    if bootSwitch.checked and not fs.exists(STARTUP) then
      local f = fs.open(STARTUP, "w")
      f.write('shell.run("/bin/control")\n')
      f.close()
    elseif not bootSwitch.checked and fs.exists(STARTUP) then
      fs.delete(STARTUP)
    end
    homeScreen({ "Settings saved.", "success" })
  end })
end

---------------------------------------------------------------------------
-- Home: a tile per module.

local function modules()
  local list = {}
  for _, name in ipairs(control.moduleNames()) do
    local ui = control.ui(name)
    if ui then list[#list + 1] = { name = name, ui = ui } end
  end
  table.sort(list, function(a, b)
    local oa, ob = a.ui.order or 100, b.ui.order or 100
    if oa ~= ob then return oa < ob end
    return a.name < b.name
  end)
  return list
end

function homeScreen(flash)
  local token = kit.newScreen("Control", nil, flash, true)
  local status = root:addLabel({ x = 1, y = 2, width = W, height = 1, text = " Connecting...",
    background = C.status, foreground = C.statusText })

  local frame = root:addFrame({ x = 1, y = 4, width = W, height = H - 5, background = C.bg, scrollable = true })
  local y = 1
  for _, m in ipairs(modules()) do
    local b = frame:addButton({ x = 2, y = y, width = W - 2, height = 3, text = m.ui.title or m.name,
      background = C.card, foreground = C.text })
    b:onClick(function() kit.task(m.ui.open, kit) end)
    y = y + 4
  end
  if y == 1 then
    frame:addLabel({ x = 2, y = 1, text = "No modules installed.", foreground = C.faint })
  end
  kit.addBottomButtons({ "Settings", "neutral", settingsScreen })

  local ok, info = kit.callQuiet("core.status", 5)
  if not kit.isCurrent(token) then return end
  if ok then
    status.text = (" Connected: " .. (kit.player() or "?")):sub(1, W)
  else
    status.text = (" " .. tostring(info)):sub(1, W)
  end
end

kit.home = function() kit.task(homeScreen) end

---------------------------------------------------------------------------
-- Start.

-- Backspace goes back (unless typing in a text field or a dialog is open).
kit.basalt.schedule(function()
  while true do
    local _, key = os.pullEvent("key")
    local focused = root:getFocused()
    local typing = focused and focused.__name == "Input"
    local screen = kit.screen
    if key == keys.backspace and not typing and not (screen.dialog and screen.dialog.visible) then
      if kit.overlayOpen() then
        kit.closeOverlay()
      elseif screen.back then
        screen.back()
      end
    end
  end
end)

local function welcomeScreen()
  kit.newScreen("Welcome", nil, nil, true)
  local _, y = kit.addText(3, "Enter your Minecraft player name. It's used to find where you are.", C.text)
  local input = root:addInput({ x = 2, y = y + 1, width = W - 2, placeholder = "Player name",
    background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
  local function done()
    if not validPlayer(input.text) then
      return kit.toast("That doesn't look like a player name.", "error", 4)
    end
    settings.set(kit.PLAYER_SETTING, input.text)
    settings.save()
    homeScreen()
  end
  input:onEnter(function() kit.task(done) end)
  kit.addButton(root, 2, y + 3, W - 2, "Continue", "primary", done)
  input:focus()
end

local _, modemErr = rpc.openModem()
if modemErr then
  kit.newScreen("Control", nil, nil, true)
  kit.addText(3, modemErr, colors.red)
elseif not kit.player() then
  welcomeScreen()
else
  kit.task(homeScreen)
end

kit.basalt.run()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
