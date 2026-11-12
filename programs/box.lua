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

-- The computer's dimension, e.g. "minecraft:overworld". There's no command
-- that just prints it, but forceload query's message names it, forced or not.
local currentDim
local function dimension()
  if not currentDim then
    local x, _, z = commands.getBlockPosition()
    local _, out = commands.exec(string.format("forceload query %d %d", x, z))
    currentDim = (out and out[1] or ""):match(" in (%S+) is ") or "minecraft:overworld"
  end
  return currentDim
end

-- Run a command in a dimension.
local function execIn(dim, cmd)
  return commands.exec("execute in " .. dim .. " run " .. cmd)
end

-- Registry of boxes in command storage, so boxes can be listed and removed
-- even when their chunks aren't loaded. Each entry is a string:
--   "<dimension>|x0,y0,z0|x1,y1,z1|<entity count>|cx,cz;cx,cz;..."
-- holding the box's dimension, corner blocks, how many entities it consists
-- of, and the chunks those entities are stored in.
local REGISTRY = "ccbox:registry"

local function parseEntry(s)
  local dim, from, to, count, chunkList = s:match("^([^|]*)|([^|]*)|([^|]*)|(%d+)|(.*)$")
  if not dim then
    -- Older entries had no dimension.
    from, to, count, chunkList = s:match("^([^|]*)|([^|]*)|(%d+)|(.*)$")
    if not from then return nil end
    dim = dimension()
  end
  local e = { dim = dim, from = {}, to = {}, count = tonumber(count), chunks = {} }
  for n in from:gmatch("-?%d+") do e.from[#e.from + 1] = tonumber(n) end
  for n in to:gmatch("-?%d+") do e.to[#e.to + 1] = tonumber(n) end
  for a, b in chunkList:gmatch("(-?%d+),(-?%d+)") do
    e.chunks[#e.chunks + 1] = { tonumber(a), tonumber(b) }
  end
  return e
end

local function formatEntry(e)
  local chunks = {}
  for i, c in ipairs(e.chunks) do chunks[i] = c[1] .. "," .. c[2] end
  return string.format("%s|%d,%d,%d|%d,%d,%d|%d|%s", e.dim, e.from[1], e.from[2], e.from[3],
    e.to[1], e.to[2], e.to[3], e.count, table.concat(chunks, ";"))
end

-- All registered boxes, as a name -> entry table.
local function registryAll()
  local ok, out = commands.exec("data get storage " .. REGISTRY .. " boxes")
  local boxes = {}
  if not ok then return boxes end
  local text = table.concat(out, " ")
  for key, val in text:gmatch('"?([%w_%-%.%+]+)"?%s*:%s*"([^"]*)"') do
    boxes[key] = parseEntry(val)
  end
  return boxes
end

local function registrySet(name, e)
  commands.exec(string.format('data modify storage %s boxes."%s" set value "%s"',
    REGISTRY, name, formatEntry(e)))
end

local function registryRemove(name)
  commands.exec(string.format('data remove storage %s boxes."%s"', REGISTRY, name))
end

-- Run fn with the given chunks of a dimension loaded. Chunks that weren't
-- already forceloaded are forceloaded for the duration and released
-- afterwards; chunks that something else forceloaded are left alone.
local function withChunksLoaded(dim, chunks, fn)
  local added = {}
  for _, c in ipairs(chunks) do
    local bx, bz = c[1] * 16, c[2] * 16
    local ok, out = execIn(dim, string.format("forceload query %d %d", bx, bz))
    local forced = ok and not (out[1] or ""):find("not marked")
    if not forced and execIn(dim, string.format("forceload add %d %d", bx, bz)) then
      added[#added + 1] = c
    end
  end
  if #added > 0 then print(string.format("Loading %d chunk(s)...", #added)) end
  local ok, err = pcall(fn)
  for _, c in ipairs(added) do
    execIn(dim, string.format("forceload remove %d %d", c[1] * 16, c[2] * 16))
  end
  if not ok then error(err, 0) end
end

-- Seconds to wait for forceloaded chunks and their entities. Generous because
-- far-away chunks may need loading from disk or even generating first.
local LOAD_TIMEOUT = 30

-- Wait until all the chunks of a dimension are loaded. Returns false on timeout.
local function waitLoaded(dim, chunks)
  local deadline = os.clock() + LOAD_TIMEOUT
  repeat
    local all = true
    for _, c in ipairs(chunks) do
      if not commands.exec(string.format("execute in %s if loaded %d 0 %d", dim, c[1] * 16, c[2] * 16)) then
        all = false
        break
      end
    end
    if all then return true end
    sleep(0.1)
  until os.clock() > deadline
  return false
end

-- Run a kill command and return how many entities it killed.
local function kill(selector)
  local ok, out, n = commands.exec("kill " .. selector)
  if not ok then return 0 end
  if n then return n end
  -- Older CC:Tweaked doesn't return the count: "Killed 26 entities" / "Killed <name>".
  return tonumber((out[1] or ""):match("(%d+)")) or 1
end

-- Kill a box's entities, loading its chunks if needed. Returns how many were killed.
local function killBox(name, entry)
  local selector = "@e[tag=" .. tagFor(name) .. "]"
  if not entry then
    -- Unregistered box: only what's loaded can be reached.
    return kill(selector)
  end
  local killed = 0
  withChunksLoaded(entry.dim, entry.chunks, function()
    -- `if loaded` (used by waitLoaded) also requires the chunk's entities to
    -- be loaded, but keep killing until all are gone in case some lag behind.
    killed = killed + kill(selector)
    if killed >= entry.count then return end
    waitLoaded(entry.dim, entry.chunks)
    local deadline = os.clock() + LOAD_TIMEOUT
    repeat
      killed = killed + kill(selector)
      if killed >= entry.count then return end
      sleep(0.1)
    until os.clock() > deadline
  end)
  return killed
end

-- Remove a box and its registry entry. Returns false if nothing was found.
local function removeBox(name, quiet)
  local entry = registryAll()[name]
  local killed = killBox(name, entry)
  if entry and killed < entry.count then
    -- Keep the rest registered so a later remove can try again.
    entry.count = entry.count - killed
    registrySet(name, entry)
    printError(string.format("Box '%s': removed %d entities, %d didn't load in time. Try again.",
      name, killed, entry.count))
    return true
  end
  registryRemove(name)
  if not quiet and (entry or killed > 0) then print("Removed box '" .. name .. "'") end
  return entry ~= nil or killed > 0
end

local function remove(name)
  name = sanitize(name)
  if not removeBox(name) then
    printError("No box named '" .. name .. "'")
  end
end

local function clear(skipConfirm)
  local boxes = registryAll()
  if not skipConfirm then
    write("Remove ALL boxes? [y/N] ")
    local answer = (read() or ""):lower()
    if answer ~= "y" and answer ~= "yes" then
      print("Cancelled.")
      return
    end
  end
  local n = 0
  for name in pairs(boxes) do
    removeBox(name, true)
    n = n + 1
  end
  -- Also catch loaded leftovers that aren't registered.
  commands.exec("kill @e[tag=" .. BASE_TAG .. "]")
  print(string.format("Removed %d registered box(es)", n))
end

-- First "boxN" name not used by a registered box.
local function nextFreeName()
  local used = registryAll()
  local n = 1
  while used["box" .. n] do n = n + 1 end
  return "box" .. n
end

local function list()
  local names = {}
  local boxes = registryAll()
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

local TAGS = string.format('Tags:["%s","%s"]', BASE_TAG, tagFor(name))
local FULLBRIGHT = "brightness:{sky:15,block:15}"

-- Chunks the box's entities are stored in (an entity lives in the chunk
-- containing its position), for loading them again on remove.
local chunks, chunkSeen = {}, {}
local function track(x, z)
  local c = { math.floor(x / 16), math.floor(z / 16) }
  local key = c[1] .. "," .. c[2]
  if not chunkSeen[key] then
    chunkSeen[key] = true
    chunks[#chunks + 1] = c
  end
end

local function edge(x, y, z, sx, sy, sz)
  track(x, z)
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
    x, y, z, block, sx, sy, sz, 2 * math.max(sx, sz), sy, FULLBRIGHT, glow, TAGS)
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
  track(x, z)
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
    2 * (w + l), height, FULLBRIGHT, TAGS)
end

-- Redrawing a box with the same name replaces it.
removeBox(name, true)

-- Edges are centered on the box boundary (half inside, half outside) so none
-- of their faces are coplanar with block faces (no z-fighting with terrain).
-- X edges run the full length including the corner cubes; Y and Z edges stop
-- short of the corners so edges never overlap each other either.
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

-- Load the chunks (so boxes can be drawn anywhere), summon, and register.
local failed = 0
local dim = dimension()
withChunksLoaded(dim, chunks, function()
  if not waitLoaded(dim, chunks) then
    -- Summoning into a chunk that isn't loaded can leave entities in limbo
    -- where commands can't reach them, so don't.
    printError("Timed out waiting for chunks to load; box not drawn. Try again.")
    failed = #parts
    return
  end
  for _, cmd in ipairs(parts) do
    if not run(cmd) then failed = failed + 1 end
  end
end)

if failed < #parts then
  registrySet(name, {
    dim = dim, from = { bx0, by0, bz0 }, to = { bx1, by1, bz1 },
    count = #parts - failed, chunks = chunks,
  })
end

if failed == 0 then
  local walls = opts.walls and string.format(", walls %s%% #%06X", tostring(opts.opacity), wallRGB) or ""
  print(string.format("Box '%s' drawn: %dx%dx%d (%s%s%s)", name, dx, dy, dz, block,
    walls, opts.xray and ", xray" or ""))
else
  printError(string.format("%d/%d parts failed", failed, #parts))
end
