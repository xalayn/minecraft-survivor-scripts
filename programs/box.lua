-- box: draw a visual-only box outline between two corners.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- The outline is made of thin block_display entities: no collision, no real
-- blocks placed. The area must be loaded for the entities to be summoned.
--
-- Usage:
--   box <x1> <y1> <z1> <x2> <y2> <z2> [block] [name]
--   box clear [name]
--
--   x1..z2  Corner coordinates. Accept ~ / ~5 relative to this computer.
--           The box fully encloses both corner blocks.
--   block   Block to draw edges with (default: lime_stained_glass).
--   name    Box name (default: "default"). Drawing again with the same name
--           replaces that box.
--   clear   Remove the named box, or all boxes if no name is given.
--
-- Examples:
--   box 100 64 200 110 70 210
--   box ~ ~ ~ ~10 ~5 ~10 red_stained_glass spawn
--   box clear spawn

if not commands then
  printError("box requires a Command Computer")
  return
end

local THICKNESS = 0.0625 -- edge thickness in blocks (1 pixel)
local BASE_TAG = "ccbox"

local args = { ... }

local function usage()
  print("Usage:")
  print("  box <x1> <y1> <z1> <x2> <y2> <z2> [block] [name]")
  print("  box clear [name]")
  print("Coords accept ~ for relative to this computer.")
end

local function tagFor(name)
  -- Entity tags can't contain spaces or most punctuation.
  return BASE_TAG .. "_" .. name:gsub("[^%w_%-%.%+]", "_")
end

local function run(cmd)
  local ok, out = commands.exec(cmd)
  if not ok then
    printError(cmd)
    for _, line in ipairs(out or {}) do printError("  " .. line) end
  end
  return ok
end

local function clear(name)
  local tag = name and tagFor(name) or BASE_TAG
  local ok, out = commands.exec("kill @e[type=minecraft:block_display,tag=" .. tag .. "]")
  print(ok and (out[1] or "Cleared") or ("Nothing to clear (" .. (out[1] or "?") .. ")"))
end

if args[1] == "clear" then
  clear(args[2])
  return
end

if #args < 6 then
  usage()
  return
end

local cx, cy, cz = commands.getBlockPosition()
local origin = { cx, cy, cz }

local function parseCoord(s, axis)
  local rel = s:match("^~(.*)$")
  if rel then
    local off = rel == "" and 0 or tonumber(rel)
    if not off then error("Bad coordinate: " .. s, 0) end
    return math.floor(origin[axis] + off)
  end
  local n = tonumber(s)
  if not n then error("Bad coordinate: " .. s, 0) end
  return math.floor(n)
end

local ok, err = pcall(function()
  for i = 1, 6 do args[i] = parseCoord(args[i], (i - 1) % 3 + 1) end
end)
if not ok then
  printError(err)
  usage()
  return
end

local block = args[7] or "minecraft:lime_stained_glass"
if not block:find(":") then block = "minecraft:" .. block end
local name = args[8] or "default"

-- Outer bounds: min corner to max corner + 1 so both corner blocks are enclosed.
local x0, x1 = math.min(args[1], args[4]), math.max(args[1], args[4]) + 1
local y0, y1 = math.min(args[2], args[5]), math.max(args[2], args[5]) + 1
local z0, z1 = math.min(args[3], args[6]), math.max(args[3], args[6]) + 1
local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
local t = THICKNESS

local tags = string.format('Tags:["%s","%s"]', BASE_TAG, tagFor(name))

local function edge(x, y, z, sx, sy, sz)
  return string.format(
    "summon minecraft:block_display %.4f %.4f %.4f {block_state:{Name:\"%s\"},"
      .. "transformation:{left_rotation:[0f,0f,0f,1f],right_rotation:[0f,0f,0f,1f],"
      .. "translation:[0f,0f,0f],scale:[%.4ff,%.4ff,%.4ff]},"
      .. "brightness:{sky:15,block:15},%s}",
    x, y, z, block, sx, sy, sz, tags)
end

-- Redrawing a box with the same name replaces it.
commands.exec("kill @e[type=minecraft:block_display,tag=" .. tagFor(name) .. "]")

local edges = {}
for _, a in ipairs({ y0, y1 - t }) do
  for _, b in ipairs({ z0, z1 - t }) do
    edges[#edges + 1] = edge(x0, a, b, dx, t, t) -- along X
  end
end
for _, a in ipairs({ x0, x1 - t }) do
  for _, b in ipairs({ z0, z1 - t }) do
    edges[#edges + 1] = edge(a, y0, b, t, dy, t) -- along Y
  end
end
for _, a in ipairs({ x0, x1 - t }) do
  for _, b in ipairs({ y0, y1 - t }) do
    edges[#edges + 1] = edge(a, b, z0, t, t, dz) -- along Z
  end
end

local failed = 0
for _, cmd in ipairs(edges) do
  if not run(cmd) then failed = failed + 1 end
end

if failed == 0 then
  print(string.format("Box '%s' drawn: %dx%dx%d (%s)", name, dx, dy, dz, block))
else
  printError(string.format("%d/%d edges failed (is the area loaded?)", failed, #edges))
end
