-- Shape: an upright cylinder standing on a center block.
-- { type = "cylinder", center = { x, y, z }, radius = r, height = h }
-- center is the middle block of the bottom layer; height is in blocks.

local shapes = require("shapes")

local M = {
  description = "Cylinder",
  usage = "<x> <y> <z> <radius> <height>",
  steps = {
    { prompt = "Stand at the center of the cylinder's bottom.", button = "Set center" },
    { prompt = "Stand at its edge (sets the radius).", button = "Set edge" },
    { prompt = "Stand at its top (sets the height).", button = "Set top" },
  },
}

function M.check(s)
  local c, err = shapes.point(s.center, "center")
  if not c then return nil, err end
  local r, rerr = shapes.number(s.radius, "Radius", 1, 256)
  if not r then return nil, rerr end
  local h, herr = shapes.number(s.height, "Height", 1, 1024)
  if not h then return nil, herr end
  return { center = c, radius = math.floor(r), height = math.floor(h) }
end

function M.fromArgs(args, coord)
  if #args ~= 5 then return nil, "cylinder needs " .. M.usage end
  local c = {}
  for i = 1, 3 do
    local n, err = coord(args[i], i)
    if not n then return nil, err end
    c[i] = n
  end
  return M.check({ center = c, radius = tonumber(args[4]), height = tonumber(args[5]) })
end

function M.fromPoints(p)
  local c, e, top = p[1], p[2], p[3]
  local r = math.floor(math.sqrt((e[1] - c[1]) ^ 2 + (e[3] - c[3]) ^ 2) + 0.5)
  return M.check({ center = c, radius = math.max(1, r), height = math.max(1, top[2] - c[2] + 1) })
end

local function geometry(s)
  return s.center[1] + 0.5, s.center[2], s.center[3] + 0.5, s.radius + 0.5, s.height
end

function M.bounds(s)
  local cx, y0, cz, R, h = geometry(s)
  return cx - R, y0, cz - R, cx + R, y0 + h, cz + R
end

function M.contains(s, x, y, z)
  local cx, y0, cz, R, h = geometry(s)
  return (x - cx) ^ 2 + (z - cz) ^ 2 <= R * R and y >= y0 and y <= y0 + h
end

function M.inside(s, x, y, z, half, height)
  local cx, y0, cz, R, h = geometry(s)
  local dx, dz = x - cx, z - cz
  local len = math.sqrt(dx * dx + dz * dz)
  local max = math.max(0, R - half - 0.05)
  if len > max then
    if len == 0 then dx, dz, len = 0, 0, 1 end
    x, z = cx + dx / len * max, cz + dz / len * max
  end
  local top = math.max(y0, y0 + h - height)
  return x, math.max(y0, math.min(top, y)), z
end

function M.spawn(s)
  return s.center[1] + 0.5, s.center[2], s.center[3] + 0.5
end

function M.size(s)
  local d = 2 * s.radius + 1
  return string.format("%dx%dx%d", d, s.height, d)
end

function M.describe(s)
  return string.format("cylinder r%d h%d at %d,%d,%d", s.radius, s.height,
    s.center[1], s.center[2], s.center[3])
end

-- Rings at the bottom and top, joined by vertical lines.
function M.draw(s, d)
  local cx, y0, cz, R, h = geometry(s)
  local n = math.max(12, math.min(48, math.floor(R * 3)))
  for _, y in ipairs({ y0, y0 + h }) do
    for i = 0, n - 1 do
      local a, b = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
      d.segment(cx + R * math.cos(a), y, cz + R * math.sin(a), cx + R * math.cos(b), y, cz + R * math.sin(b))
    end
  end
  for i = 0, 7 do
    local a = 2 * math.pi * i / 8
    local x, z = cx + R * math.cos(a), cz + R * math.sin(a)
    d.segment(x, y0, z, x, y0 + h, z)
  end
end

return M
