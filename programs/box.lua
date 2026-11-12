-- box: draw a visual-only box between two corners.
-- Requires a Command Computer (CC:Tweaked) and Minecraft 1.19.4+.
--
-- The box is made of display entities: no collision, no real blocks placed.
-- The area must be loaded for the entities to be summoned, listed or cleared.
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
--   list    Show all boxes in loaded chunks, with their corners and size.
--   remove  Remove the box with that name.
--   clear   Remove all boxes in loaded chunks. Asks for confirmation first.
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

package.path = "/lib/?.lua;" .. package.path
local argparse = require("args")

if not commands then
  printError("box requires a Command Computer")
  return
end

local THICKNESS = 0.0625 -- edge thickness in blocks (1 pixel)
local WALL_INSET = 0.01  -- walls sit this far inside the box, so they don't z-fight with blocks
local DEFAULT_OPACITY = 20
local BASE_TAG = "ccbox"
local INFO_TAG = "ccbox_info:" -- carried by one edge per box: "<name>|x0,y0,z0|x1,y1,z1"

-- Vanilla dye text colors, longest names first so "light_blue" matches before "blue".
local COLORS = {
  { "light_blue", 0x9AC0CD }, { "light_gray", 0xD3D3D3 },
  { "magenta", 0xFF00FF }, { "orange", 0xFF681F }, { "yellow", 0xFFFF00 },
  { "purple", 0xA020F0 }, { "white", 0xFFFFFF }, { "black", 0x000000 },
  { "brown", 0x8B4513 }, { "green", 0x00FF00 }, { "gray", 0x808080 },
  { "pink", 0xFF69B4 }, { "cyan", 0x00FFFF }, { "blue", 0x0000FF },
  { "lime", 0xBFFF00 }, { "red", 0xFF0000 },
}

