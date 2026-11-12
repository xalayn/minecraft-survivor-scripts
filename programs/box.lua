-- box: draw a visual-only box between two corners.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- The box is made of display entities: no collision, no real blocks placed.
-- Boxes are recorded in command storage (ccbox:registry, saved with the world),
-- including which chunks their entities are in. Drawing and removing briefly
-- forceload those chunks (at most a few per box, at its corners), so boxes can
-- be drawn anywhere in the computer's dimension, and listed and removed from
-- any command computer regardless of where they are.
--
-- Usage:
--   box <x1> <y1> <z1> <x2> <y2> <z2> [block] [name] [options]
--   box list
--   box remove <name>
--   box clear [-y]
--
--   x1..z2  Corner coordinates. Accept ~ / ~5 relative to this computer.
--           The box fully encloses both corner blocks.
--   block   Block to draw edges with (default: lime_concrete).
--   name    Box name. Drawing again with the same name replaces that box.
--           Without a name, the box gets the first free name box1, box2, ...
--   list    Show all boxes, with their corners and size.
--   remove  Remove the box with that name.
--   clear   Remove all boxes. Asks for confirmation first.
--
-- Options (may appear anywhere after `box`):
--   -y, --yes             clear: don't ask for confirmation.
--   --name <name>         Same as the name argument, without having to give a block.
--   --no-walls            Only draw the edges, no translucent walls.
--   --opacity <0-100>     Wall opacity in percent (default: 20). Values below
--                         ~10 may not render at all.
--   --wall-color <color>  Wall color: a dye name (red, light_blue, ...) or hex
--                         RRGGBB. Default: the edge block's dye color, or white.
--   --xray                Make the edges visible through blocks. Uses the
--                         glowing outline effect, so the edges also get an
--                         outline when not obstructed. Shader packs may not
--                         render it.
--
-- Examples:
--   box 100 64 200 110 70 210
--   box ~ ~ ~ ~10 ~5 ~10 red_concrete spawn --xray
--   box ~ ~ ~ ~4 ~4 ~4 --opacity 40 --wall-color 00ffff
--   box ~ ~ ~ ~4 ~4 ~4 --no-walls --name shed
--   box list
--   box remove spawn
--   box clear
--
-- The drawing itself lives in /lib/boxdraw.lua, shared with the region
-- program's draw feature.

package.path = "/lib/?.lua;" .. package.path
local argparse = require("args")
local cmd = require("cmd")
local boxdraw = require("boxdraw")

if not commands then
  printError("box requires a Command Computer")
  return
end

local OPTIONS = {
  { name = "yes", short = "y", desc = "clear: don't ask" },
  { name = "name", type = "string", desc = "Box name" },
  { name = "walls", default = true, desc = "No walls" },
  { name = "opacity", type = "number", default = boxdraw.DEFAULT_OPACITY, min = 0, max = 100,
    arg = "<0-100>", desc = "Wall opacity %" },
  { name = "wall-color", type = "string", arg = "<color>", desc = "Dye name or RRGGBB" },
  { name = "xray", desc = "Edges visible through blocks" },
}

local function usage()
  print("Usage:")
  print("  box <x1> <y1> <z1> <x2> <y2> <z2> [block] [name]")
  print("  box list")
  print("  box remove <name>")
  print("  box clear [-y]")
  print("Coords accept ~ for relative to this computer.")
  print("Options:")
  for _, line in ipairs(argparse.help(OPTIONS)) do print(line) end
end

local args, opts = argparse.parse(OPTIONS, { ... })
if not args then
  printError(opts)
  usage()
  return
end

local function list()
  local boxes, names = boxdraw.all(), {}
  for name in pairs(boxes) do names[#names + 1] = name end
  if #names == 0 then
    print("No boxes.")
    return
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local e = boxes[name]
    local f, t = e.from, e.to
    print(string.format("%s  %d,%d,%d -> %d,%d,%d  (%dx%dx%d) %s", name,
      f[1], f[2], f[3], t[1], t[2], t[3],
      t[1] - f[1] + 1, t[2] - f[2] + 1, t[3] - f[3] + 1,
      (e.dim:gsub("^minecraft:", ""))))
  end
end

if args[1] == "list" then
  list()
  return
elseif args[1] == "remove" then
  if not args[2] then
    printError("Usage: box remove <name>")
    return
  end
  local name = cmd.sanitize(args[2])
  if not boxdraw.remove(name) then printError("No box named '" .. name .. "'") end
  return
elseif args[1] == "clear" then
  if not opts.yes then
    write("Remove ALL boxes? [y/N] ")
    local answer = (read() or ""):lower()
    if answer ~= "y" and answer ~= "yes" then
      print("Cancelled.")
      return
    end
  end
  print(string.format("Removed %d registered box(es)", boxdraw.clear()))
  return
end

if #args < 6 then
  usage()
  return
end

local area, err = cmd.parseArea(args, 1)
if not area then
  printError(err)
  usage()
  return
end

local givenName = opts.name or args[8]
local name = givenName and cmd.sanitize(givenName) or boxdraw.nextFreeName()

local ok, msg = boxdraw.draw(name, area, {
  block = args[7],
  walls = opts.walls,
  opacity = opts.opacity,
  wallColor = opts["wall-color"],
  xray = opts.xray,
})
if ok then print(msg) else printError(msg) end
