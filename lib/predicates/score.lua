-- Condition: the player's score on a scoreboard objective is in a range.
-- Text form: score:kills=3.. (objective=range).
return {
  description = "Score in a range",
  negatable = false,
  params = {
    { name = "objective", type = "string", pattern = "^[%w_%-%.%+]+$", hint = "Scoreboard objective name." },
    { name = "range", type = "string", pattern = "^%-?%d*%.?%.?%-?%d*$",
      hint = "Score range: 3 (exactly), 3.. (3 or more), ..3 (up to 3) or 1..5." },
  },
  describe = function(p) return p.objective .. " score " .. p.range end,
  term = function(p) return { key = "scores", value = p.objective .. "=" .. p.range } end,
  fromText = function(s)
    local obj, range = s:match("^([^=]+)=(.+)$")
    return obj and { objective = obj, range = range }
  end,
  toText = function(p) return p.objective .. "=" .. p.range end,
}
