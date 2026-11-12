-- box: draw a visual-only box between two corners.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- The box is made of block_display entities: no collision, no real blocks
-- placed. The area must be loaded for the entities to be summoned.
--
-- Usage:
--   box <x1> <y1> <z1> <x2> <y2> <z2> [block] [name] [options]
--   box clear [name]
--
--   x1..z2  Corner coordinates. Accept ~ / ~5 relative to this computer.
--           The box fully encloses both corner blocks.
--   block   Block to draw edges with (default: lime_concrete).
--   name    Box name (default: "default"). Drawing again with the same name
--           replaces that box.
--   clear   Remove the named box, or all boxes if no name is given.
--
-- Options (may appear anywhere after `box`):
--   --no-walls       Only draw the edges, no translucent walls.
--   --wall <block>   Block for the walls. Default: the stained glass matching
--                    the edge block's color (e.g. lime_concrete ->
--                    lime_stained_glass), or plain glass if it has no color.
--   --xray           Make the edges visible through blocks. Uses the glowing
--                    outline effect, so the edges also get an outline when
--                    not obstructed. Shader packs may not render it.
--
-- Examples:
--   box 100 64 200 110 70 210
--   box ~ ~ ~ ~10 ~5 ~10 red_concrete spawn --xray
--   box ~ ~ ~ ~4 ~4 ~4 --no-walls
--   box clear spawn

if not commands then
  printError("box requires a Command Computer")
  return
end

local THICKNESS = 0.0625     -- edge thickness in blocks (1 pixel)
local WALL_INSET = 0.01      -- walls sit this far inside the box, so they don't z-fight with blocks
local WALL_THICKNESS = 0.005
local BASE_TAG = "ccbox"

-- Vanilla dye colors (text color values), longest names first so
-- "light_blue" matches before "blue".
local COLORS = {
  { "light_blue", 0x9AC0CD }, { "light_gray", 0xD3D3D3 },
  { "magenta", 0xFF00FF }, { "orange", 0xFF681F }, { "yellow", 0xFFFF00 },
  { "purple", 0xA020F0 }, { "white", 0xFFFFFF }, { "black", 0x000000 },
  { "brown", 0x8B4513 }, { "green", 0x00FF00 }, { "gray", 0x808080 },
  { "pink", 0xFF69B4 }, { "cyan", 0x00FFFF }, { "blue", 0x0000FF },
  { "lime", 0xBFFF00 }, { "red", 0xFF0000 },
}

local function usage()
  print("Usage:")
  print("  box <x1> <y1> <z1> <x2> <y2> <z2> [block] [name]")
  print("      [--no-walls] [--wall <block>] [--xray]")
  print("  box clear [name]")
  print("Coords accept ~ for relative to this computer.")
end

