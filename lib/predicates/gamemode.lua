-- Condition: the player is in a game mode.
return {
  description = "In a game mode",
  params = {
    { name = "mode", type = "string", default = "survival",
      choices = { "survival", "creative", "adventure", "spectator" }, hint = "The game mode." },
  },
  describe = function(p) return "in " .. p.mode end,
  term = function(p) return { key = "gamemode", value = p.mode } end,
}
