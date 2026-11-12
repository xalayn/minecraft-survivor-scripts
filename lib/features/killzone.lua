-- killzone: players inside the region are killed or damaged.
--
-- With no options, any non-exempt player whose feet are inside is killed
-- immediately. --delay gives a warning countdown (on the action bar) first, so
-- players can get out. --damage deals that much damage every --interval
-- seconds instead of killing.
--
-- Exempt players: creative and spectator players (unless turned off), and
-- anyone with the ccregion_exempt tag.

local regions = require("regions")
local cmd = require("cmd")

local function warn(player, text)
  return string.format('title %s actionbar {"text":"%s","color":"red"}', player, text)
end

return {
  description = "Kills or damages players inside",

  options = {
    { name = "delay", type = "number", default = 0, min = 0, arg = "<seconds>",
      desc = "Warning countdown first",
      hint = "Seconds of on-screen warning before anything happens, so players can get out. 0 acts at once." },
    { name = "damage", type = "number", min = 0, arg = "<hp>", desc = "Damage instead of kill",
      hint = "Hurt players by this much (2 = one heart) instead of killing them. Empty kills." },
    { name = "interval", type = "number", default = 1, min = 0.05, arg = "<seconds>",
      desc = "Time between damage",
      hint = "Seconds between hits when Damage is set." },
    { name = "damage-type", type = "string", default = "minecraft:magic", arg = "<id>",
      desc = "Damage type (magic ignores armor)", pattern = "^[%w_%-%.:/]+$",
      hint = "Minecraft damage type used for hits. minecraft:magic ignores armor." },
    regions.exemptOptions()[1],
    regions.exemptOptions()[2],
  },

  queries = function(region, s)
    return { regions.positionsQuery(region, regions.notExempt(s)) }
  end,

  -- ctx.state maps player name -> { entered, lastHit, lastWarn } while inside.
  act = function(region, s, ctx, results)
    local actions, seen = {}, {}
    local out = results[regions.positionsQuery(region, regions.notExempt(s))].out
    for _, p in ipairs(cmd.parsePositions(out)) do
      if regions.contains(region, p.x, p.y, p.z) then
        seen[p.name] = true
        local st = ctx.state[p.name]
        if not st then
          st = { entered = ctx.now }
          ctx.state[p.name] = st
        end
        local remaining = s.delay - (ctx.now - st.entered)
        if remaining > 0 then
          local secs = math.ceil(remaining)
          if st.lastWarn ~= secs then
            st.lastWarn = secs
            actions[#actions + 1] = warn(p.name, "Leave this area! " .. secs)
          end
        elseif not s.damage then
          actions[#actions + 1] = "kill " .. p.name
          ctx.state[p.name] = nil
          ctx.log(p.name .. " killed by " .. region.name)
        elseif not st.lastHit or ctx.now - st.lastHit >= s.interval then
          st.lastHit = ctx.now
          actions[#actions + 1] = string.format("damage %s %s %s", p.name, tostring(s.damage),
            s["damage-type"])
        end
      end
    end
    -- Forget players who left (or died).
    for name in pairs(ctx.state) do
      if not seen[name] then ctx.state[name] = nil end
    end
    return actions
  end,
}
