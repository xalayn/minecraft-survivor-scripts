-- Condition: a specific player.
return {
  description = "A specific player",
  params = {
    { name = "name", type = "string", pattern = "^[%w_]+$", hint = "Player name." },
  },
  describe = function(p) return p.name end,
  term = function(p) return { key = "name", value = p.name } end,
}
