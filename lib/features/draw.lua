-- draw: show the region as a box (see the box program). The drawing is made
-- when the feature is added and removed with it; it needs no regiond.

local boxdraw = require("boxdraw")

local function boxName(region)
  return "region_" .. region.name
end

return {
  description = "Show the region as a box",

  options = {
    { name = "block", type = "string", default = boxdraw.DEFAULT_BLOCK, arg = "<block>", desc = "Edge block",
      pattern = "^[%w_%-%.:/]+$" },
    { name = "walls", default = true, desc = "No walls" },
    { name = "opacity", type = "number", default = boxdraw.DEFAULT_OPACITY, min = 0, max = 100,
      arg = "<0-100>", desc = "Wall opacity %" },
    { name = "wall-color", type = "string", arg = "<color>", desc = "Dye name or RRGGBB",
      check = function(v) if not boxdraw.parseColor(v) then return "not a color" end end },
    { name = "xray", desc = "Edges visible through blocks" },
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
