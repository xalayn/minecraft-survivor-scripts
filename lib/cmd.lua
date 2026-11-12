-- cmd: helpers for Command Computer programs.
--
--   package.path = "/lib/?.lua;" .. package.path
--   local cmd = require("cmd")

local M = {}

--- Run commands concurrently and return { ok = bool, out = {lines} } for each,
-- in order. Unlike commands.exec, which waits a server tick per command, these
-- can all complete within the same tick.
function M.execAll(cmds)
  local index, results, pending = {}, {}, 0
  for i, c in ipairs(cmds) do
    index[commands.execAsync(c)] = i
    pending = pending + 1
  end
  while pending > 0 do
    local _, id, taskOk, ok, out = os.pullEvent("task_complete")
    local i = index[id]
    if i then
      index[id] = nil
      pending = pending - 1
      if taskOk then
        results[i] = { ok = ok, out = out or {} }
      else
        results[i] = { ok = false, out = { tostring(ok) } } -- task error message
      end
    end
  end
  return results
end

--- Run a command in a dimension.
function M.execIn(dim, c)
  return commands.exec("execute in " .. dim .. " run " .. c)
end

-- The last namespaced ID ("minecraft:overworld") in a string, if any.
function M.lastId(s)
  local id
  for m in (s or ""):gmatch("[%w_%-%.]+:[%w_%-%./]*[%w_%-%.]") do id = m end
  return id
end

local currentDim
--- The computer's dimension, e.g. "minecraft:overworld". There's no command
-- that just prints it, but forceload query's message names it, forced or not.
-- Depending on the version, the message shows the dimension as a plain ID or
-- wrapped ("ResourceKey[minecraft:dimension / minecraft:overworld]"); the
-- dimension's ID is the last namespaced ID in it.
function M.dimension()
  if not currentDim then
    local x, _, z = commands.getBlockPosition()
    local _, out = commands.exec(string.format("forceload query %d %d", x, z))
    currentDim = M.lastId((out and out[1] or ""):match(" in (.-) is ")) or "minecraft:overworld"
  end
  return currentDim
end

--- Make a name safe for use in entity tags and selectors.
function M.sanitize(name)
  return (name:gsub("[^%w_%-%.%+]", "_"))
end

--- Parse a block coordinate, accepting ~ / ~5 relative to the computer.
-- axis is 1, 2 or 3 for x, y, z.
function M.parseCoord(s, axis)
  local rel = s:match("^~(.*)$")
  if rel then
    local off = rel == "" and 0 or tonumber(rel)
    if not off then return nil, "Bad coordinate: " .. s end
    local origin = { commands.getBlockPosition() }
    return math.floor(origin[axis] + off)
  end
  local n = tonumber(s)
  if not n then return nil, "Bad coordinate: " .. s end
  return math.floor(n)
end

--- Parse two corners from args[first..first+5] (x1 y1 z1 x2 y2 z2) into an
-- area { x0, y0, z0, x1, y1, z1 } of inclusive block coordinates with
-- x0 <= x1 etc. Returns nil and an error message on bad input.
function M.parseArea(args, first)
  first = first or 1
  local v = {}
  for i = 0, 5 do
    if args[first + i] == nil then return nil, "Expected 6 coordinates" end
    local n, err = M.parseCoord(args[first + i], i % 3 + 1)
    if not n then return nil, err end
    v[i + 1] = n
  end
  return {
    math.min(v[1], v[4]), math.min(v[2], v[5]), math.min(v[3], v[6]),
    math.max(v[1], v[4]), math.max(v[2], v[5]), math.max(v[3], v[6]),
  }
end

return M
