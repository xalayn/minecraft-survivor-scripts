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
local shapes = require("shapes")

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

--- Create a region from a shape (see lib/shapes.lua), in a dimension
-- (default: the computer's).
function M.create(name, shape, dim)
  if type(name) ~= "string" or name == "" then return false, "Missing region name" end
  name = cmd.sanitize(name)
  local s, serr = shapes.check(shape)
  if not s then return false, serr end
  if dim ~= nil and not cmd.lastId(dim) then return false, "Bad dimension" end
  if regions.get(name) then return false, "Region '" .. name .. "' already exists" end
  local r = {
    name = name,
    dim = dim and cmd.lastId(dim) or cmd.dimension(),
    shapes = { s },
    features = {},
  }
  regions.updateArea(r)
  local ok, err = regions.save(r)
  if not ok then return false, "Couldn't save: " .. tostring(err) end
  return true, r
end

-- After a region's shapes change: save it and redo features that set
-- something up (e.g. redraw its drawing). Returns true and the region, or
-- false and an error.
local function reshaped(r)
  regions.updateArea(r)
  local ok, err = regions.save(r)
  if not ok then return false, "Couldn't save: " .. tostring(err) end
  local problems = {}
  for fname, settings in pairs(r.features) do
    local f = regions.feature(fname)
    if f and f.enable then
      if f.disable then pcall(f.disable, r, settings) end
      local eok, emsg = f.enable(r, settings)
      if not eok then problems[#problems + 1] = fname .. ": " .. tostring(emsg) end
    end
  end
  if #problems > 0 then return false, table.concat(problems, "; ") end
  return true, r
end

--- Add a shape to a region (the region becomes all its shapes together).
function M.addShape(name, shape)
  local r, err = findRegion(name)
  if not r then return false, err end
  local s, serr = shapes.check(shape)
  if not s then return false, serr end
  r.shapes[#r.shapes + 1] = s
  return reshaped(r)
end

--- Remove a region's shape by its number (1 = first). A region keeps at
-- least one shape.
function M.removeShape(name, index)
  local r, err = findRegion(name)
  if not r then return false, err end
  index = tonumber(index)
  if not index or not r.shapes[index] then return false, "No shape number " .. tostring(index) end
  if #r.shapes == 1 then return false, "A region needs at least one shape" end
  table.remove(r.shapes, index)
  return reshaped(r)
end

--- Shape types: a list of { name, description, usage, steps }.
function M.shapeTypes()
  local list = {}
  for _, n in ipairs(shapes.typeNames()) do
    local t = shapes.type(n)
    if t then list[#list + 1] = { name = n, description = t.description, usage = t.usage, steps = t.steps } end
  end
  return true, list
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
  local x, y, z = regions.spawn(r)
  local ok, out = commands.exec(string.format("execute in %s run tp %s %.2f %.2f %.2f", r.dim, player, x, y, z))
  if not ok then return false, (out and out[1]) or "Teleport failed" end
  return true, { x, y, z, dim = r.dim }
end

--- Who runs controld, or nil.
function M.status()
  return true, { daemon = control.daemon() }
end

return M
