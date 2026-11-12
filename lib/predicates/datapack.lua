-- Condition: a datapack predicate (predicate=<id> in selectors). Datapack
-- predicates can test almost anything: held items, effects, location, ...
return {
  description = "Datapack predicate",
  params = {
    { name = "id", type = "string", pattern = "^[%w_%-%.]+:[%w_%-%./]+$",
      hint = "Predicate ID from a datapack, e.g. mypack:holding_sword." },
  },
  describe = function(p) return "matching " .. p.id end,
  term = function(p) return { key = "predicate", value = p.id } end,
}
