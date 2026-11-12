-- teams: player teams, built on Minecraft's own teams (/team), so a team's
-- color colors its members' nametags and names in chat and the tab list.
--
-- Each team's settings are kept in command storage (control:teams, saved with
-- the world) and applied to the Minecraft team. Members aren't stored: they're
-- read from the game, so /team join in chat shows up here too.
--
-- Shared by the team program and the control server's teams module. Every
-- function returns true and a result, or false and an error message; inputs
-- may come from the network, so everything is validated.

local args = require("args")
local cmd = require("cmd")
local players = require("players")

local M = {}

local STORE = "control:teams"

-- Minecraft's team colors.
M.COLORS = {
  "white", "gray", "dark_gray", "black", "red", "dark_red", "gold", "yellow",
  "green", "dark_green", "aqua", "dark_aqua", "blue", "dark_blue", "light_purple", "dark_purple",
}

--- Team settings (see lib/args.lua for the format).
M.OPTIONS = {
  { name = "display-name", type = "string", arg = "<text>", desc = "Name shown in chat and tab list",
    pattern = "^[%w _%-%.!?&()+']*$",
    hint = "Name shown in chat and the tab list. Letters, numbers, spaces and simple punctuation. Empty uses the team ID." },
  { name = "color", type = "string", default = "white", arg = "<color>", choices = M.COLORS,
    desc = "Nametag and chat color",
    hint = "Color of members' nametags and their names in chat and the tab list." },
  { name = "friendly-fire", default = true, desc = "Teammates can't hurt each other",
    hint = "Teammates can hurt each other." },
  { name = "nametags", type = "string", default = "always", arg = "<who>",
    choices = { "always", "never", "hideForOtherTeams", "hideForOwnTeam" },
    desc = "Who sees members' nametags",
    hint = "Who can see members' nametags: always, never, hideForOtherTeams (only teammates see them) or hideForOwnTeam." },
  { name = "collision", type = "string", default = "always", arg = "<rule>",
    choices = { "always", "never", "pushOtherTeams", "pushOwnTeam" },
    desc = "Who members push",
    hint = "Whether members push and get pushed: always, never, pushOtherTeams (only other teams) or pushOwnTeam." },
  { name = "see-invisible", default = true, desc = "Can't see invisible teammates",
    hint = "Members can see invisible teammates (as see-through)." },
}

--- Whether a string is a valid team ID.
function M.validId(id)
  return type(id) == "string" and #id >= 1 and #id <= 16 and id:match("^[%w_%-%.%+]+$") ~= nil
end

local function badId(id)
  return "Bad team ID '" .. tostring(id) .. "' (letters, numbers, _ - . +, up to 16)"
end

---------------------------------------------------------------------------
-- Store.

local function stored()
  local ok, out = commands.exec("data get storage " .. STORE .. " teams")
  local result = {}
  if not ok then return result end
  for id, json in pairs(cmd.parseStringCompound(out)) do
    local okDecode, s = pcall(textutils.unserialiseJSON, json)
    if okDecode and type(s) == "table" then result[id] = s end
  end
  return result
end

local function save(id, s)
  local ok, out = commands.exec(string.format('data modify storage %s teams."%s" set value %s',
    STORE, id, cmd.snbtQuote(textutils.serialiseJSON(s))))
  if not ok then return false, out and out[1] end
  return true
end

local function forget(id)
  commands.exec(string.format('data remove storage %s teams."%s"', STORE, id))
end

