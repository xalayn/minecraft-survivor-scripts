-- Shape: a sphere of blocks around a center block.
-- { type = "sphere", center = { x, y, z }, radius = r }
-- Covers the blocks whose centers are within radius of the center block's.

local shapes = require("shapes")

local M = {
  description = "Sphere",
  usage = "<x> <y> <z> <radius>",
  steps = {
    { prompt = "Stand at the center of the sphere.", button = "Set center" },
    { prompt = "Stand at its edge (sets the radius).", button = "Set edge" },
  },
}

function M.check(s)
  local c, err = shapes.point(s.center, "center")
  if not c then return nil, err end
  local r, rerr = shapes.number(s.radius, "Radius", 1, 256)
  if not r then return nil, rerr end
  return { center = c, radius = math.floor(r) }
end

function M.fromArgs(args, coord)
  if #args ~= 4 then return nil, "sphere needs " .. M.usage end
  local c = {}
  for i = 1, 3 do
    local n, err = coord(args[i], i)
    if not n then return nil, err end
    c[i] = n
  end
  return M.check({ center = c, radius = tonumber(args[4]) })
end

function M.fromPoints(p)
  local c, e = p[1], p[2]
  local r = math.floor(math.sqrt((e[1] - c[1]) ^ 2 + (e[2] - c[2]) ^ 2 + (e[3] - c[3]) ^ 2) + 0.5)
  return M.check({ center = c, radius = math.max(1, r) })
end

-- Center (world coordinates) and outer radius.
local function geometry(s)
  return s.center[1] + 0.5, s.center[2] + 0.5, s.center[3] + 0.5, s.radius + 0.5
end

function M.bounds(s)
  local cx, cy, cz, R = geometry(s)
  return cx - R, cy - R, cz - R, cx + R, cy + R, cz + R
end

function M.contains(s, x, y, z)
  local cx, cy, cz, R = geometry(s)
  return (x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2 <= R * R
end

function M.inside(s, x, y, z, half)
  local cx, cy, cz, R = geometry(s)
  local dx, dy, dz = x - cx, y - cy, z - cz
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  local max = math.max(0, R - half - 0.05)
  if len <= max then return x, y, z end
  if len == 0 then return cx, cy, cz end
  local k = max / len
  return cx + dx * k, cy + dy * k, cz + dz * k
end

function M.spawn(s)
  return s.center[1] + 0.5, s.center[2], s.center[3] + 0.5
end

function M.size(s)
  local d = 2 * s.radius + 1
  return string.format("%dx%dx%d", d, d, d)
end

function M.describe(s)
  return string.format("sphere r%d at %d,%d,%d", s.radius, s.center[1], s.center[2], s.center[3])
end

-- Three rings: around the equator and through the poles.
function M.draw(s, d)
  local cx, cy, cz, R = geometry(s)
  local n = math.max(12, math.min(48, math.floor(R * 3)))
  local function ring(point)
    for i = 0, n - 1 do
      local ax, ay, az = point(2 * math.pi * i / n)
      local bx, by, bz = point(2 * math.pi * (i + 1) / n)
      d.segment(ax, ay, az, bx, by, bz)
    end
  end
  ring(function(a) return cx + R * math.cos(a), cy, cz + R * math.sin(a) end)
  ring(function(a) return cx + R * math.cos(a), cy + R * math.sin(a), cz end)
  ring(function(a) return cx, cy + R * math.cos(a), cz + R * math.sin(a) end)
end

return M
