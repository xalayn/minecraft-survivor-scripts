-- Regions module, server side: requests for the control app (see
-- lib/regionops.lua) and the engine that runs continuous region features
-- (boundary, killzone, ...) every tick.

local regions = require("regions")
local regionops = require("regionops")
local cmd = require("cmd")

local RELOAD_EVERY = 1 -- seconds between checks for region changes

local log = print

-- Loaded regions and feature modules.
local all, version = {}, nil
local features = {} -- feature name -> module, or false if it failed to load
local states = {}   -- feature name -> region name -> state table
local entries = {}  -- active (region, feature) pairs with per-tick behaviour
local nextReload = 0

local function reload()
  all = regions.all()
  local n = 0
  for _, r in pairs(all) do
    n = n + 1
    for fname in pairs(r.features) do
      if features[fname] == nil then
        local mod, err = regions.feature(fname)
        features[fname] = mod or false
        if not mod then log("Warning: " .. err) end
      end
    end
  end
  log(string.format("Regions: loaded %d region(s)", n))

  entries = {}
  for rname, r in pairs(all) do
    for fname, settings in pairs(r.features) do
      local mod = features[fname]
      if mod and (mod.queries or mod.act) then
        states[fname] = states[fname] or {}
        states[fname][rname] = states[fname][rname] or {}
        entries[#entries + 1] = { region = r, settings = settings, mod = mod,
          ctx = { state = states[fname][rname], log = log } }
      end
    end
  end
end

-- One round of feature queries and actions.
local function runFeatures()
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
      local ok, out = pcall(e.mod.act, e.region, e.settings, e.ctx, results)
      if ok then
        for _, a in ipairs(out or {}) do actions[#actions + 1] = a end
      else
        log("Error in region " .. e.region.name .. ": " .. tostring(out))
      end
    end
  end
  if #actions > 0 then cmd.execAll(actions) end
end

return {
  title = "Regions",

  handlers = {
    list = regionops.list,
    get = regionops.get,
    create = regionops.create,
    setFeature = regionops.setFeature,
    removeFeature = regionops.removeFeature,
    delete = regionops.delete,
    features = regionops.features,
    regionsAt = regionops.regionsAt,
    teleport = regionops.teleport,
  },

  init = function(logFn)
    log = logFn
  end,

  tick = function()
    local t = os.clock()
    if t >= nextReload then
      nextReload = t + RELOAD_EVERY
      local v = regions.version()
      if v ~= version then
        version = v
        reload()
      end
    end
    if #entries == 0 then return false end
    runFeatures()
    return true
  end,
}