local OPTIONS = {
  { name = "yes", short = "y", desc = "clear: don't ask" },
  { name = "name", type = "string", desc = "Box name" },
  { name = "walls", default = true, desc = "No walls" },
  { name = "opacity", type = "number", default = DEFAULT_OPACITY, min = 0, max = 100,
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

local function sanitize(name)
  -- Entity tags used in selectors can't contain spaces or most punctuation.
  return (name:gsub("[^%w_%-%.%+]", "_"))
end

local function tagFor(name)
  return BASE_TAG .. "_" .. name
end

local function withNamespace(block)
  return block:find(":") and block or ("minecraft:" .. block)
end

-- Dye color name and RGB of a block like "minecraft:lime_concrete".
local function colorOf(block)
  local path = block:match(":(.*)$") or block
  for _, c in ipairs(COLORS) do
    if path:sub(1, #c[1] + 1) == c[1] .. "_" then return c[1], c[2] end
  end
end

-- RGB from a dye name or hex string.
local function parseColor(s)
  for _, c in ipairs(COLORS) do
    if s == c[1] then return c[2] end
  end
  local hex = s:match("^#?(%x%x%x%x%x%x)$")
  return hex and tonumber(hex, 16)
end

-- Minecraft 1.21.5 switched text components in NBT from JSON strings to SNBT.
local function snbtText()
  local v = _HOST and _HOST:match("Minecraft ([%d%.]+)")
  if not v then return true end
  local parts = {}
  for n in v:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
  local a, b, c = parts[1] or 0, parts[2] or 0, parts[3] or 0
  if a ~= 1 then return a > 1 end
  if b ~= 21 then return b > 21 end
  return c >= 5
end

local function run(cmd)
  local ok, out = commands.exec(cmd)
  if not ok then
    printError(cmd)
    for _, line in ipairs(out or {}) do printError("  " .. line) end
  end
  return ok
end

local function remove(name)
  name = sanitize(name)
  local ok = commands.exec("kill @e[tag=" .. tagFor(name) .. "]")
  if ok then
    print("Removed box '" .. name .. "'")
  else
    printError("No box named '" .. name .. "' in loaded chunks")
  end
end

local function clear(skipConfirm)
  if not skipConfirm then
    write("Remove ALL boxes in loaded chunks? [y/N] ")
    local answer = read()
    if not answer or answer:lower() ~= "y" and answer:lower() ~= "yes" then
      print("Cancelled.")
      return
    end
  end
  local ok, out = commands.exec("kill @e[tag=" .. BASE_TAG .. "]")
  print(ok and (out[1] or "Cleared") or "No boxes to clear")
end

-- Boxes in loaded chunks, as { name, from = "x,y,z", to = "x,y,z" }.
local function findBoxes()
  local _, out = commands.exec(
    "execute as @e[type=minecraft:block_display,tag=" .. BASE_TAG .. "] run data get entity @s Tags")
  local boxes = {}
  for _, line in ipairs(out or {}) do
    local info = line:match(INFO_TAG .. "([^\"']+)")
    if info then
      local name, a, b = info:match("^(.-)|(.-)|(.-)$")
      if name then boxes[#boxes + 1] = { name = name, from = a, to = b } end
    end
  end
  return boxes
end

-- First "boxN" name not used by a box in loaded chunks.
local function nextFreeName()
  local used = {}
  for _, bx in ipairs(findBoxes()) do used[bx.name] = true end
  local n = 1
  while used["box" .. n] do n = n + 1 end
  return "box" .. n
end

local function list()
  local boxes = findBoxes()
  if #boxes == 0 then
    print("No boxes found in loaded chunks.")
    return
  end
  table.sort(boxes, function(p, q) return p.name < q.name end)
  for _, bx in ipairs(boxes) do
    local x0, y0, z0 = bx.from:match("(-?%d+),(-?%d+),(-?%d+)")
    local x1, y1, z1 = bx.to:match("(-?%d+),(-?%d+),(-?%d+)")
    local size = x0 and string.format("%dx%dx%d", x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1) or "?"
    print(string.format("%s  %s -> %s  (%s)", bx.name, bx.from, bx.to, size))
  end
end

if args[1] == "clear" then
  clear(opts.yes)
  return
elseif args[1] == "remove" then
  if not args[2] then
    printError("Usage: box remove <name>")
    return
  end
  remove(args[2])
  return
elseif args[1] == "list" then
  list()
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
local givenName = opts.name or args[8]
local name = givenName and sanitize(givenName) or nextFreeName()
local _, edgeRGB = colorOf(block)

local wallRGB = edgeRGB or 0xFFFFFF
if opts["wall-color"] then
  wallRGB = parseColor(opts["wall-color"])
  if not wallRGB then
    printError("Bad --wall-color: " .. opts["wall-color"])
    return
  end
end

-- Block corners (inclusive) and outer bounds (max + 1 so both corner blocks are enclosed).
local bx0, bx1 = math.min(args[1], args[4]), math.max(args[1], args[4])
local by0, by1 = math.min(args[2], args[5]), math.max(args[2], args[5])
local bz0, bz1 = math.min(args[3], args[6]), math.max(args[3], args[6])
local x0, x1, y0, y1, z0, z1 = bx0, bx1 + 1, by0, by1 + 1, bz0, bz1 + 1
local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
local t = THICKNESS
local h = t / 2

local function tagList(extra)
  local tags = { BASE_TAG, tagFor(name) }
  if extra then tags[#tags + 1] = extra end
  for i, tg in ipairs(tags) do tags[i] = '"' .. tg .. '"' end
  return "Tags:[" .. table.concat(tags, ",") .. "]"
end

local FULLBRIGHT = "brightness:{sky:15,block:15}"

local function edge(x, y, z, sx, sy, sz, extraTag)
  -- width/height is the client's culling box (centered horizontally on the
  -- entity, extending up); size it to cover what's rendered.
  -- view_range keeps large boxes visible from afar.
  local glow = ""
  if opts.xray then
    glow = string.format("Glowing:1b,glow_color_override:%d,", edgeRGB or 0xFFFFFF)
  end
  return string.format(
    "summon minecraft:block_display %.4f %.4f %.4f {block_state:{Name:\"%s\"},"
      .. "transformation:{left_rotation:[0f,0f,0f,1f],right_rotation:[0f,0f,0f,1f],"
      .. "translation:[0f,0f,0f],scale:[%.4ff,%.4ff,%.4ff]},"
      .. "width:%.4ff,height:%.4ff,view_range:4f,%s,%s%s}",
    x, y, z, block, sx, sy, sz, 2 * math.max(sx, sz), sy, FULLBRIGHT, glow, tagList(extraTag))
end

-- Walls are text_displays showing a single space with a translucent background,
-- stretched into a panel. In the entity's local space, that background is a
-- quad spanning x = QUAD_X0..QUAD_X0+QUAD_W, y = 0..QUAD_H (z = 0), visible
-- only from +Z. (A space is 4px wide plus 1px padding = 5px; a line is 10px
-- plus 1px padding = 11px; 1px = 0.025 blocks.)
local QUAD_X0, QUAD_W, QUAD_H = -0.05, 0.125, 0.275
-- Each orientation below rotates that quad: ex/ey are where its local x/y axes
-- end up, and the quad is then visible from the side its normal points to.
local S = math.sqrt(0.5)
local ORIENT = {
  ["+z"] = { q = { 0, 0, 0, 1 },  ex = { 1, 0, 0 },  ey = { 0, 1, 0 } },
  ["-z"] = { q = { 0, 1, 0, 0 },  ex = { -1, 0, 0 }, ey = { 0, 1, 0 } },
  ["+x"] = { q = { 0, S, 0, S },  ex = { 0, 0, -1 }, ey = { 0, 1, 0 } },
  ["-x"] = { q = { 0, -S, 0, S }, ex = { 0, 0, 1 },  ey = { 0, 1, 0 } },
  ["+y"] = { q = { -S, 0, 0, S }, ex = { 1, 0, 0 },  ey = { 0, 0, -1 } },
  ["-y"] = { q = { S, 0, 0, S },  ex = { 1, 0, 0 },  ey = { 0, 0, 1 } },
}

local wallText = snbtText() and 'text:" "' or [[text:'" "']]
local alpha = math.floor(opts.opacity * 255 / 100 + 0.5)
local argb = alpha * 0x1000000 + wallRGB
if argb >= 0x80000000 then argb = argb - 0x100000000 end -- NBT ints are signed

-- A one-sided panel with its corner at (x, y, z), w long along the orientation's
-- ex axis and l long along its ey axis.
local function panel(dir, x, y, z, w, l)
  local o = ORIENT[dir]
  local sx, sy = w / QUAD_W, l / QUAD_H
  -- Shift so the quad's left edge (local x = QUAD_X0) lands on the entity position.
  local shift = -QUAD_X0 * sx
  local tx, ty, tz = o.ex[1] * shift, o.ex[2] * shift, o.ex[3] * shift
  local height = o.ey[2] == 1 and l or 0.1
  return string.format(
    "summon minecraft:text_display %.4f %.4f %.4f {%s,background:%d,"
      .. "transformation:{left_rotation:[%.6ff,%.6ff,%.6ff,%.6ff],right_rotation:[0f,0f,0f,1f],"
      .. "translation:[%.4ff,%.4ff,%.4ff],scale:[%.4ff,%.4ff,1f]},"
      .. "width:%.4ff,height:%.4ff,view_range:4f,%s,%s}",
    x, y, z, wallText, argb, o.q[1], o.q[2], o.q[3], o.q[4], tx, ty, tz, sx, sy,
    2 * (w + l), height, FULLBRIGHT, tagList())
end

-- Redrawing a box with the same name replaces it.
commands.exec("kill @e[tag=" .. tagFor(name) .. "]")

local info = string.format("%s%s|%d,%d,%d|%d,%d,%d", INFO_TAG, name, bx0, by0, bz0, bx1, by1, bz1)

-- Edges are centered on the box boundary (half inside, half outside) so none
-- of their faces are coplanar with block faces (no z-fighting with terrain).
-- X edges run the full length including the corner cubes; Y and Z edges stop
-- short of the corners so edges never overlap each other either.
local parts = {}
for _, a in ipairs({ y0 - h, y1 - h }) do
  for _, b in ipairs({ z0 - h, z1 - h }) do
    -- The first edge carries the box's info for `box list`.
    parts[#parts + 1] = edge(x0 - h, a, b, dx + t, t, t, #parts == 0 and info or nil) -- along X
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
-- don't z-fight with neighbouring blocks. Each wall is two panels back to back
-- so it's visible from inside and outside.
if opts.walls then
  local e = WALL_INSET
  local ix, iy, iz = dx - t, dy - t, dz - t -- inner span between edges
  for _, px in ipairs({ x0 + e, x1 - e }) do
    parts[#parts + 1] = panel("-x", px, y0 + h, z0 + h, iz, iy)
    parts[#parts + 1] = panel("+x", px, y0 + h, z1 - h, iz, iy)
  end
  for _, py in ipairs({ y0 + e, y1 - e }) do
    parts[#parts + 1] = panel("-y", x0 + h, py, z0 + h, ix, iz)
    parts[#parts + 1] = panel("+y", x0 + h, py, z1 - h, ix, iz)
  end
  for _, pz in ipairs({ z0 + e, z1 - e }) do
    parts[#parts + 1] = panel("+z", x0 + h, y0 + h, pz, ix, iy)
    parts[#parts + 1] = panel("-z", x1 - h, y0 + h, pz, ix, iy)
  end
end

local failed = 0
for _, cmd in ipairs(parts) do
  if not run(cmd) then failed = failed + 1 end
end

if failed == 0 then
  local walls = opts.walls and string.format(", walls %s%% #%06X", tostring(opts.opacity), wallRGB) or ""
  print(string.format("Box '%s' drawn: %dx%dx%d (%s%s%s)", name, dx, dy, dz, block,
    walls, opts.xray and ", xray" or ""))
else
  printError(string.format("%d/%d parts failed (is the area loaded?)", failed, #parts))
end
