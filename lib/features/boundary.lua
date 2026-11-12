-- boundary: players can't leave the region.
--
-- Any non-exempt player whose feet are inside the region is confined to it:
-- players outside are unaffected, but once they enter they can't leave. A
-- confined player who crosses the edge (walking, flying, ender pearls,
-- respawning elsewhere, changing dimension) is teleported back to the nearest
-- point just inside it. Confinement is a tag on the player
-- (ccregion_bound_<region>), so it survives death and relogging.
--
-- Exempt players are never confined, and are released as soon as they become
-- exempt: creative and spectator players (unless turned off), and anyone with
-- the ccregion_exempt tag. To free yourself if you get stuck:
--   /tag @s add ccregion_exempt

local regions = require("regions")
local cmd = require("cmd")

local HALF_WIDTH = 0.3 -- player hitbox half-width
local HEIGHT = 1.8     -- player hitbox height

local function tagOf(region)
  return "ccregion_bound_" .. region.name
end

local function clamp(v, lo, hi)
  if hi < lo then return (lo + hi) / 2 end
  return math.max(lo, math.min(hi, v))
end

-- Nearest position inside the region where a player's whole hitbox fits.
local function pullBack(region, x, y, z)
  local X0, Y0, Z0, X1, Y1, Z1 = regions.bounds(region)
  return clamp(x, X0 + HALF_WIDTH, X1 - HALF_WIDTH),
    clamp(y, Y0, math.max(Y0, Y1 - HEIGHT)),
    clamp(z, Z0 + HALF_WIDTH, Z1 - HALF_WIDTH)
end

-- The two queries whose output act() reads.
local function confinedQuery(region, s)
  return string.format("execute in %s as @a[tag=%s,distance=0..,%s] run data get entity @s Pos",
    region.dim, tagOf(region), regions.notExempt(s))
end

local function candidatesQuery(region, s)
  return regions.positionsQuery(region, "tag=!" .. tagOf(region) .. "," .. regions.notExempt(s))
end

return {
  description = "Players can't leave",

  options = regions.exemptOptions(),

  disable = function(region)
    commands.exec("tag @a remove " .. tagOf(region))
  end,

  queries = function(region, s)
    local tag = tagOf(region)
    local X0, Y0, Z0, X1, _, Z1 = regions.bounds(region)
    local q = {
      confinedQuery(region, s),
      candidatesQuery(region, s),
      -- Confined players who left the dimension go back to the middle of the floor.
      string.format("execute as @a[tag=%s,%s] at @s unless dimension %s in %s run tp @s %.2f %d %.2f",
        tag, regions.notExempt(s), region.dim, region.dim, (X0 + X1) / 2, Y0, (Z0 + Z1) / 2),
      -- Players who became exempt are released.
      string.format("tag @a[tag=%s,tag=%s] remove %s", tag, regions.EXEMPT_TAG, tag),
    }
    for _, m in ipairs(regions.exemptModes(s)) do
      q[#q + 1] = string.format("tag @a[tag=%s,gamemode=%s] remove %s", tag, m, tag)
    end
    return q
  end,

  act = function(region, s, ctx, results)
    local actions = {}
    for _, p in ipairs(cmd.parsePositions(results[confinedQuery(region, s)].out)) do
      if not regions.contains(region, p.x, p.y, p.z) then
        local x, y, z = pullBack(region, p.x, p.y, p.z)
        actions[#actions + 1] = string.format("execute in %s run tp %s %.3f %.3f %.3f",
          region.dim, p.name, x, y, z)
      end
    end
    for _, p in ipairs(cmd.parsePositions(results[candidatesQuery(region, s)].out)) do
      if regions.contains(region, p.x, p.y, p.z) then
        actions[#actions + 1] = string.format("tag %s add %s", p.name, tagOf(region))
        ctx.log(p.name .. " confined to " .. region.name)
      end
    end
    return actions
  end,
}
