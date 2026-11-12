-- Condition: the player's experience level is in a range.
return {
  description = "XP level in a range",
  negatable = false,
  params = {
    { name = "range", type = "string", pattern = "^%d*%.?%.?%d*$",
      hint = "Level range: 5 (exactly), 5.. (5 or more), ..5 (up to 5) or 5..10." },
  },
  describe = function(p) return "level " .. p.range end,
  term = function(p) return { key = "level", value = p.range } end,
}
