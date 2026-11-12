-- region: manage regions, named areas with features attached.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- Regions are stored in the world (command storage), so any command computer
-- can manage them; pocket computers can too, through the control app.
-- Features that act continuously (boundary, killzone) are enforced by
-- controld, which must be running on one computer.
--
-- Usage:
--   region create <name> <x1> <y1> <z1> <x2> <y2> <z2>
--   region create <name> <shape> <shape args...>
--   region shape add <name> <shape> <shape args...>
--   region shape remove <name> <number>
--   region add <name> <feature> [feature options]
--   region remove <name> <feature>
--   region delete <name> [-y]
--   region list
--   region info <name>
--   region features [feature]
--
--   create    Define a region in this computer's dimension, with one shape:
--             6 coordinates for a box, or a shape type and its arguments.
--             Coordinates accept ~ / ~5 relative to this computer; a box
--             includes both corner blocks.
--   shape     Add another shape to a region (it becomes all its shapes
--             together), or remove one by its number (see region info).
--   add       Attach a feature, or change its options if already attached.
--   remove    Detach a feature, undoing its effects.
--   delete    Detach all features and delete the region. Asks first unless -y.
--   features  List available features, or one feature's options.
--
-- Shapes:
--   box       <x1> <y1> <z1> <x2> <y2> <z2>     two opposite corner blocks
--   sphere    <x> <y> <z> <radius>              around a center block
--   cylinder  <x> <y> <z> <radius> <height>     upright, on a center block
--
-- Features (see `region features`):
--   draw      Show the region's shapes.
--   boundary  Players can't leave.
--   killzone  Kills or damages players inside.
--
-- Examples:
--   region create arena ~-20 ~ ~-20 ~20 ~30 ~20
--   region create dome sphere ~ ~ ~ 15
--   region shape add arena cylinder ~30 ~ ~ 8 20
--   region add arena draw --block red_concrete --xray
--   region add arena boundary
--   region add arena killzone --delay 5 --damage 4 --interval 2
--   region remove arena killzone
--   region delete arena

package.path = "/lib/?.lua;" .. package.path
local argparse = require("args")
local cmd = require("cmd")
local regions = require("regions")
local regionops = require("regionops")
local shapes = require("shapes")
local control = require("control")
local predicate = require("predicate")

if not commands then
  printError("region requires a Command Computer")
  return
end

local function usage()
  print("Usage:")
  print("  region create <name> <x1> <y1> <z1> <x2> <y2> <z2>")
  print("  region create <name> <shape> <args...>")
  print("  region shape add <name> <shape> <args...>")
  print("  region shape remove <name> <number>")
  print("  region add <name> <feature> [options]")
  print("  region remove <name> <feature>")
  print("  region delete <name> [-y]")
  print("  region list")
  print("  region info <name>")
  print("  region features [feature]")
end

local raw = { ... }
local sub = raw[1]

local function rest(from)
  local r = {}
  for i = from, #raw do r[#r + 1] = raw[i] end
  return r
end

local function getRegion(name)
  if not name then
    printError("Missing region name")
    return nil
  end
  local r = regions.get(cmd.sanitize(name))
  if not r then printError("No region named '" .. cmd.sanitize(name) .. "'") end
  return r
end

local function dimName(dim)
  return (dim:gsub("^minecraft:", ""))
end

local function describeArea(r)
  local a = r.area
  return string.format("%d,%d,%d -> %d,%d,%d (%dx%dx%d) %s", a[1], a[2], a[3], a[4], a[5], a[6],
    a[4] - a[1] + 1, a[5] - a[2] + 1, a[6] - a[3] + 1, (r.dim:gsub("^minecraft:", "")))
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function confirm(question)
  write(question .. " [y/N] ")
  local answer = (read() or ""):lower()
  return answer == "y" or answer == "yes"
end

local commandsBySub = {}

-- Parse a shape from raw[from..]: "<shape type> <args...>", or just 6
-- coordinates for a box. Returns the shape, or nil and an error.
local function shapeFrom(from)
  local typeName = raw[from]
  local args = rest(from + 1)
  if typeName and (tonumber(typeName) or typeName:sub(1, 1) == "~") then
    typeName, args = "box", rest(from)
  end
  if not typeName then return nil, "Missing shape" end
  local t, err = shapes.type(typeName)
  if not t then return nil, err .. " (shapes: " .. table.concat(shapes.typeNames(), ", ") .. ")" end
  local shape, serr = t.fromArgs(args, cmd.parseCoord)
  if not shape then return nil, serr end
  shape.type = typeName
  return shape
end

