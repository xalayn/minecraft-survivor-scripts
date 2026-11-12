-- boundary: keep players inside an area.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- Any player whose feet are inside the area is confined to it: players outside
-- are unaffected, but once they enter they can't leave. A player who crosses
-- the edge (walking, flying, ender pearls, changing dimension, respawning
-- elsewhere) is teleported back to the nearest point just inside it.
--
-- Runs until stopped with Ctrl+T, which releases everyone (and removes the
-- drawing, if any). Use `bg boundary ...` to keep the shell usable meanwhile.
--
-- Exempt players are never confined, and lose their confinement as soon as
-- they become exempt: creative and spectator players (by default), and anyone
-- with the tag ccbound_exempt. To free yourself if you get stuck, run
--   /tag @s add ccbound_exempt
-- and later /tag @s remove ccbound_exempt once you're out.
--
-- Usage:
--   boundary <x1> <y1> <z1> <x2> <y2> <z2> [name] [options]
--
--   x1..z2  Corner coordinates. Accept ~ / ~5 relative to this computer.
--           The area includes both corner blocks.
--   name    Boundary name (default: "boundary"). Run several boundaries at
--           once by giving them different names.
--
-- Options:
--   --draw            Draw the boundary with the box program while active.
--   --block <block>   Edge block for the drawing (default: red_concrete).
--   --xray            Make the drawing's edges visible through blocks.
--   --no-exempt-creative   Confine creative players too.
--   --no-exempt-spectator  Confine spectators too.
--
-- Examples:
--   boundary ~-10 ~ ~-10 ~10 ~20 ~10 --draw
--   bg boundary 0 60 0 50 100 50 arena --draw --block orange_concrete

package.path = "/lib/?.lua;" .. package.path
local argparse = require("args")
local cmd = require("cmd")

if not commands then
  printError("boundary requires a Command Computer")
  return
end

local OPTIONS = {
  { name = "draw", desc = "Draw it with box" },
  { name = "block", type = "string", default = "red_concrete", arg = "<block>", desc = "Drawing edge block" },
  { name = "xray", desc = "Drawing visible through blocks" },
  { name = "exempt-creative", default = true, desc = "Confine creative too" },
  { name = "exempt-spectator", default = true, desc = "Confine spectators too" },
}

local EXEMPT_TAG = "ccbound_exempt"

local function usage()
  print("Usage:")
  print("  boundary <x1> <y1> <z1> <x2> <y2> <z2> [name]")
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

local area, err = cmd.parseArea(args, 1)
if not area then
  printError(err)
  usage()
  return
end

local name = cmd.sanitize(args[7] or "boundary")
local TAG = "ccbound_" .. name
local BOX_NAME = "boundary_" .. name
local dim = cmd.dimension()

-- Inclusive block corners -> outer bounds of the area.
local bx0, by0, bz0, bx1, by1, bz1 = table.unpack(area)
local X0, Y0, Z0 = bx0, by0, bz0
local X1, Y1, Z1 = bx1 + 1, by1 + 1, bz1 + 1

local HALF_WIDTH = 0.3 -- player hitbox half-width
local HEIGHT = 1.8     -- player hitbox height

local function inside(x, y, z)
  return x >= X0 and x <= X1 and y >= Y0 and y <= Y1 and z >= Z0 and z <= Z1
end

local function clamp(v, lo, hi)
  if hi < lo then return (lo + hi) / 2 end
  return math.max(lo, math.min(hi, v))
end

-- Nearest position inside the area where the player's whole hitbox fits.
local function pullBack(x, y, z)
  return clamp(x, X0 + HALF_WIDTH, X1 - HALF_WIDTH),
    clamp(y, Y0, math.max(Y0, Y1 - HEIGHT)),
    clamp(z, Z0 + HALF_WIDTH, Z1 - HALF_WIDTH)
end

