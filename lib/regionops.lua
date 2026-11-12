-- regionops: the operations on regions, shared by the region program (run
-- locally) and controld (on behalf of pocket computers, via the regions module).
--
-- Every function returns true and a result, or false and an error message.
-- Inputs may come from the network, so everything that ends up in a command
-- is validated here (names sanitized, feature settings checked against the
-- feature's options, player names checked).

local args = require("args")
local cmd = require("cmd")
local regions = require("regions")
local control = require("control")
local players = require("players")

local M = {}

local function findRegion(name)
  if type(name) ~= "string" or name == "" then return nil, "Missing region name" end
  local r = regions.get(cmd.sanitize(name))
  if not r then return nil, "No region named '" .. cmd.sanitize(name) .. "'" end
  return r
end

local function disable(r, fname)
  local f = regions.feature(fname)
  if f and f.disable then
    local ok, err = pcall(f.disable, r, r.features[fname] or {})
    if not ok then return tostring(err) end
  end
end

-- Copy of a feature's options that can be sent over the network (no functions).
local function plainOptions(options)
  local out = {}
  for i, o in ipairs(options or {}) do
    local c = {}
    for k, v in pairs(o) do
      if type(v) ~= "function" then c[k] = v end
    end
    out[i] = c
  end
  return out
end

--- All regions, as a name -> region table.
function M.list()
  return true, regions.all()
end

--- One region.
function M.get(name)
  local r, err = findRegion(name)
  if not r then return false, err end
  return true, r
end

--- Create a region from two corners: { x, y, z } block positions.
function M.create(name, p1, p2, dim)
  if type(name) ~= "string" or name == "" then return false, "Missing region name" end
  name = cmd.sanitize(name)
  for _, p in ipairs({ p1, p2 }) do
    if type(p) ~= "table" or type(p[1]) ~= "number" or type(p[2]) ~= "number" or type(p[3]) ~= "number" then
      return false, "Bad corner"
    end
  end
  if dim ~= nil and not cmd.lastId(dim) then return false, "Bad dimension" end
  if regions.get(name) then return false, "Region '" .. name .. "' already exists" end
  local f = math.floor
  local r = {
    name = name,
    dim = dim and cmd.lastId(dim) or cmd.dimension(),
    area = {
      math.min(f(p1[1]), f(p2[1])), math.min(f(p1[2]), f(p2[2])), math.min(f(p1[3]), f(p2[3])),
      math.max(f(p1[1]), f(p2[1])), math.max(f(p1[2]), f(p2[2])), math.max(f(p1[3]), f(p2[3])),
    },
    features = {},
  }
  local ok, err = regions.save(r)
  if not ok then return false, "Couldn't save: " .. tostring(err) end
  return true, r
end

--- Attach a feature to a region, or replace its settings. `values` is a table
-- of option values (missing ones get defaults). Returns true and
-- { message = <from the feature, or nil>, needsDaemon = bool }.
function M.setFeature(name, fname, values)
  local r, err = findRegion(name)
  if not r then return false, err end
  if type(fname) ~= "string" then return false, "Missing feature name" end
  local f, ferr = regions.feature(fname)
  if not f then return false, ferr end
  local settings, verr = args.validate(f.options or {}, values)
  if not settings then return false, verr end

  if r.features[fname] then disable(r, fname) end
  local message
  if f.enable then
    local ok, msg = f.enable(r, settings)
    if not ok then
      -- Don't record a feature whose setup failed.
      r.features[fname] = nil
      regions.save(r)
      return false, fname .. ": " .. tostring(msg)
    end
    message = msg
  end
  r.features[fname] = settings
  regions.save(r)
  return true, {
    message = message,
    needsDaemon = (f.queries or f.act) and not control.daemon() or false,
  }
end

--- Detach a feature from a region, undoing its effects.
function M.removeFeature(name, fname)
  local r, err = findRegion(name)
  if not r then return false, err end
  if not r.features[fname] then return false, "'" .. r.name .. "' has no " .. tostring(fname) .. " feature" end
  local derr = disable(r, fname)
  r.features[fname] = nil
  regions.save(r)
  if derr then return false, fname .. ": " .. derr end
  return true
end

--- Detach all features and delete a region.
function M.delete(name)
  local r, err = findRegion(name)
  if not r then return false, err end
  for fname in pairs(r.features) do disable(r, fname) end
  regions.delete(r.name)
  return true
end

--- Available features: a list of { name, description, options, continuous }.
function M.features()
  local list = {}
  for _, name in ipairs(regions.featureNames()) do
    local f = regions.feature(name)
    if f then
      list[#list + 1] = {
        name = name,
        description = f.description,
        options = plainOptions(f.options),
        continuous = (f.queries or f.act) and true or false,
      }
    end
  end
  return true, list
end

local validPlayer, exactPos = players.valid, players.exactPos

--- Names of the regions a player is standing in (sorted; empty if none).
function M.regionsAt(player)
  local p, err = exactPos(player)
  if not p then return false, err end
  local names = {}
  for name, r in pairs(regions.all()) do
    if r.dim == p.dim and regions.contains(r, p.x, p.y, p.z) then names[#names + 1] = name end
  end
  table.sort(names)
  return true, names
end

--- Teleport a player to the middle of a region's floor. Returns the
-- destination { x, y, z, dim }.
function M.teleport(player, name)
  if not validPlayer(player) then return false, "Bad player name" end
  local r, err = findRegion(name)
  if not r then return false, err end
  local a = r.area
  local x, y, z = (a[1] + a[4] + 1) / 2, a[2], (a[3] + a[6] + 1) / 2
  local ok, out = commands.exec(string.format("execute in %s run tp %s %.1f %d %.1f", r.dim, player, x, y, z))
  if not ok then return false, (out and out[1]) or "Teleport failed" end
  return true, { x, y, z, dim = r.dim }
end

--- Who runs controld, or nil.
function M.status()
  return true, { daemon = control.daemon() }
end

return M
