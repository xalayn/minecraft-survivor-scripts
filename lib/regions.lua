-- regions: named areas with features attached, stored in the world.
--
--   local regions = require("regions")
--
-- A region is { name, dim, area = { x0, y0, z0, x1, y1, z1 }, features = {
-- <feature name> = <settings table>, ... } }. Regions are stored in command
-- storage (ccregion:store, saved with the world) as one JSON string each, so
-- every command computer sees the same regions.
--
-- Features are modules in /lib/features/<name>.lua (lib/features/ in the repo).
-- Adding a feature means adding a file there that returns a table with any of:
--
--   description  One line shown by `region features`.
--   options      Option specs (see lib/args.lua). `region add` parses them and
--                stores the result as the region's settings for the feature.
--   enable(region, settings) -> ok, message
--                Called once by `region add` (e.g. draw summons the box).
--   disable(region, settings)
--                Called once by `region remove`/`region delete` to undo
--                everything (e.g. release confined players).
--   queries(region, settings, ctx) -> { command, ... }
--                Called by controld every tick. Commands to run this tick;
--                identical commands from different features/regions run once.
--   act(region, settings, ctx, results) -> { command, ... }
--                Called by controld after the queries ran. results[command] is
--                { ok = bool, out = {lines} } for each query. Returns commands
--                to run in response (teleports, kills, ...).
--
-- ctx.state is a table kept between ticks for this feature and region,
-- ctx.now the current time in seconds, and ctx.log(text) prints to controld's
-- screen. Features with neither queries nor act don't need controld at all.
--
-- This module also holds helpers features share (exemptions, selectors, ...).

local cmd = require("cmd")

local M = {}

local STORE = "ccregion:store"

--- Players with this tag are exempt from every region feature.
M.EXEMPT_TAG = "ccregion_exempt"

---------------------------------------------------------------------------
-- Store.

local function decode(json)
  local ok, value = pcall(textutils.unserialiseJSON, json)
  if ok and type(value) == "table" then return value end
end

-- Normalize a decoded region (JSON arrays/objects come back as tables).
local function normalize(r)
  r.features = type(r.features) == "table" and r.features or {}
  for name, settings in pairs(r.features) do
    if type(settings) ~= "table" then r.features[name] = {} end
  end
  return r
end

--- All regions, as a name -> region table.
function M.all()
  local ok, out = commands.exec("data get storage " .. STORE .. " regions")
  local result = {}
  if not ok then return result end
  for name, json in pairs(cmd.parseStringCompound(out)) do
    local r = decode(json)
    if r then result[name] = normalize(r) end
  end
  return result
end

--- One region by name, or nil.
function M.get(name)
  return M.all()[name]
end

-- Mark the store as changed, so controld reloads it.
local function bump()
  commands.exec(string.format('data modify storage %s version set value "%d-%d"',
    STORE, os.epoch("utc"), math.random(0, 999999)))
end

--- Opaque value that changes whenever the store changes.
function M.version()
  local _, out = commands.exec("data get storage " .. STORE .. " version")
  return cmd.parseStoredString(out)
end

--- Save (create or replace) a region.
function M.save(region)
  local json = textutils.serialiseJSON(region)
  local ok, out = commands.exec(string.format('data modify storage %s regions."%s" set value %s',
    STORE, region.name, cmd.snbtQuote(json)))
  if not ok then return false, out and out[1] end
  bump()
  return true
end

--- Delete a region from the store (features must be disabled first).
function M.delete(name)
  commands.exec(string.format('data remove storage %s regions."%s"', STORE, name))
  bump()
end

---------------------------------------------------------------------------
-- Helpers for features.

--- Outer bounds of a region's area: X0, Y0, Z0, X1, Y1, Z1 (max + 1).
function M.bounds(region)
  local a = region.area
  return a[1], a[2], a[3], a[4] + 1, a[5] + 1, a[6] + 1
end

--- Whether a position (a player's feet) is inside the region.
function M.contains(region, x, y, z)
  local X0, Y0, Z0, X1, Y1, Z1 = M.bounds(region)
  return x >= X0 and x <= X1 and y >= Y0 and y <= Y1 and z >= Z0 and z <= Z1
end

--- Selector arguments matching entities whose hitbox touches the region,
-- e.g. "x=0,y=60,z=0,dx=50,dy=40,dz=50".
function M.volume(region)
  local a = region.area
  return string.format("x=%d,y=%d,z=%d,dx=%d,dy=%d,dz=%d",
    a[1], a[2], a[3], a[4] - a[1], a[5] - a[2], a[6] - a[3])
end

--- Command printing the positions of living players matching `filter`
-- (extra selector arguments, without a leading comma) whose hitbox touches
-- the region. Parse the output with cmd.parsePositions. Features using the
-- same filter share one query per tick.
function M.positionsQuery(region, filter)
  return string.format("execute in %s as @e[type=minecraft:player,%s%s] run data get entity @s Pos",
    region.dim, M.volume(region), filter ~= "" and ("," .. filter) or "")
end

--- Option specs for gamemode exemptions, for features to include in their
-- options. Both creative and spectator are exempt by default.
function M.exemptOptions()
  return {
    { name = "exempt-creative", default = true, desc = "Also affect creative",
      hint = "Leave players in creative mode alone." },
    { name = "exempt-spectator", default = true, desc = "Also affect spectators",
      hint = "Leave players in spectator mode alone." },
  }
end

--- The gamemodes exempt under a feature's settings.
function M.exemptModes(settings)
  local modes = {}
  if settings["exempt-creative"] ~= false then modes[#modes + 1] = "creative" end
  if settings["exempt-spectator"] ~= false then modes[#modes + 1] = "spectator" end
  return modes
end

--- Selector arguments (no leading comma) excluding exempt players.
function M.notExempt(settings)
  local parts = { "tag=!" .. M.EXEMPT_TAG }
  for _, m in ipairs(M.exemptModes(settings)) do parts[#parts + 1] = "gamemode=!" .. m end
  return table.concat(parts, ",")
end

--- Load a feature module by name. Returns the module, or nil and an error.
function M.feature(name)
  if not name:match("^[%w_%-]+$") then return nil, "Bad feature name: " .. name end
  local ok, mod = pcall(require, "features." .. name)
  if not ok then return nil, "Unknown feature: " .. name end
  return mod
end

--- Names of all installed features.
function M.featureNames()
  local names = {}
  if fs.isDir("/lib/features") then
    for _, f in ipairs(fs.list("/lib/features")) do
      local n = f:match("^(.+)%.lua$")
      if n then names[#names + 1] = n end
    end
  end
  table.sort(names)
  return names
end

return M
