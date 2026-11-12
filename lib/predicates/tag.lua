-- Condition: the player has a scoreboard tag (/tag <player> add <tag>).
return {
  description = "Has a tag",
  params = {
    { name = "tag", type = "string", pattern = "^[%w_%-%.%+]+$", hint = "Tag name, as given with /tag." },
  },
  describe = function(p) return "tagged " .. p.tag end,
  term = function(p) return { key = "tag", value = p.tag } end,
}
