-- Condition: the player is on a team (see the team program / Teams module).
return {
  description = "On a team",
  params = {
    { name = "team", type = "string", pattern = "^[%w_%-%.%+]+$", hint = "Team ID, e.g. blue." },
  },
  describe = function(p) return "on team " .. p.team end,
  term = function(p) return { key = "team", value = p.team } end,
}
