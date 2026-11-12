-- region: manage regions, named areas with features attached.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- Regions are stored in the world (command storage), so any command computer
-- can manage them; pocket computers can too, through the regionui app.
-- Features that act continuously (boundary, killzone) are enforced by
-- regiond, which must be running on one computer.
--
-- Usage:
--   region create <name> <x1> <y1> <z1> <x2> <y2> <z2>
--   region add <name> <feature> [feature options]
--   region remove <name> <feature>
--   region delete <name> [-y]
--   region list
--   region info <name>
--   region features [feature]
--
--   create    Define a region in this computer's dimension. Coords accept
--             ~ / ~5 relative to this computer; both corner blocks are included.
--   add       Attach a feature, or change its options if already attached.
--   remove    Detach a feature, undoing its effects.
--   delete    Detach all features and delete the region. Asks first unless -y.
--   features  List available features, or one feature's options.
--
-- Features (see `region features`):
--   draw      Show the region as a box.
--   boundary  Players can't leave.
--   killzone  Kills or damages players inside.
--
-- Examples:
--   region create arena ~-20 ~ ~-20 ~20 ~30 ~20
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

if not commands then
  printError("region requires a Command Computer")
  return
end

local function usage()
  print("Usage:")
  print("  region create <name> <x1> <y1> <z1> <x2> <y2> <z2>")
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

function commandsBySub.create()
  local name = raw[2]
  if not name then return usage() end
  local area, err = cmd.parseArea(raw, 3)
  if not area then return printError(err) end
  local ok, r = regionops.create(name, { area[1], area[2], area[3] }, { area[4], area[5], area[6] })
  if not ok then return printError(r) end
  print("Created region '" .. r.name .. "': " .. describeArea(r))
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
    print("Note: regiond isn't running, so " .. fname .. " won't be enforced until it is.")
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
    print(name .. "  " .. describeArea(r))
    if #feats > 0 then print("  " .. table.concat(feats, ", ")) end
  end
end

function commandsBySub.info()
  local r = getRegion(raw[2])
  if not r then return end
  print(r.name .. "  " .. describeArea(r))
  for _, fname in ipairs(sortedKeys(r.features)) do
    local parts = {}
    for _, k in ipairs(sortedKeys(r.features[fname])) do
      parts[#parts + 1] = k .. "=" .. tostring(r.features[fname][k])
    end
    print("  " .. fname .. (#parts > 0 and (": " .. table.concat(parts, " ")) or ""))
  end
  local holder = regions.daemon()
  print(holder and ("regiond: running on " .. holder) or "regiond: not running")
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
