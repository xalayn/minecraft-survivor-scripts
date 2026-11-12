-- region: manage regions, named areas with features attached.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- Regions are stored in the world (command storage), so any command computer
-- can manage them. Features that act continuously (boundary, killzone) are
-- enforced by regiond, which must be running on one computer.
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

local function disableFeature(r, name)
  local f = regions.feature(name)
  if f and f.disable then
    local ok, err = pcall(f.disable, r, r.features[name] or {})
    if not ok then printError(name .. ": " .. tostring(err)) end
  end
end

local commandsBySub = {}

function commandsBySub.create()
  local name = raw[2] and cmd.sanitize(raw[2])
  if not name then return usage() end
  local area, err = cmd.parseArea(raw, 3)
  if not area then return printError(err) end
  if regions.get(name) then
    return printError("Region '" .. name .. "' already exists")
  end
  local r = { name = name, dim = cmd.dimension(), area = area, features = {} }
  local ok, saveErr = regions.save(r)
  if not ok then return printError("Couldn't save: " .. tostring(saveErr)) end
  print("Created region '" .. name .. "': " .. describeArea(r))
end

function commandsBySub.add()
  local r = getRegion(raw[2])
  if not r then return end
  local fname = raw[3]
  if not fname then return printError("Usage: region add <name> <feature> [options]") end
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

  if r.features[fname] then disableFeature(r, fname) end
  if f.enable then
    local ok, msg = f.enable(r, settings)
    if not ok then
      -- Don't record a feature whose setup failed.
      r.features[fname] = nil
      regions.save(r)
      return printError(fname .. ": " .. tostring(msg))
    end
    if msg then print(msg) end
  end
  r.features[fname] = settings
  regions.save(r)
  print("Added " .. fname .. " to '" .. r.name .. "'")

  if f.queries or f.act then
    local holder = regions.daemon()
    if not holder then
      print("Note: regiond isn't running, so " .. fname .. " won't be enforced until it is.")
    end
  end
end

function commandsBySub.remove()
  local r = getRegion(raw[2])
  if not r then return end
  local fname = raw[3]
  if not fname then return printError("Usage: region remove <name> <feature>") end
  if not r.features[fname] then
    return printError("'" .. r.name .. "' has no " .. fname .. " feature")
  end
  disableFeature(r, fname)
  r.features[fname] = nil
  regions.save(r)
  print("Removed " .. fname .. " from '" .. r.name .. "'")
end

function commandsBySub.delete()
  local pos, opts = argparse.parse({ { name = "yes", short = "y" } }, rest(2))
  if not pos then return printError(opts) end
  local r = getRegion(pos[1])
  if not r then return end
  if not opts.yes and not confirm("Delete region '" .. r.name .. "' and all its features?") then
    return print("Cancelled.")
  end
  for _, fname in ipairs(sortedKeys(r.features)) do disableFeature(r, fname) end
  regions.delete(r.name)
  print("Deleted region '" .. r.name .. "'")
end

function commandsBySub.list()
  local all = regions.all()
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
  for _, name in ipairs(regions.featureNames()) do
    local f = regions.feature(name)
    print(string.format("%-9s %s", name, f and f.description or "(failed to load)"))
  end
end

local handler = sub and commandsBySub[sub]
if not handler then
  if sub then printError("Unknown command: " .. sub) end
  usage()
  return
end
handler()
