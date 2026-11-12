-- controld: the control server. Runs every installed module's continuous work
-- (e.g. region boundaries and kill zones) and answers requests from pocket
-- computers running the control app.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- Run it on one designated computer. It claims a lock in the world, so a
-- second copy on another computer refuses to start and says where the running
-- one is. If the running computer stops (unloaded, broken) without releasing
-- the lock, another can take over after about 10 seconds.
--
-- Pocket computers connect through a wireless or ender modem attached here.
-- To require a password from them, run `set control.secret <password>` here
-- and enter the same in each pocket's control app settings.
--
-- Modules are folders in /lib/modules (see lib/control.lua). Stop with Ctrl+T.
--
-- Usage:
--   controld            Run in this shell.
--   controld enable     Start automatically when this computer boots (in its
--                       own tab), and start now.
--   controld disable    Stop starting automatically.

package.path = "/lib/?.lua;" .. package.path
local control = require("control")
local players = require("players")
local rpc = require("rpc")

if not commands then
  printError("controld requires a Command Computer")
  return
end

local STARTUP = "/startup/50-controld.lua"
local HEARTBEAT_EVERY = 2 -- seconds between lock heartbeats

local sub = ({ ... })[1]
if sub == "enable" then
  local f = fs.open(STARTUP, "w")
  f.write('if multishell then shell.openTab("/bin/controld") else shell.run("/bin/controld") end\n')
  f.close()
  print("controld will start on boot.")
  if multishell then
    shell.openTab("/bin/controld")
    print("Started in a new tab.")
  end
  return
elseif sub == "disable" then
  fs.delete(STARTUP)
  print("controld won't start on boot any more.")
  return
elseif sub then
  printError("Usage: controld [enable|disable]")
  return
end

local ok, holder = control.claimLock()
if not ok then
  printError("controld is already running on " .. holder .. ".")
  printError("Stop it there first (or wait ~10s if that computer is gone).")
  return
end

local function log(text)
  print(os.date("%H:%M:%S ") .. text)
end

-- Requests not tied to a module.
local HANDLERS = {
  ["core.status"] = function()
    local names = {}
    for _, n in ipairs(control.moduleNames()) do
      if control.server(n) then names[#names + 1] = n end
    end
    return true, { daemon = control.daemon(), modules = names }
  end,
  ["core.playerPos"] = players.blockPos,
  ["core.players"] = players.online,
}

-- Load module server parts.
local servers = {}
for _, name in ipairs(control.moduleNames()) do
  local mod, err = control.server(name)
  if mod then
    servers[#servers + 1] = mod
    for method, fn in pairs(mod.handlers or {}) do HANDLERS[name .. "." .. method] = fn end
    if mod.init then mod.init(log) end
    log("Module: " .. (mod.title or name))
  elseif err then
    log("Module " .. name .. " failed to load: " .. err)
  end
end

local function run()
  local nextBeat = 0
  while true do
    local t = os.clock()
    if t >= nextBeat then
      nextBeat = t + HEARTBEAT_EVERY
      local still, other = control.heartbeat()
      if not still then
        error("lock taken over by " .. other, 0)
      end
    end
    local busy = false
    for _, mod in ipairs(servers) do
      if mod.tick then
        local okTick, did = pcall(mod.tick)
        if not okTick then
          if did == "Terminated" then error(did, 0) end
          log("Error in " .. (mod.title or "module") .. ": " .. tostring(did))
        elseif did then
          busy = true
        end
      end
    end
    if not busy then sleep(0.5) end
  end
end

log("controld started on computer #" .. os.getComputerID() .. ". Ctrl+T to stop.")
local modem = rpc.openModem()
if modem then
  log("Serving pocket computers via modem '" .. modem .. "'" ..
    (rpc.secret() and " (password required)" or ""))
else
  log("No modem attached: pocket computers can't connect.")
end

local okRun, err = pcall(function()
  if modem then
    parallel.waitForAny(run, function() rpc.serve(HANDLERS, log) end)
  else
    run()
  end
end)
control.releaseLock()
if okRun or err == "Terminated" then
  log("controld stopped.")
else
  printError("controld stopped: " .. tostring(err))
end