function commandsBySub.create()
  local name = raw[2]
  if not name then return usage() end
  local shape, err = shapeFrom(3)
  if not shape then return printError(err) end
  local ok, r = regionops.create(name, shape)
  if not ok then return printError(r) end
  print("Created region '" .. r.name .. "': " .. shapes.describe(r.shapes[1]) .. " in " .. dimName(r.dim))
end

function commandsBySub.shape()
  local action, name = raw[2], raw[3]
  if action == "add" and name then
    local shape, err = shapeFrom(4)
    if not shape then return printError(err) end
    local ok, r = regionops.addShape(name, shape)
    if not ok then return printError(r) end
    print("Added " .. shapes.describe(shape) .. " to '" .. r.name .. "' (now " .. #r.shapes .. " shapes)")
  elseif action == "remove" and name and raw[4] then
    local ok, r = regionops.removeShape(name, raw[4])
    if not ok then return printError(r) end
    print("Removed shape " .. raw[4] .. " from '" .. r.name .. "'")
  else
    printError("Usage: region shape add <name> <shape> <args...>")
    printError("       region shape remove <name> <number>")
    for _, n in ipairs(shapes.typeNames()) do
      local t = shapes.type(n)
      if t then print("  " .. n .. " " .. t.usage) end
    end
  end
end

function commandsBySub.add()
  local name, fname = raw[2], raw[3]
  if not name or not fname then return printError("Usage: region add <name> <feature> [options]") end
  local f, ferr = regions.feature(fname)
  if not f then return printError(ferr) end

  local pos, settings = argparse.parse(f.options or {}, rest(4))
  if not pos then
    printError(settings)
    print("Options for " .. fname .. ":")
    for _, line in ipairs(argparse.help(f.options or {})) do print(line) end
    return
  end
  if #pos > 0 then return printError("Unexpected argument: " .. pos[1]) end

  local ok, result = regionops.setFeature(name, fname, settings)
  if not ok then return printError(result) end
  if result.message then print(result.message) end
  print("Added " .. fname .. " to '" .. cmd.sanitize(name) .. "'")
  if result.needsDaemon then
    print("Note: controld isn't running, so " .. fname .. " won't be enforced until it is.")
  end
end

function commandsBySub.remove()
  local name, fname = raw[2], raw[3]
  if not name or not fname then return printError("Usage: region remove <name> <feature>") end
  local ok, err = regionops.removeFeature(name, fname)
  if not ok then return printError(err) end
  print("Removed " .. fname .. " from '" .. cmd.sanitize(name) .. "'")
end

function commandsBySub.delete()
  local pos, opts = argparse.parse({ { name = "yes", short = "y" } }, rest(2))
  if not pos then return printError(opts) end
  local r = getRegion(pos[1])
  if not r then return end
  if not opts.yes and not confirm("Delete region '" .. r.name .. "' and all its features?") then
    return print("Cancelled.")
  end
  local ok, err = regionops.delete(r.name)
  if not ok then return printError(err) end
  print("Deleted region '" .. r.name .. "'")
end

function commandsBySub.list()
  local _, all = regionops.list()
  local names = sortedKeys(all)
  if #names == 0 then return print("No regions.") end
  for _, name in ipairs(names) do
    local r = all[name]
    local feats = sortedKeys(r.features)
    print(name .. "  " .. describeArea(r) .. (#r.shapes > 1 and (", " .. #r.shapes .. " shapes") or ""))
    if #feats > 0 then print("  " .. table.concat(feats, ", ")) end
  end
end

function commandsBySub.info()
  local r = getRegion(raw[2])
  if not r then return end
  print(r.name .. "  " .. describeArea(r))
  for i, s in ipairs(r.shapes) do print(string.format("  shape %d: %s", i, shapes.describe(s))) end
  for _, fname in ipairs(sortedKeys(r.features)) do
    local parts = {}
    for _, k in ipairs(sortedKeys(r.features[fname])) do
      local v = r.features[fname][k]
      if type(v) == "table" then v = "\"" .. predicate.toText(v) .. "\"" end
      parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    print("  " .. fname .. (#parts > 0 and (": " .. table.concat(parts, " ")) or ""))
  end
  local holder = control.daemon()
  print(holder and ("controld: running on " .. holder) or "controld: not running")
end

function commandsBySub.features()
  if raw[2] then
    local f, err = regions.feature(raw[2])
    if not f then return printError(err) end
    print(raw[2] .. ": " .. (f.description or ""))
    for _, line in ipairs(argparse.help(f.options or {})) do print(line) end
    return
  end
  local _, list = regionops.features()
  for _, f in ipairs(list) do
    print(string.format("%-9s %s", f.name, f.description or ""))
  end
end

local handler = sub and commandsBySub[sub]
if not handler then
  if sub then printError("Unknown command: " .. sub) end
  usage()
  return
end
handler()
