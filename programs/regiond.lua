-- regiond: enforce region features (boundary, killzone, ...) continuously.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- Run it on one designated computer. It claims a lock in the world, so a
-- second copy on another computer refuses to start and says where the running
-- one is. If the running computer stops (unloaded, broken) without releasing
-- the lock, another can take over after about 10 seconds.
--
-- Picks up region changes made with the region program within a second.
-- Stop with Ctrl+T.
--
-- With a wireless or ender modem attached, it also serves pocket computers
-- running regionui. To require a password from them, run
-- `set region.secret <password>` here and set the same on each pocket.
--
-- Usage:
--   regiond             Run in this shell.
--   regiond enable      Start automatically when this computer boots (in its
--                       own tab), and start now.
--   regiond disable     Stop starting automatically.

package.path = "/lib/?.lua;" .. package.path
local regions = require("regions")
local cmd = require("cmd")
local rpc = require("rpc")
local regionops = require("regionops")

if not commands then
  printError("regiond requires a Command Computer")
  return
end

local STARTUP = "/startup/50-regiond.lua"
local RELOAD_EVERY = 1   -- seconds between checks for region changes
local HEARTBEAT_EVERY = 2 -- seconds between lock heartbeats

local sub = ({ ... })[1]
if sub == "enable" then
  local f = fs.open(STARTUP, "w")
  f.write('if multishell then shell.openTab("/bin/regiond") else shell.run("/bin/regiond") end\n')
  f.close()
  print("regiond will start on boot.")
  if multishell then
    shell.openTab("/bin/regiond")
    print("Started in a new tab.")
  end
  return
elseif sub == "disable" then
  fs.delete(STARTUP)
  print("regiond won't start on boot any more.")
  return
elseif sub then
  printError("Usage: regiond [enable|disable]")
  return
end

local ok, holder = regions.claimLock()
if not ok then
  printError("regiond is already running on " .. holder .. ".")
  printError("Stop it there first (or wait ~10s if that computer is gone).")
  return
end

local function log(text)
  print(os.date("%H:%M:%S ") .. text)
end

-- Loaded regions and feature modules.
local all, version = {}, nil
local modules = {}  -- feature name -> module, or false if it failed to load
local states = {}   -- feature name -> region name -> state table

local function reload()
  all = regions.all()
  local n = 0
  for _, r in pairs(all) do
    n = n + 1
    for fname in pairs(r.features) do
      if modules[fname] == nil then
        local mod, err = regions.feature(fname)
        modules[fname] = mod or false
        if not mod then log("Warning: " .. err) end
      end
    end
  end
  log(string.format("Loaded %d region(s)", n))
end

-- Active (region, feature) pairs with per-tick behaviour.
local function active()
  local list = {}
  for rname, r in pairs(all) do
    for fname, settings in pairs(r.features) do
      local mod = modules[fname]
      if mod and (mod.queries or mod.act) then
        states[fname] = states[fname] or {}
        states[fname][rname] = states[fname][rname] or {}
        list[#list + 1] = { region = r, settings = settings, mod = mod,
          ctx = { state = states[fname][rname], log = log } }
      end
    end
  end
  return list
end

local function tick(entries)
  local now = os.epoch("utc") / 1000

  -- Collect queries, running identical ones once.
  local queries, seen = {}, {}
  for _, e in ipairs(entries) do
    e.ctx.now = now
    if e.mod.queries then
      for _, q in ipairs(e.mod.queries(e.region, e.settings, e.ctx) or {}) do
        if not seen[q] then
          seen[q] = true
          queries[#queries + 1] = q
        end
      end
    end
  end

  local results = {}
  if #queries == 0 then
    sleep(0.05) -- execAll would return without yielding; wait a tick instead
  end
  for i, r in ipairs(cmd.execAll(queries)) do results[queries[i]] = r end

  local actions = {}
  for _, e in ipairs(entries) do
    if e.mod.act then
      local okAct, out = pcall(e.mod.act, e.region, e.settings, e.ctx, results)
      if okAct then
        for _, a in ipairs(out or {}) do actions[#actions + 1] = a end
      else
        log("Error in " .. e.region.name .. ": " .. tostring(out))
      end
    end
  end
  if #actions > 0 then cmd.execAll(actions) end
end

local function run()
  local nextReload, nextBeat = 0, 0
  local entries = {}
  while true do
    local t = os.clock()
    if t >= nextReload then
      nextReload = t + RELOAD_EVERY
      local v = regions.version()
      if v ~= version then
        version = v
        reload()
        entries = active()
      end
    end
    if t >= nextBeat then
      nextBeat = t + HEARTBEAT_EVERY
      local still, other = regions.heartbeat()
      if not still then
        error("lock taken over by " .. other, 0)
      end
    end
    if #entries > 0 then
      tick(entries)
    else
      sleep(0.5)
    end
  end
end

-- Requests from pocket computers (see lib/rpc.lua).
local HANDLERS = {
  list = regionops.list,
  get = regionops.get,
  create = regionops.create,
  setFeature = regionops.setFeature,
  removeFeature = regionops.removeFeature,
  delete = regionops.delete,
  features = regionops.features,
  playerPos = regionops.playerPos,
  status = regionops.status,
}

log("regiond started on computer #" .. os.getComputerID() .. ". Ctrl+T to stop.")
local modem = rpc.openModem()
if modem then
  log("Serving pocket computers via modem '" .. modem .. "'" ..
    (settings.get(rpc.SECRET_SETTING) and " (password required)" or ""))
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
regions.releaseLock()
if okRun or err == "Terminated" then
  log("regiond stopped.")
else
  printError("regiond stopped: " .. tostring(err))
end