-- Parse `data get entity <player> Pos` output lines into { name, x, y, z }.
local function parsePositions(lines)
  local players = {}
  for _, line in ipairs(lines) do
    local player, list = line:match("^(%S+) has the following entity data: %[(.-)%]")
    if player then
      local v = {}
      for n in list:gmatch("%-?[%d%.]+[eE]?[%-+]?%d*") do v[#v + 1] = tonumber(n) end
      if #v == 3 then players[#players + 1] = { name = player, x = v[1], y = v[2], z = v[3] } end
    end
  end
  return players
end

local cx, cz = (X0 + X1) / 2, (Z0 + Z1) / 2

-- Selector filter excluding exempt players, and the gamemodes that are exempt.
local exemptModes = {}
if opts["exempt-creative"] then exemptModes[#exemptModes + 1] = "creative" end
if opts["exempt-spectator"] then exemptModes[#exemptModes + 1] = "spectator" end
local NOT_EXEMPT = ",tag=!" .. EXEMPT_TAG
for _, m in ipairs(exemptModes) do NOT_EXEMPT = NOT_EXEMPT .. ",gamemode=!" .. m end

-- Commands run every tick. The first two must stay first: their output is read.
local QUERIES = {
  -- Positions of confined players in this dimension.
  string.format("execute in %s as @a[tag=%s,distance=0..%s] run data get entity @s Pos",
    dim, TAG, NOT_EXEMPT),
  -- Positions of unconfined players near the area (hitbox touching it), to
  -- confine the ones whose feet are inside.
  string.format("execute in %s as @a[tag=!%s,x=%d,y=%d,z=%d,dx=%d,dy=%d,dz=%d%s] run data get entity @s Pos",
    dim, TAG, X0, Y0, Z0, bx1 - bx0, by1 - by0, bz1 - bz0, NOT_EXEMPT),
  -- Confined players who left the dimension go back to the middle of the floor.
  string.format("execute as @a[tag=%s%s] at @s unless dimension %s in %s run tp @s %.2f %d %.2f",
    TAG, NOT_EXEMPT, dim, dim, cx, Y0, cz),
  -- Players who became exempt are released.
  string.format("tag @a[tag=%s,tag=%s] remove %s", TAG, EXEMPT_TAG, TAG),
}
for _, m in ipairs(exemptModes) do
  QUERIES[#QUERIES + 1] = string.format("tag @a[tag=%s,gamemode=%s] remove %s", TAG, m, TAG)
end

local function tick()
  local results = cmd.execAll(QUERIES)
  local actions = {}
  for _, p in ipairs(parsePositions(results[1].out)) do
    if not inside(p.x, p.y, p.z) then
      local x, y, z = pullBack(p.x, p.y, p.z)
      actions[#actions + 1] = string.format("execute in %s run tp %s %.3f %.3f %.3f", dim, p.name, x, y, z)
    end
  end
  for _, p in ipairs(parsePositions(results[2].out)) do
    if inside(p.x, p.y, p.z) then
      actions[#actions + 1] = string.format("tag %s add %s", p.name, TAG)
      print("Confined " .. p.name)
    end
  end
  if #actions > 0 then cmd.execAll(actions) end
end

local function cleanup()
  commands.exec("tag @a remove " .. TAG)
  if opts.draw then shell.run("box", "remove", BOX_NAME) end
end

if opts.draw then
  local boxArgs = { bx0, by0, bz0, bx1, by1, bz1, opts.block, "--name", BOX_NAME }
  if opts.xray then boxArgs[#boxArgs + 1] = "--xray" end
  shell.run("box", table.unpack(boxArgs))
end

print(string.format("Boundary '%s' active: %d,%d,%d -> %d,%d,%d (%s)", name,
  bx0, by0, bz0, bx1, by1, bz1, dim))
print("Ctrl+T to stop.")

local ok, loopErr = pcall(function()
  while true do tick() end
end)

cleanup()
if ok or loopErr == "Terminated" then
  print("Boundary '" .. name .. "' stopped; players released.")
else
  printError(loopErr)
end
