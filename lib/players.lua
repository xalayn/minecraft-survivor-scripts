-- players: looking up players (positions, who's online). Shared by modules.

local cmd = require("cmd")

local M = {}

--- Whether a string is a valid player name (safe to put in a command).
function M.valid(player)
  return type(player) == "string" and #player <= 16 and player:match("^[%w_]+$") ~= nil
end

--- A player's exact position: { x, y, z, dim }, or nil and an error.
function M.exactPos(player)
  if not M.valid(player) then return nil, "Bad player name" end
  local results = cmd.execAll({
    "data get entity " .. player .. " Pos",
    "data get entity " .. player .. " Dimension",
  })
  local pos = cmd.parsePositions(results[1].out)[1]
  local dim = cmd.lastId(cmd.parseStoredString(results[2].out))
  if not pos or not dim then
    return nil, "Couldn't find player " .. player .. " (online?)"
  end
  return { x = pos.x, y = pos.y, z = pos.z, dim = dim }
end

--- A player's block position and dimension: ok, { x, y, z, dim = ... }.
function M.blockPos(player)
  local p, err = M.exactPos(player)
  if not p then return false, err end
  return true, { math.floor(p.x), math.floor(p.y), math.floor(p.z), dim = p.dim }
end

--- Names of online players (sorted): ok, { name, ... }.
function M.online()
  -- "There are 2 of a max of 20 players online: Steve, Alex"
  local ok, out = commands.exec("list")
  if not ok then return false, out and out[1] or "list failed" end
  local names = {}
  local list = table.concat(out or {}, " "):match("online:%s*(.*)$") or ""
  for name in list:gmatch("[%w_]+") do names[#names + 1] = name end
  table.sort(names)
  return true, names
end

return M