-- Members of Minecraft teams, by ID (one batch of commands).
local function membersOf(ids)
  local cmds = {}
  for i, id in ipairs(ids) do cmds[i] = "team list " .. id end
  local result = {}
  for i, r in ipairs(cmd.execAll(cmds)) do
    -- "Team [Red] has 2 members: Steve, Alex" / "There are no members on team [Red]"
    local list = r.ok and table.concat(r.out, " "):match("member[^:]*:%s*(.*)$") or ""
    local names = {}
    for name in list:gmatch("[%w_]+") do names[#names + 1] = name end
    table.sort(names)
    result[ids[i]] = names
  end
  return result
end

-- Apply settings to the Minecraft team.
local function apply(id, s)
  local display = (s["display-name"] and s["display-name"] ~= "") and s["display-name"] or id
  local results = cmd.execAll({
    string.format('team modify %s displayName {"text":"%s"}', id, display),
    "team modify " .. id .. " color " .. s.color,
    "team modify " .. id .. " friendlyFire " .. tostring(s["friendly-fire"]),
    "team modify " .. id .. " nametagVisibility " .. s.nametags,
    "team modify " .. id .. " collisionRule " .. s.collision,
    "team modify " .. id .. " seeFriendlyInvisibles " .. tostring(s["see-invisible"]),
  })
  for _, r in ipairs(results) do
    -- "Nothing changed" counts as failure in Minecraft but is fine here.
    local msg = r.out[1] or ""
    if not r.ok and not msg:find("[Nn]othing changed") and not msg:find("already") then
      return false, msg
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Operations.

--- All teams: ok, { <id> = { id, settings..., members = { ... } } }.
function M.list()
  local all = stored()
  local ids = {}
  for id in pairs(all) do ids[#ids + 1] = id end
  local members = membersOf(ids)
  for id, s in pairs(all) do
    s.id = id
    s.members = members[id] or {}
  end
  return true, all
end

--- One team.
function M.get(id)
  if not M.validId(id) then return false, badId(id) end
  local s = stored()[id]
  if not s then return false, "No team '" .. id .. "'" end
  s.id = id
  s.members = membersOf({ id })[id]
  return true, s
end

--- Create a team (or take over an existing Minecraft team with that ID).
function M.create(id, values)
  if not M.validId(id) then return false, badId(id) end
  if stored()[id] then return false, "Team '" .. id .. "' already exists" end
  local s, err = args.validate(M.OPTIONS, values or {})
  if not s then return false, err end
  local ok, out = commands.exec("team add " .. id)
  if not ok and not (out[1] or ""):find("already") then return false, out[1] or "team add failed" end
  local applied, aerr = apply(id, s)
  if not applied then return false, aerr end
  save(id, s)
  return M.get(id)
end

--- Change a team's settings (missing ones get defaults).
function M.set(id, values)
  if not M.validId(id) then return false, badId(id) end
  if not stored()[id] then return false, "No team '" .. id .. "'" end
  local s, err = args.validate(M.OPTIONS, values or {})
  if not s then return false, err end
  commands.exec("team add " .. id) -- in case it was removed with /team
  local applied, aerr = apply(id, s)
  if not applied then return false, aerr end
  save(id, s)
  return M.get(id)
end

--- Delete a team (its members become teamless).
function M.delete(id)
  if not M.validId(id) then return false, badId(id) end
  if not stored()[id] then return false, "No team '" .. id .. "'" end
  commands.exec("team remove " .. id)
  forget(id)
  return true
end

local function checkPlayers(list)
  if type(list) == "string" then list = { list } end
  if type(list) ~= "table" or #list == 0 then return nil, "No players given" end
  for _, p in ipairs(list) do
    if not players.valid(p) then return nil, "Bad player name '" .. tostring(p) .. "'" end
  end
  return list
end

--- Put players on a team (moving them from any other team).
function M.join(id, list)
  if not M.validId(id) then return false, badId(id) end
  if not stored()[id] then return false, "No team '" .. id .. "'" end
  local names, err = checkPlayers(list)
  if not names then return false, err end
  local ok, out = commands.exec("team join " .. id .. " " .. table.concat(names, " "))
  if not ok then return false, out[1] or "team join failed" end
  return true
end

--- Take players off whatever team they're on.
function M.leave(list)
  local names, err = checkPlayers(list)
  if not names then return false, err end
  local ok, out = commands.exec("team leave " .. table.concat(names, " "))
  if not ok then return false, out[1] or "team leave failed" end
  return true
end

--- Remove all players from a team.
function M.empty(id)
  if not M.validId(id) then return false, badId(id) end
  commands.exec("team empty " .. id)
  return true
end

--- The settings' definitions without functions (for sending to the app).
function M.options()
  local out = {}
  for i, o in ipairs(M.OPTIONS) do
    local c = {}
    for k, v in pairs(o) do if type(v) ~= "function" then c[k] = v end end
    out[i] = c
  end
  return true, out
end

return M
