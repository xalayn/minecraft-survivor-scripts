-- draw: show the region as a box (see the box program). The drawing is made
-- when the feature is added and removed with it; it needs no controld.

local boxdraw = require("boxdraw")

local function boxName(region)
  return "region_" .. region.name
end

return {
  description = "Show the region as a box",

  options = {
    { name = "block", type = "string", default = boxdraw.DEFAULT_BLOCK, arg = "<block>", desc = "Edge block",
      pattern = "^[%w_%-%.:/]+$",
      hint = "Block the edges are made of, e.g. red_concrete. Its color also colors the walls." },
    { name = "walls", default = true, desc = "No walls",
      hint = "Fill the sides with see-through walls. Off shows only the edges." },
    { name = "opacity", type = "number", default = boxdraw.DEFAULT_OPACITY, min = 0, max = 100,
      arg = "<0-100>", desc = "Wall opacity %",
      hint = "How solid the walls look, 0-100. Below about 10 they may not show at all." },
    { name = "wall-color", type = "string", arg = "<color>", desc = "Dye name or RRGGBB",
      check = function(v) if not boxdraw.parseColor(v) then return "not a color" end end,
      hint = "Wall color: a dye name like light_blue, or a hex color like 00ffff. Empty matches the edges." },
    { name = "xray", desc = "Edges visible through blocks",
      hint = "Make the edges glow so they show through blocks. Some shader packs hide this." },
  },

  enable = function(region, s)
    return boxdraw.draw(boxName(region), region.area, {
      block = s.block,
      walls = s.walls,
      opacity = s.opacity,
      wallColor = s["wall-color"],
      xray = s.xray,
      dim = region.dim,
    })
  end,

  disable = function(region)
    boxdraw.remove(boxName(region), true)
  end,
}
