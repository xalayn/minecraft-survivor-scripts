-- boxdraw: draw visual-only boxes out of display entities, and keep track of
-- them so they can be listed and removed even when their chunks are unloaded.
--
--   local boxdraw = require("boxdraw")
--   boxdraw.draw("spawn", { x0, y0, z0, x1, y1, z1 }, { block = "red_concrete" })
--   boxdraw.remove("spawn")
--
-- Boxes are recorded in command storage (ccbox:registry, saved with the
-- world), including which chunks their entities are in. Drawing and removing
-- briefly forceload those chunks (at most a few per box, at its corners).

local cmd = require("cmd")
local shapes = require("shapes")

local M = {}

M.BASE_TAG = "ccbox"
M.DEFAULT_BLOCK = "lime_concrete"
M.DEFAULT_OPACITY = 20

local THICKNESS = 0.0625 -- edge thickness in blocks (1 pixel)
local WALL_INSET = 0.01  -- walls sit this far inside the box, so they don't z-fight with blocks

-- Vanilla dye text colors, longest names first so "light_blue" matches before "blue".
local COLORS = {
  { "light_blue", 0x9AC0CD }, { "light_gray", 0xD3D3D3 },
  { "magenta", 0xFF00FF }, { "orange", 0xFF681F }, { "yellow", 0xFFFF00 },
  { "purple", 0xA020F0 }, { "white", 0xFFFFFF }, { "black", 0x000000 },
  { "brown", 0x8B4513 }, { "green", 0x00FF00 }, { "gray", 0x808080 },
  { "pink", 0xFF69B4 }, { "cyan", 0x00FFFF }, { "blue", 0x0000FF },
  { "lime", 0xBFFF00 }, { "red", 0xFF0000 },
}

function M.tagFor(name)
  return M.BASE_TAG .. "_" .. name
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

