-- shapes: the shapes regions are made of (a region is one or more shapes).
--
-- A shape is plain data, e.g.
--   { type = "box", from = { x, y, z }, to = { x, y, z } }
--   { type = "sphere", center = { x, y, z }, radius = 5 }
--   { type = "cylinder", center = { x, y, z }, radius = 5, height = 10 }
-- with block coordinates (a block's x, y, z; it spans x..x+1).
--
-- Shape types are modules in lib/shapes/<type>.lua. Each returns:
--   description  e.g. "Sphere".
--   usage        Command-line arguments, e.g. "<x> <y> <z> <radius>".
--   check(s)     Validate and normalize shape data (from the network or a
--                file): returns the clean shape, or nil and an error.
--   fromArgs(args, coord)  Build a shape from command-line arguments; coord(s,
--                axis) parses a coordinate (accepting ~). Returns shape or
--                nil, err.
--   steps        For creating it by walking (control app): a list of
--                { prompt = "Stand at the center", button = "Set center" }.
--   fromPoints(points)  Build the shape from the block positions recorded at
--                each step ({ x, y, z } each).
--   bounds(s)    Outer bounds x0, y0, z0, x1, y1, z1 in world coordinates.
--   contains(s, x, y, z)  Whether a position (a player's feet) is inside.
--   inside(s, x, y, z, half, height)  The nearest position to (x, y, z)
--                where a player's hitbox (half-width, height) fits inside.
--   spawn(s)     Where to teleport players to: x, y, z.
--   describe(s)  Short text, e.g. "sphere r5 at 10,64,3".
--   size(s)      Size text, e.g. "11x11x11".
--   draw(s, d)   Draw it with the helpers in d (see lib/boxdraw.lua).

local M = {}

local typeCache = {}

--- A shape type module by name, or nil and an error.
function M.type(name)
  if type(name) ~= "string" or not name:match("^[%w_]+$") then return nil, "Bad shape type" end
  if typeCache[name] == nil then
    local ok, mod = pcall(require, "shapes." .. name)
    typeCache[name] = ok and mod or false
  end
  if not typeCache[name] then return nil, "Unknown shape: " .. name end
  return typeCache[name]
end

--- Names of installed shape types.
function M.typeNames()
  local names = {}
  if fs.isDir("/lib/shapes") then
    for _, f in ipairs(fs.list("/lib/shapes")) do
      local n = f:match("^([%w_]+)%.lua$")
      if n then names[#names + 1] = n end
    end
  end
  table.sort(names)
  return names
end

--- Validate and normalize a shape. Returns it, or nil and an error.
function M.check(s)
  if type(s) ~= "table" then return nil, "Bad shape" end
  local t, err = M.type(s.type)
  if not t then return nil, err end
  local clean, cerr = t.check(s)
  if not clean then return nil, cerr end
  clean.type = s.type
  return clean
end

--- Check that a value is a list of 3 numbers; returns it with whole numbers.
function M.point(p, what)
  if type(p) ~= "table" or type(p[1]) ~= "number" or type(p[2]) ~= "number" or type(p[3]) ~= "number" then
    return nil, "Bad " .. (what or "point")
  end
  return { math.floor(p[1]), math.floor(p[2]), math.floor(p[3]) }
end

--- Check that a value is a number in a range; returns it.
function M.number(v, what, min, max)
  v = tonumber(v)
  if not v or v ~= v or (min and v < min) or (max and v > max) then
    return nil, string.format("%s must be a number from %s to %s", what, tostring(min), tostring(max))
  end
  return v
end

local function call(s, fn, ...)
  local t = assert(M.type(s.type))
  return t[fn](s, ...)
end

function M.bounds(s) return call(s, "bounds") end
function M.contains(s, x, y, z) return call(s, "contains", x, y, z) end
function M.inside(s, x, y, z, half, height) return call(s, "inside", x, y, z, half, height) end
function M.spawn(s) return call(s, "spawn") end
function M.describe(s) return call(s, "describe") end
function M.size(s) return call(s, "size") end

--- Outer bounds of several shapes together.
function M.boundsAll(list)
  local b
  for _, s in ipairs(list) do
    local x0, y0, z0, x1, y1, z1 = M.bounds(s)
    if not b then
      b = { x0, y0, z0, x1, y1, z1 }
    else
      b = { math.min(b[1], x0), math.min(b[2], y0), math.min(b[3], z0),
        math.max(b[4], x1), math.max(b[5], y1), math.max(b[6], z1) }
    end
  end
  if not b then return 0, 0, 0, 0, 0, 0 end
  return table.unpack(b)
end

return M
