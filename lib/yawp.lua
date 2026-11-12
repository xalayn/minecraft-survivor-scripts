-- yawp: talking to the Yet Another World Protector mod
-- (https://github.com/Z0rdak/Yet-Another-World-Protector), if it's installed.
--
-- YAWP regions are made with its commands (/yawp ...). M.available() checks
-- whether the mod is there by running a harmless command once.

local cmd = require("cmd")

local M = {}

-- Flags that make sense for local regions, with what they prevent (from
-- YAWP's flag list).
M.FLAGS = {
  { "break-blocks", "players breaking blocks" },
  { "place-blocks", "players placing blocks" },
  { "scoop-fluids", "scooping up fluids with buckets" },
  { "place-fluids", "placing fluids" },
  { "use-blocks", "interacting with blocks (e.g. opening containers)" },
  { "access-container", "accessing most containers" },
  { "access-enderchest", "accessing ender chests" },
  { "use-entities", "interacting with entities" },
  { "use-items", "using items" },
  { "use-bonemeal", "using bone meal" },
  { "no-pvp", "players damaging other players" },
  { "melee-players", "melee attacks on players" },
  { "melee-animals", "melee attacks on animals" },
  { "melee-villagers", "melee attacks on villagers" },
  { "melee-monsters", "melee attacks on monsters" },
  { "item-drop", "dropping items" },
  { "item-pickup", "picking up items" },
  { "xp-pickup", "picking up xp" },
  { "exec-command", "players running commands" },
  { "send-msg", "sending chat messages" },
  { "set-spawn", "setting the spawn point" },
  { "sleep", "sleeping" },
  { "no-flight", "flying (forces players to fall)" },
  { "use-elytra", "starting elytra flight" },
  { "fall-damage-players", "players taking fall damage" },
  { "use-portal-players", "players using portals" },
  { "enderpearl-to", "ender pearling into the region" },
  { "enderpearl-from", "ender pearling out of the region" },
  { "no-sign-edit", "editing signs" },
  { "animal-taming", "taming animals" },
  { "animal-breeding", "breeding animals" },
  { "animal-mounting", "mounting animals" },
  { "trample-farmland", "trampling farmland" },
  { "tools-secondary", "stripping wood, tilling, making paths" },
  { "ignite-explosives", "igniting explosives" },
  { "keep-xp", "losing xp on death (players keep it)" },
  { "keep-inv", "losing the inventory on death (players keep it)" },
  { "invincible", "players taking damage" },
  { "no-hunger", "players getting hungry" },
  { "no-knockback", "players being knocked back" },
  { "drop-loot", "all loot drops" },
  { "spawning-all", "all entity spawning" },
  { "spawning-monster", "monster spawning" },
  { "spawning-animal", "animal spawning" },
  { "explosions-blocks", "explosions destroying blocks" },
  { "explosions-entities", "explosions damaging entities" },
  { "fire-tick", "fire spreading" },
  { "fluid-flow", "fluids flowing" },
  { "lightning", "lightning strikes" },
  { "leaf-decay", "leaves decaying" },
  { "snow-fall", "snow layers forming" },
  { "snow-melting", "snow melting" },
  { "no-item-despawn", "items despawning" },
}

M.FLAG_NAMES = {}
M.FLAG_INFO = {}
for i, f in ipairs(M.FLAGS) do
  M.FLAG_NAMES[i] = f[1]
  M.FLAG_INFO[f[1]] = f[2]
end

local availability -- cached: { ok, reason }

--- Whether YAWP is installed (and usable from this computer): ok, reason.
function M.available()
  if not availability then
    local ok, out = commands.exec("yawp dim " .. cmd.dimension() .. " list local")
    local text = table.concat(out or {}, " ")
    if ok then
      availability = { true }
    elseif text:find("[Uu]nknown or incomplete command") or text:find("[Uu]nknown command") then
      availability = { false, "needs the YAWP mod (Yet Another World Protector)" }
    else
      availability = { false, "YAWP didn't respond: " .. text }
    end
  end
  return availability[1], availability[2]
end

--- The YAWP region name for shape n of one of our regions: cc-<region>-<n>.
-- YAWP names must start with a letter, contain only letters, digits and
-- hyphens, end with a letter or digit, and be at least 3 long (checked
-- against YAWP 0.6.3), so other characters in the region name become hyphens.
function M.regionName(regionName, n)
  return "cc-" .. regionName:gsub("[^%w]", "-") .. "-" .. n
end

--- Run YAWP commands in order; returns true, or false and the first error.
function M.run(list)
  for _, c in ipairs(list) do
    local ok, out = commands.exec(c)
    if not ok then return false, (out and out[1] or "failed") .. " (" .. c .. ")" end
  end
  return true
end

return M