--- RGB from a dye name or hex string (RRGGBB or #RRGGBB), or nil.
function M.parseColor(s)
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

---------------------------------------------------------------------------
-- Registry. Each entry is a string:
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
    dim = cmd.dimension()
  end
  -- lastId also repairs entries saved with a mangled dimension by older versions.
  local e = { dim = cmd.lastId(dim) or cmd.dimension(), from = {}, to = {}, count = tonumber(count), chunks = {} }
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

--- All registered boxes, as a name -> { dim, from, to, count, chunks } table.
function M.all()
  local ok, out = commands.exec("data get storage " .. REGISTRY .. " boxes")
  local boxes = {}
  if not ok then return boxes end
  for name, value in pairs(cmd.parseStringCompound(out)) do
    boxes[name] = parseEntry(value)
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

--- First "boxN" name not used by a registered box.
function M.nextFreeName()
  local used = M.all()
  local n = 1
  while used["box" .. n] do n = n + 1 end
  return "box" .. n
end

---------------------------------------------------------------------------
-- Chunk loading.

-- Seconds to wait for forceloaded chunks and their entities. Generous because
-- far-away chunks may need loading from disk or even generating first.
local LOAD_TIMEOUT = 30

-- One command per chunk, from a format taking (dimension, block x, block z).
local function chunkCmds(dim, chunks, fmt)
  local cmds = {}
  for i, c in ipairs(chunks) do cmds[i] = string.format(fmt, dim, c[1] * 16, c[2] * 16) end
  return cmds
end

local function allOk(results)
  for _, r in ipairs(results) do
    if not r.ok then return false end
  end
  return true
end

-- Wait until all the chunks of a dimension are loaded (`if loaded` also
-- requires their entities to be loaded). Returns false on timeout.
local function waitLoaded(dim, chunks)
  local cmds = chunkCmds(dim, chunks, "execute in %s if loaded %d 0 %d")
  local deadline = os.clock() + LOAD_TIMEOUT
  local results
  repeat
    results = cmd.execAll(cmds)
    if allOk(results) then return true end
    sleep(0.1)
  until os.clock() > deadline

  printError("Chunks not loaded after " .. LOAD_TIMEOUT .. "s (" .. dim .. "):")
  for i, c in ipairs(chunks) do
    if not results[i].ok then
      print(string.format(" %d,%d: %s", c[1] * 16, c[2] * 16, tostring(results[i].out[1])))
    end
  end
  return false
end

-- Run fn(loaded) with the given chunks of a dimension loaded; `loaded` is
-- false if they didn't load in time. Chunks that are already loaded are left
-- alone. Unloaded ones are forceloaded for the duration and released
-- afterwards, unless something else had forceloaded them.
local function withChunksLoaded(dim, chunks, fn)
  local unloaded = {}
  local loadedNow = cmd.execAll(chunkCmds(dim, chunks, "execute in %s if loaded %d 0 %d"))
  for i, c in ipairs(chunks) do
    if not loadedNow[i].ok then unloaded[#unloaded + 1] = c end
  end

  local added = {}
  if #unloaded > 0 then
    local queries = cmd.execAll(chunkCmds(dim, unloaded, "execute in %s run forceload query %d %d"))
    local toAdd = {}
    for i, c in ipairs(unloaded) do
      local forced = queries[i].ok and not (queries[i].out[1] or ""):find("not marked")
      if not forced then toAdd[#toAdd + 1] = c end
    end
    local adds = cmd.execAll(chunkCmds(dim, toAdd, "execute in %s run forceload add %d %d"))
    for i, c in ipairs(toAdd) do
      if adds[i].ok then added[#added + 1] = c end
    end
    print(string.format("Loading %d chunk(s)...", #unloaded))
  end

  local loaded = #unloaded == 0 or waitLoaded(dim, chunks)
  local ok, err = pcall(fn, loaded)
  cmd.execAll(chunkCmds(dim, added, "execute in %s run forceload remove %d %d"))
  if not ok then error(err, 0) end
end

---------------------------------------------------------------------------
-- Removing.

-- Run a kill command and return how many entities it killed.
local function kill(selector)
  local ok, out = commands.exec("kill " .. selector)
  if not ok then return 0 end
  -- The message is "Killed 26 entities" or, for one entity, "Killed <name>".
  -- (commands.exec's third return value isn't the kill count, so don't use it.)
  return tonumber((out[1] or ""):match("(%d+) entities")) or 1
end

-- How long to keep looking for stragglers once the chunks report loaded.
local GRACE = 2

-- Kill a box's entities, loading its chunks if needed.
-- Returns how many were killed, and whether its chunks could be loaded.
local function killBox(name, entry)
  local selector = "@e[tag=" .. M.tagFor(name) .. "]"
  if not entry then
    -- Unregistered box: only what's loaded can be reached.
    return kill(selector), true
  end
  local killed, loaded = 0, false
  withChunksLoaded(entry.dim, entry.chunks, function(ok)
    loaded = ok
    if not loaded then return end
    -- Chunks (and their entities) are loaded; allow a moment for stragglers.
    local deadline = os.clock() + GRACE
    repeat
      killed = killed + kill(selector)
      if killed >= entry.count then return end
      sleep(0.1)
    until os.clock() > deadline
  end)
  return killed, loaded
end

--- Remove a box and its registry entry. Returns false if nothing was found.
function M.remove(name, quiet)
  local entry = M.all()[name]
  local killed, loaded = killBox(name, entry)
  if not loaded then
    -- Keep it registered so a later remove can try again.
    printError(string.format("Box '%s': its chunks didn't load in time (removed %d of %d parts). Try again.",
      name, killed, entry.count))
    return true
  end
  registryRemove(name)
  if entry and killed < entry.count then
    print(string.format("Box '%s': only found %d of %d parts; the rest were already gone.",
      name, killed, entry.count))
  end
  if not quiet and (entry or killed > 0) then print("Removed box '" .. name .. "'") end
  return entry ~= nil or killed > 0
end

--- Remove all boxes. Returns how many registered boxes were removed.
function M.clear()
  local n = 0
  for name in pairs(M.all()) do
    M.remove(name, true)
    n = n + 1
  end
  -- Also catch loaded leftovers that aren't registered.
  commands.exec("kill @e[tag=" .. M.BASE_TAG .. "]")
  return n
end

---------------------------------------------------------------------------
-- Drawing.

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

local FULLBRIGHT = "brightness:{sky:15,block:15}"

-- Rotate vector v by quaternion q = { x, y, z, w }.
local function rotate(q, vx, vy, vz)
  local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
  -- t = 2 * cross(q.xyz, v); v' = v + w * t + cross(q.xyz, t)
  local tx, ty, tz = 2 * (qy * vz - qz * vy), 2 * (qz * vx - qx * vz), 2 * (qx * vy - qy * vx)
  return vx + qw * tx + (qy * tz - qz * ty), vy + qw * ty + (qz * tx - qx * tz), vz + qw * tz + (qx * ty - qy * tx)
end

--- Draw shapes (see lib/shapes.lua) as one drawing, replacing any existing
-- drawing with the same name.
-- o (all optional):
--   block      edge block (default lime_concrete)
--   walls      draw translucent walls on boxes (default true)
--   opacity    wall opacity percent (default 20)
--   wallColor  wall RGB number or color string (default: edge block's dye color, or white)
--   xray       edges visible through blocks (glowing outline)
--   dim        dimension (default: the computer's)
-- Returns true and a summary, or false and an error message.
--
-- Shapes draw themselves with the helpers in the table passed to their draw():
--   d.edge(x, y, z, sx, sy, sz)        an axis-aligned bar from its min corner
--   d.segment(ax, ay, az, bx, by, bz)  a bar between two points
--   d.panel(dir, x, y, z, w, l)        a one-sided translucent wall panel
--   d.thickness, d.walls, d.wallInset
function M.drawShapes(name, list, o)
  o = o or {}
  local block = withNamespace(o.block or M.DEFAULT_BLOCK)
  local walls = o.walls ~= false
  local opacity = o.opacity or M.DEFAULT_OPACITY
  local dim = o.dim or cmd.dimension()
  local _, edgeRGB = colorOf(block)

  local wallRGB = edgeRGB or 0xFFFFFF
  if type(o.wallColor) == "string" then
    wallRGB = M.parseColor(o.wallColor)
    if not wallRGB then return false, "Bad wall color: " .. o.wallColor end
  elseif type(o.wallColor) == "number" then
    wallRGB = o.wallColor
  end

  local t = THICKNESS
  local h = t / 2
  local tags = string.format('Tags:["%s","%s"]', M.BASE_TAG, M.tagFor(name))
  local parts = {}

  -- Chunks the entities are stored in (an entity lives in the chunk
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

  local glow = ""
  if o.xray then
    glow = string.format("Glowing:1b,glow_color_override:%d,", edgeRGB or 0xFFFFFF)
  end

  -- A block_display bar. width/height is the client's culling box (centered
  -- horizontally on the entity, extending up); sized to cover what's
  -- rendered. view_range keeps large drawings visible from afar.
  local function bar(x, y, z, q, tx, ty, tz, sx, sy, sz, cullW, cullH)
    track(x, z)
    parts[#parts + 1] = string.format(
      "execute in %s run summon minecraft:block_display %.4f %.4f %.4f {block_state:{Name:\"%s\"},"
        .. "transformation:{left_rotation:[%.6ff,%.6ff,%.6ff,%.6ff],right_rotation:[0f,0f,0f,1f],"
        .. "translation:[%.4ff,%.4ff,%.4ff],scale:[%.4ff,%.4ff,%.4ff]},"
        .. "width:%.4ff,height:%.4ff,view_range:4f,%s,%s%s}",
      dim, x, y, z, block, q[1], q[2], q[3], q[4], tx, ty, tz, sx, sy, sz,
      cullW, cullH, FULLBRIGHT, glow, tags)
  end

  local d = { thickness = t, walls = walls, wallInset = WALL_INSET }

  function d.edge(x, y, z, sx, sy, sz)
    bar(x, y, z, { 0, 0, 0, 1 }, 0, 0, 0, sx, sy, sz, 2 * math.max(sx, sz), sy)
  end

  function d.segment(ax, ay, az, bx, by, bz)
    if by < ay then ax, ay, az, bx, by, bz = bx, by, bz, ax, ay, az end -- start at the bottom
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return end
    local ux, uy, uz = dx / len, dy / len, dz / len
    -- Rotation taking +X (the bar's length) onto the direction.
    local q
    if ux < -0.999999 then
      q = { 0, 1, 0, 0 }
    else
      local qx, qy, qz, qw = 0, -uz, uy, 1 + ux
      local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
      q = { qx / n, qy / n, qz / n, qw / n }
    end
    -- Center the bar's cross-section on the line.
    local tx, ty, tz = rotate(q, 0, -h, -h)
    bar(ax, ay, az, q, tx, ty, tz, len, t, t, 2 * math.max(math.abs(dx), math.abs(dz)) + 1, dy + 1)
  end

  local wallText = snbtText() and 'text:" "' or [[text:'" "']]
  local alpha = math.floor(opacity * 255 / 100 + 0.5)
  local argb = alpha * 0x1000000 + wallRGB
  if argb >= 0x80000000 then argb = argb - 0x100000000 end -- NBT ints are signed

  -- A one-sided panel with its corner at (x, y, z), w long along the orientation's
  -- ex axis and l long along its ey axis.
  function d.panel(dir, x, y, z, w, l)
    track(x, z)
    local or_ = ORIENT[dir]
    local sx, sy = w / QUAD_W, l / QUAD_H
    -- Shift so the quad's left edge (local x = QUAD_X0) lands on the entity position.
    local shift = -QUAD_X0 * sx
    local tx, ty, tz = or_.ex[1] * shift, or_.ex[2] * shift, or_.ex[3] * shift
    local height = or_.ey[2] == 1 and l or 0.1
    parts[#parts + 1] = string.format(
      "execute in %s run summon minecraft:text_display %.4f %.4f %.4f {%s,background:%d,"
        .. "transformation:{left_rotation:[%.6ff,%.6ff,%.6ff,%.6ff],right_rotation:[0f,0f,0f,1f],"
        .. "translation:[%.4ff,%.4ff,%.4ff],scale:[%.4ff,%.4ff,1f]},"
        .. "width:%.4ff,height:%.4ff,view_range:4f,%s,%s}",
      dim, x, y, z, wallText, argb, or_.q[1], or_.q[2], or_.q[3], or_.q[4], tx, ty, tz, sx, sy,
      2 * (w + l), height, FULLBRIGHT, tags)
  end

  for _, s in ipairs(list) do
    local st, err = shapes.type(s.type)
    if not st then return false, err end
    st.draw(s, d)
  end

  -- Redrawing with the same name replaces it.
  M.remove(name, true)

  -- Load the chunks (so drawings can be made anywhere), summon, and register.
  local failed, timedOut = 0, false
  withChunksLoaded(dim, chunks, function(loaded)
    if not loaded then
      -- Summoning into a chunk that isn't loaded can leave entities in limbo
      -- where commands can't reach them, so don't.
      timedOut = true
      return
    end
    for i, r in ipairs(cmd.execAll(parts)) do
      if not r.ok then
        failed = failed + 1
        printError(parts[i])
        for _, line in ipairs(r.out) do printError("  " .. line) end
      end
    end
  end)

  if timedOut then
    return false, "Timed out waiting for chunks to load; not drawn. Try again."
  end
  local x0, y0, z0, x1, y1, z1 = shapes.boundsAll(list)
  if failed < #parts then
    registrySet(name, {
      dim = dim,
      from = { math.floor(x0), math.floor(y0), math.floor(z0) },
      to = { math.ceil(x1) - 1, math.ceil(y1) - 1, math.ceil(z1) - 1 },
      count = #parts - failed, chunks = chunks,
    })
  end
  if failed > 0 then
    return false, string.format("%d/%d parts failed", failed, #parts)
  end
  local wallInfo = walls and string.format(", walls %s%% #%06X", tostring(opacity), wallRGB) or ""
  return true, string.format("'%s' drawn: %d part(s) (%s%s%s)", name, #parts, block,
    wallInfo, o.xray and ", xray" or "")
end

--- Draw a box, replacing any existing drawing with the same name.
-- area: { x0, y0, z0, x1, y1, z1 }, inclusive block corners. o: as drawShapes.
function M.draw(name, area, o)
  local ok, msg = M.drawShapes(name, { { type = "box", from = { area[1], area[2], area[3] },
    to = { area[4], area[5], area[6] } } }, o)
  if ok then
    msg = string.format("Box %s (%dx%dx%d)", msg, area[4] - area[1] + 1, area[5] - area[2] + 1, area[6] - area[3] + 1)
  end
  return ok, msg
end

return M
