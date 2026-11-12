-- Teams module, control app screens: team list, a team's members (add from
-- online players or by name, tap to remove), team settings (color, name,
-- friendly fire, nametags, ...), creating and deleting teams.

local kit -- set in open()
local C

local listScreen, teamScreen

local function nameOf(t)
  return (t["display-name"] and t["display-name"] ~= "") and t["display-name"] or t.id
end

local optionCache
local function options()
  if not optionCache then optionCache = kit.call("teams.options") end
  return optionCache
end

---------------------------------------------------------------------------
-- Settings (also used to create a team).

local function settingsScreen(id, current)
  local opts = options()
  if not opts then return end
  local title = current and (id .. " - settings") or ("New team: " .. id)
  kit.newScreen(title, current and kit.backTo(teamScreen, id) or kit.backTo(listScreen))
  local _, y = kit.addText(3, "Tap a name for help.", C.faint)
  local read = kit.addForm(y + 1, kit.H - 2, opts, current)
  kit.addBottomButtons({ current and "Save" or "Create team", "primary", function()
    local v, err = read()
    if not v then return kit.toast(err, "error", 4) end
    local t = kit.call(current and "teams.set" or "teams.create", id, v)
    if t then teamScreen(id, { (current and "Saved " or "Created ") .. nameOf(t) .. ".", "success" }) end
  end })
end

local function newTeam()
  kit.prompt("New team", "Team ID (letters, numbers, _ - . +, up to 16):", "", function(id)
    if id ~= "" then settingsScreen(id, nil) end
  end)
end

---------------------------------------------------------------------------
-- Adding players.

local function addPlayersScreen(t)
  local token = kit.newScreen(nameOf(t) .. " - add", kit.backTo(teamScreen, t.id))
  kit.addText(3, "Tap players to add them. Players on another team are moved.")
  local list = kit.addList(6, kit.H - 2, "Loading...")
  kit.addBottomButtons({ "Type a name", "neutral", function()
    kit.prompt("Add player", "Player name:", "", function(name)
      if name ~= "" and kit.call("teams.join", t.id, { name }) then
        kit.toast("Added " .. name .. ".", "success")
      end
    end)
  end })

  local online = kit.call("core.players")
  if not kit.isCurrent(token) then return end
  local members = {}
  for _, m in ipairs(t.members) do members[m] = true end
  for _, name in ipairs(online or {}) do
    if not members[name] then
      kit.addItem(list, name, function()
        if kit.call("teams.join", t.id, { name }) then
          members[name] = true
          kit.toast("Added " .. name .. ".", "success")
        end
      end)
    end
  end
  list.emptyText = online and "No other players online." or "Couldn't get players."
end

---------------------------------------------------------------------------
-- A team.

function teamScreen(id, flash)
  local token = kit.newScreen(id, kit.backTo(listScreen), flash)
  local t = kit.call("teams.get", id)
  if not kit.isCurrent(token) or not t then return end

  local y = kit.addCard(3, {
    { "Name", nameOf(t) },
    { "Color", t.color, kit.MC_COLORS[t.color] },
    { "Size", #t.members .. " player" .. (#t.members == 1 and "" or "s") },
  })
  kit.root:addLabel({ x = 2, y = y + 1, text = "Members", foreground = C.muted })
  kit.addButton(kit.root, kit.W - 7, y + 1, 7, "+ Add", "primary", function() addPlayersScreen(t) end)
  local list = kit.addList(y + 3, kit.H - 2, "No members yet.")
  for _, name in ipairs(t.members) do
    kit.addItem(list, name, function()
      kit.confirm(nameOf(t), "Remove " .. name .. " from the team?", function()
        if kit.call("teams.leave", { name }) then
          teamScreen(id, { "Removed " .. name .. ".", "success" })
        end
      end)
    end)
  end

  kit.addBottomButtons(
    { "Settings", "neutral", function() settingsScreen(id, t) end },
    { "Delete", "danger", function()
      kit.confirm(nameOf(t), "Delete team " .. nameOf(t) .. "? Its members become teamless.", function()
        if kit.call("teams.delete", id) then listScreen({ "Deleted " .. nameOf(t) .. ".", "success" }) end
      end)
    end })
end

---------------------------------------------------------------------------
-- Team list.

function listScreen(flash)
  local token = kit.newScreen("Teams", kit.home, flash)
  local list = kit.addList(3, kit.H - 2, "Loading...")
  kit.addBottomButtons({ "+ New team", "primary", newTeam })

  local all = kit.call("teams.list")
  if not kit.isCurrent(token) then return end
  for _, id in ipairs(kit.sortedKeys(all)) do
    local t = all[id]
    local label = nameOf(t) .. " (" .. #t.members .. ")"
    local color = kit.MC_COLORS[t.color]
    if color == colors.black then color = C.faint end -- visible on the black background
    kit.addItem(list, label, function() teamScreen(id) end, color)
  end
  list.emptyText = all and "No teams yet." or "Couldn't load teams."
end

return {
  title = "Teams",
  order = 20,
  open = function(k)
    kit, C = k, k.C
    listScreen()
  end,
}
