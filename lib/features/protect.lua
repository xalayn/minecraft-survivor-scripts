-- protect: protect the region with the YAWP mod (Yet Another World Protector).
-- Only available when YAWP is installed.
--
-- Adding it creates a YAWP local region for each of the region's shapes
-- (boxes become Cuboids, spheres Spheres; YAWP has no cylinders, so those are
-- skipped with a warning), named cc-<region>-<n>, with the chosen flags
-- denied. Removing it (or deleting the region) deletes them again; changing
-- the region's shapes recreates them.
--
-- The YAWP regions' names are remembered in command storage (control:yawp),
-- so they can always be cleaned up.

local args = require("args")
local cmd = require("cmd")
local shapes = require("shapes")
local yawp = require("yawp")

local STORE = "control:yawp"

-- Names of the YAWP regions made for a region.
local function made(region)
  local _, out = commands.exec(string.format('data get storage %s regions."%s"', STORE, region.name))
  local names = {}
  for n in (cmd.parseStoredString(out) or ""):gmatch("%S+") do names[#names + 1] = n end
  return names
end

local function remember(region, names)
  if #names == 0 then
    commands.exec(string.format('data remove storage %s regions."%s"', STORE, region.name))
  else
    commands.exec(string.format('data modify storage %s regions."%s" set value "%s"',
      STORE, region.name, table.concat(names, " ")))
  end
end

-- Delete the YAWP regions made for a region.
local function cleanup(region)
  for _, n in ipairs(made(region)) do
    commands.exec(string.format("yawp dim %s delete %s -y", region.dim, n))
  end
  remember(region, {})
end

-- The YAWP area arguments for a shape, or nil if YAWP can't represent it.
local function area(s)
  if s.type == "box" then
    return string.format("Cuboid %d %d %d %d %d %d", s.from[1], s.from[2], s.from[3], s.to[1], s.to[2], s.to[3])
  elseif s.type == "sphere" then
    return string.format("Sphere %d %d %d %d", s.center[1], s.center[2], s.center[3], s.radius)
  end
end

return {
  description = "Protect with YAWP flags",

  -- Only offered when YAWP is installed.
  available = yawp.available,

  options = {
    { name = "flags", type = "list", choices = yawp.FLAG_NAMES, arg = "<flag,...>",
      default = { "break-blocks", "place-blocks", "place-fluids", "scoop-fluids" },
      convert = args.listOf(yawp.FLAG_NAMES), choiceInfo = yawp.FLAG_INFO,
      desc = "YAWP flags to deny, comma-separated",
      hint = "What players can't do inside. Default: building (break/place blocks and fluids)." },
    { name = "members", type = "list", default = {}, arg = "<player,...>",
      convert = args.listOf(nil, "^[%w_]+$"),
      desc = "Players the flags don't apply to",
      hint = "Players the protection doesn't apply to (YAWP members), e.g. crew who need to build." },
    { name = "priority", type = "number", min = 0, max = 10000, arg = "<n>",
      desc = "YAWP priority over overlapping regions",
      hint = "YAWP priority: where YAWP regions overlap, the higher priority one wins. Empty uses YAWP's default." },
    { name = "alerts", default = true, desc = "Don't tell players when blocked",
      hint = "Tell players when something they try is blocked." },
  },

  enable = function(region, s)
    cleanup(region)
    local names, skipped = {}, {}
    for i, shape in ipairs(region.shapes) do
      local a = area(shape)
      if not a then
        skipped[#skipped + 1] = shapes.describe(shape)
      else
        local name = yawp.regionName(region.name, i)
        local base = string.format("yawp local %s %s ", region.dim, name)
        -- Create it, and check it really was: YAWP may answer "success" while
        -- only printing why it refused.
        local createCmd = string.format("yawp dim %s create local %s %s", region.dim, name, a)
        local cok, cout = commands.exec(createCmd)
        local reply = table.concat(cout or {}, " ")
        if not cok or not reply:lower():find("created") then
          cleanup(region)
          return false, string.format("YAWP didn't create %s: %s (%s)", name,
            reply ~= "" and reply or "no reply", createCmd)
        end
        names[#names + 1] = name
        remember(region, names)

        local cmds = {}
        if #s.flags > 0 then cmds[#cmds + 1] = base .. "add flags " .. table.concat(s.flags, " ") end
        if s.priority then cmds[#cmds + 1] = base .. "state priority " .. math.floor(s.priority) end
        if not s.alerts then cmds[#cmds + 1] = base .. "state alert false" end
        for _, p in ipairs(s.members) do cmds[#cmds + 1] = base .. "add player member " .. p end
        local ok, err = yawp.run(cmds)
        if not ok then
          cleanup(region)
          return false, "YAWP: " .. err
        end
      end
    end
    remember(region, names)
    if #names == 0 then
      return false, "YAWP only supports boxes and spheres; this region has neither."
    end
    local msg = string.format("Protected by %d YAWP region(s)", #names)
    local warning
    if #skipped > 0 then
      warning = "Not protected (YAWP has no such shape): " .. table.concat(skipped, ", ")
    end
    return true, msg, warning
  end,

  disable = function(region)
    cleanup(region)
  end,
}
