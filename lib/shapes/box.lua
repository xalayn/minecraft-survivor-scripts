-- Shape: a box between two corner blocks (both included).
-- { type = "box", from = { x, y, z }, to = { x, y, z } }

local shapes = require("shapes")

local M = {
  description = "Box",
  usage = "<x1> <y1> <z1> <x2> <y2> <z2>",
  steps = {
    { prompt = "Stand at one corner of the box.", button = "Set first corner" },
    { prompt = "Stand at the opposite corner.", button = "Set second corner" },
  },
}

function M.check(s)
  local a, err = shapes.point(s.from, "corner")
  if not a then return nil, err end
  local b, err2 = shapes.point(s.to, "corner")
  if not b then return nil, err2 end
  return {
    from = { math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3]) },
    to = { math.max(a[1], b[1]), math.max(a[2], b[2]), math.max(a[3], b[3]) },
  }
end

function M.fromArgs(args, coord)
  if #args ~= 6 then return nil, "box needs " .. M.usage end
  local v = {}
  for i = 1, 6 do
    local n, err = coord(args[i], (i - 1) % 3 + 1)
    if not n then return nil, err end
    v[i] = n
  end
  return M.check({ from = { v[1], v[2], v[3] }, to = { v[4], v[5], v[6] } })
end

function M.fromPoints(p)
  return M.check({ from = p[1], to = p[2] })
end

function M.bounds(s)
  return s.from[1], s.from[2], s.from[3], s.to[1] + 1, s.to[2] + 1, s.to[3] + 1
end

function M.contains(s, x, y, z)
  local x0, y0, z0, x1, y1, z1 = M.bounds(s)
  return x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1
end

local function clamp(v, lo, hi)
  if hi < lo then return (lo + hi) / 2 end
  return math.max(lo, math.min(hi, v))
end

function M.inside(s, x, y, z, half, height)
  local x0, y0, z0, x1, y1, z1 = M.bounds(s)
  return clamp(x, x0 + half, x1 - half), clamp(y, y0, math.max(y0, y1 - height)), clamp(z, z0 + half, z1 - half)
end

function M.spawn(s)
  local x0, y0, z0, x1, _, z1 = M.bounds(s)
  return (x0 + x1) / 2, y0, (z0 + z1) / 2
end

function M.size(s)
  return string.format("%dx%dx%d", s.to[1] - s.from[1] + 1, s.to[2] - s.from[2] + 1, s.to[3] - s.from[3] + 1)
end

function M.describe(s)
  return string.format("box %s at %d,%d,%d", M.size(s), s.from[1], s.from[2], s.from[3])
end

-- Edges are centered on the boundary (half inside, half outside) so none of
-- their faces are coplanar with block faces (no z-fighting with terrain). X
-- edges run the full length including the corner cubes; Y and Z edges stop
-- short of the corners so edges never overlap. Walls (two one-sided panels
-- back to back) fill the space between the edges, inset slightly.
function M.draw(s, d)
  local x0, y0, z0, x1, y1, z1 = M.bounds(s)
  local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
  local t = d.thickness
  local h = t / 2
  for _, a in ipairs({ y0 - h, y1 - h }) do
    for _, b in ipairs({ z0 - h, z1 - h }) do d.edge(x0 - h, a, b, dx + t, t, t) end
  end
  for _, a in ipairs({ x0 - h, x1 - h }) do
    for _, b in ipairs({ z0 - h, z1 - h }) do d.edge(a, y0 + h, b, t, dy - t, t) end
  end
  for _, a in ipairs({ x0 - h, x1 - h }) do
    for _, b in ipairs({ y0 - h, y1 - h }) do d.edge(a, b, z0 + h, t, t, dz - t) end
  end
  if d.walls then
    local e = d.wallInset
    local ix, iy, iz = dx - t, dy - t, dz - t
    for _, px in ipairs({ x0 + e, x1 - e }) do
      d.panel("-x", px, y0 + h, z0 + h, iz, iy)
      d.panel("+x", px, y0 + h, z1 - h, iz, iy)
    end
    for _, py in ipairs({ y0 + e, y1 - e }) do
      d.panel("-y", x0 + h, py, z0 + h, ix, iz)
      d.panel("+y", x0 + h, py, z1 - h, ix, iz)
    end
    for _, pz in ipairs({ z0 + e, z1 - e }) do
      d.panel("+z", x0 + h, y0 + h, pz, ix, iy)
      d.panel("-z", x1 - h, y0 + h, pz, ix, iy)
    end
  end
end

return M