-- Split flags from positional args.
local args, opts = {}, { walls = true, xray = false }
do
  local raw, i = { ... }, 1
  while i <= #raw do
    local a = raw[i]
    if a == "--no-walls" then
      opts.walls = false
    elseif a == "--xray" then
      opts.xray = true
    elseif a == "--wall" then
      i = i + 1
      opts.wallBlock = raw[i]
      if not opts.wallBlock then
        printError("--wall needs a block")
        return
      end
    elseif a:sub(1, 2) == "--" then
      printError("Unknown option: " .. a)
      usage()
      return
    else
      args[#args + 1] = a
    end
    i = i + 1
  end
end

local function tagFor(name)
  -- Entity tags can't contain spaces or most punctuation.
  return BASE_TAG .. "_" .. name:gsub("[^%w_%-%.%+]", "_")
end

local function withNamespace(block)
  return block:find(":") and block or ("minecraft:" .. block)
end

-- Returns the dye color name and RGB of a block like "minecraft:lime_concrete".
local function colorOf(block)
  local path = block:match(":(.*)$") or block
  for _, c in ipairs(COLORS) do
    if path:sub(1, #c[1] + 1) == c[1] .. "_" then return c[1], c[2] end
  end
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

local block = withNamespace(args[7] or "lime_concrete")
local name = args[8] or "default"
local colorName, colorRGB = colorOf(block)

local wallBlock
if opts.walls then
  if opts.wallBlock then
    wallBlock = withNamespace(opts.wallBlock)
  elseif colorName then
    wallBlock = "minecraft:" .. colorName .. "_stained_glass"
  else
    wallBlock = "minecraft:glass"
  end
end

-- Outer bounds: min corner to max corner + 1 so both corner blocks are enclosed.
local x0, x1 = math.min(args[1], args[4]), math.max(args[1], args[4]) + 1
local y0, y1 = math.min(args[2], args[5]), math.max(args[2], args[5]) + 1
local z0, z1 = math.min(args[3], args[6]), math.max(args[3], args[6]) + 1
local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
local t = THICKNESS

local tags = string.format('Tags:["%s","%s"]', BASE_TAG, tagFor(name))
local glow = opts.xray
  and string.format("Glowing:1b,glow_color_override:%d,", colorRGB or 0xFFFFFF)
  or ""

local function display(blk, x, y, z, sx, sy, sz, extra)
  -- width/height is the client's culling box (centered horizontally on the
  -- entity, extending up); size it to cover what's rendered.
  -- view_range keeps large boxes visible from afar.
  local width = 2 * math.max(sx, sz)
  return string.format(
    "summon minecraft:block_display %.4f %.4f %.4f {block_state:{Name:\"%s\"},"
      .. "transformation:{left_rotation:[0f,0f,0f,1f],right_rotation:[0f,0f,0f,1f],"
      .. "translation:[0f,0f,0f],scale:[%.4ff,%.4ff,%.4ff]},"
      .. "width:%.4ff,height:%.4ff,view_range:4f,"
      .. "brightness:{sky:15,block:15},%s%s}",
    x, y, z, blk, sx, sy, sz, width, sy, extra, tags)
end

local function edge(x, y, z, sx, sy, sz)
  return display(block, x, y, z, sx, sy, sz, glow)
end

local function wall(x, y, z, sx, sy, sz)
  return display(wallBlock, x, y, z, sx, sy, sz, "")
end

-- Redrawing a box with the same name replaces it.
commands.exec("kill @e[type=minecraft:block_display,tag=" .. tagFor(name) .. "]")

-- Edges are centered on the box boundary (half inside, half outside) so none
-- of their faces are coplanar with block faces (no z-fighting with terrain).
-- X edges run the full length including the corner cubes; Y and Z edges stop
-- short of the corners so edges never overlap each other either.
local h = t / 2
local parts = {}
for _, a in ipairs({ y0 - h, y1 - h }) do
  for _, b in ipairs({ z0 - h, z1 - h }) do
    parts[#parts + 1] = edge(x0 - h, a, b, dx + t, t, t) -- along X
  end
end
for _, a in ipairs({ x0 - h, x1 - h }) do
  for _, b in ipairs({ z0 - h, z1 - h }) do
    parts[#parts + 1] = edge(a, y0 + h, b, t, dy - t, t) -- along Y
  end
end
for _, a in ipairs({ x0 - h, x1 - h }) do
  for _, b in ipairs({ y0 - h, y1 - h }) do
    parts[#parts + 1] = edge(a, b, z0 + h, t, t, dz - t) -- along Z
  end
end

-- Walls fill the space between the edges, inset slightly into the box so they
-- don't z-fight with the faces of neighbouring blocks.
if wallBlock then
  local e, w = WALL_INSET, WALL_THICKNESS
  local ix, iy, iz = dx - t, dy - t, dz - t -- inner span between edges
  for _, px in ipairs({ x0 + e, x1 - e - w }) do
    parts[#parts + 1] = wall(px, y0 + h, z0 + h, w, iy, iz) -- X faces
  end
  for _, py in ipairs({ y0 + e, y1 - e - w }) do
    parts[#parts + 1] = wall(x0 + h, py, z0 + h, ix, w, iz) -- Y faces
  end
  for _, pz in ipairs({ z0 + e, z1 - e - w }) do
    parts[#parts + 1] = wall(x0 + h, y0 + h, pz, ix, iy, w) -- Z faces
  end
end

local failed = 0
for _, cmd in ipairs(parts) do
  if not run(cmd) then failed = failed + 1 end
end

if failed == 0 then
  print(string.format("Box '%s' drawn: %dx%dx%d (%s%s%s)", name, dx, dy, dz, block,
    wallBlock and (", walls " .. wallBlock) or "", opts.xray and ", xray" or ""))
else
  printError(string.format("%d/%d parts failed (is the area loaded?)", failed, #parts))
end
