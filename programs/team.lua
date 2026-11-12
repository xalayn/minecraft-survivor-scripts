-- team: manage player teams. Teams are Minecraft teams (/team), so a team's
-- color colors its members' nametags and names in chat and the tab list.
-- Requires a Command Computer (CC:Tweaked). Also manageable from a pocket
-- computer with the control app.
--
-- Usage:
--   team list
--   team info <team>
--   team create <team> [options]
--   team set <team> [options]
--   team delete <team> [-y]
--   team join <team> <player> [player...]
--   team leave <player> [player...]
--   team empty <team>
--   team options
--
--   create   Make a team (or take over an existing Minecraft team with that
--            ID). IDs: letters, numbers, _ - . +, up to 16 characters.
--   set      Change the given settings of a team; others stay as they are.
--   delete   Delete a team; its members become teamless. Asks unless -y.
--   join     Put players on a team (moving them off any other team).
--   leave    Take players off their team.
--   empty    Take everyone off a team.
--   options  List the team settings.
--
-- Settings (for create and set):
--   --display-name <text>   Name shown in chat and the tab list.
--   --color <color>         Nametag/chat color: white, gray, dark_gray, black,
--                           red, dark_red, gold, yellow, green, dark_green,
--                           aqua, dark_aqua, blue, dark_blue, light_purple,
--                           dark_purple (default white).
--   --no-friendly-fire      Teammates can't hurt each other.
--   --nametags <who>        always, never, hideForOtherTeams, hideForOwnTeam.
--   --collision <rule>      always, never, pushOtherTeams, pushOwnTeam.
--   --no-see-invisible      Members can't see invisible teammates.
--
-- Examples:
--   team create red --color red --display-name "Red Team"
--   team join red Steve Alex
--   team set red --color dark_red --no-friendly-fire
--   team leave Steve
--   team delete red

package.path = "/lib/?.lua;" .. package.path
local argparse = require("args")
local teams = require("teams")

if not commands then
  printError("team requires a Command Computer")
  return
end

local function usage()
  print("Usage:")
  print("  team list | info <team> | options")
  print("  team create <team> [options]")
  print("  team set <team> [options]")
  print("  team delete <team> [-y]")
  print("  team join <team> <player...>")
  print("  team leave <player...>")
  print("  team empty <team>")
end

local raw = { ... }
local sub = raw[1]

local function rest(from)
  local r = {}
  for i = from, #raw do r[#r + 1] = raw[i] end
  return r
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function describe(t)
  local name = (t["display-name"] and t["display-name"] ~= "") and (" \"" .. t["display-name"] .. "\"") or ""
  return string.format("%s%s  %s, %d member(s)", t.id, name, t.color, #t.members)
end

-- Parse team settings from the arguments after the team ID. With onlyGiven,
-- settings not on the command line are left out (instead of defaulted).
local function settingsFrom(from, onlyGiven)
  local spec = teams.OPTIONS
  if onlyGiven then
    spec = {}
    for i, o in ipairs(teams.OPTIONS) do
      local c = {}
      for k, v in pairs(o) do c[k] = v end
      c.default = nil
      spec[i] = c
    end
  end
  local pos, opts = argparse.parse(spec, rest(from))
  if not pos then
    printError(opts)
    print("Settings:")
    for _, line in ipairs(argparse.help(teams.OPTIONS)) do print(line) end
    return nil
  end
  if #pos > 0 then
    printError("Unexpected argument: " .. pos[1])
    return nil
  end
  return opts
end

local function report(ok, result, success)
  if not ok then return printError(result) end
  if success then print(success) end
  return result
end

local handlers = {}

function handlers.list()
  local _, all = teams.list()
  local ids = sortedKeys(all)
  if #ids == 0 then return print("No teams.") end
  for _, id in ipairs(ids) do print(describe(all[id])) end
end

function handlers.info()
  local ok, t = teams.get(raw[2])
  if not ok then return printError(t) end
  print(describe(t))
  for _, o in ipairs(teams.OPTIONS) do
    if o.name ~= "display-name" and o.name ~= "color" then
      print("  " .. o.name .. ": " .. tostring(t[o.name]))
    end
  end
  print("  members: " .. (#t.members > 0 and table.concat(t.members, ", ") or "none"))
end

function handlers.create()
  if not raw[2] then return usage() end
  local s = settingsFrom(3)
  if not s then return end
  local ok, t = teams.create(raw[2], s)
  if not ok then return printError(t) end
  print("Created " .. describe(t))
end

function handlers.set()
  if not raw[2] then return usage() end
  local given = settingsFrom(3, true)
  if not given then return end
  local ok, current = teams.get(raw[2])
  if not ok then return printError(current) end
  -- Change only the settings given; keep the rest.
  local s = {}
  for _, o in ipairs(teams.OPTIONS) do
    if given[o.name] ~= nil then s[o.name] = given[o.name] else s[o.name] = current[o.name] end
  end
  local t
  ok, t = teams.set(raw[2], s)
  if not ok then return printError(t) end
  print("Updated " .. describe(t))
end

function handlers.delete()
  local pos, opts = argparse.parse({ { name = "yes", short = "y" } }, rest(2))
  if not pos then return printError(opts) end
  if not pos[1] then return usage() end
  if not opts.yes then
    write("Delete team " .. pos[1] .. "? [y/N] ")
    local answer = (read() or ""):lower()
    if answer ~= "y" and answer ~= "yes" then return print("Cancelled.") end
  end
  report(teams.delete(pos[1]), nil, "Deleted team " .. pos[1])
end

function handlers.join()
  if not raw[2] or not raw[3] then return usage() end
  local names = rest(3)
  report(teams.join(raw[2], names), nil, "Added " .. table.concat(names, ", ") .. " to " .. raw[2])
end

function handlers.leave()
  if not raw[2] then return usage() end
  local names = rest(2)
  report(teams.leave(names), nil, "Removed " .. table.concat(names, ", ") .. " from their team")
end

function handlers.empty()
  if not raw[2] then return usage() end
  report(teams.empty(raw[2]), nil, "Emptied team " .. raw[2])
end

function handlers.options()
  for _, line in ipairs(argparse.help(teams.OPTIONS)) do print(line) end
end

local handler = sub and handlers[sub]
if not handler then
  if sub then printError("Unknown command: " .. sub) end
  usage()
  return
end
handler()
