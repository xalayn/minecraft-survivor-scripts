-- Regions module, control app screens: searchable region list with "You're
-- in", region details, features (as forms built from their options),
-- teleporting, and creating regions by walking to two corners.

local shapes = require("shapes")

local kit -- set in open()
local C

local mainScreen, regionScreen

---------------------------------------------------------------------------
-- Features.

local featureCache
local function features()
  if not featureCache then
    local list = kit.call("regions.features")
    if not list then return nil end
    featureCache = {}
    for _, f in ipairs(list) do featureCache[f.name] = f end
  end
  return featureCache
end

-- The settings of one feature on a region. current: its settings if added;
-- warning: its current warning, if any (shown at the top).
local function featureForm(regionName, info, current, warning)
  local title = regionName .. " - " .. info.name
  kit.newScreen(title, kit.backTo(regionScreen, regionName))
  local _, y = kit.addText(3, info.description or info.name)
  if warning then _, y = kit.addText(y + 1, "! " .. warning, C.warn) end
  if #info.options > 0 then _, y = kit.addText(y, "Tap a name for help.", C.faint) end
  local read = kit.addForm(y + 1, kit.H - 2, info.options, current)

  local function save()
    local v, err = read()
    if not v then return kit.toast(err, "error", 4) end
    local result = kit.call("regions.setFeature", regionName, info.name, v)
    if not result then return end
    local text = (current and "Saved " or "Added ") .. info.name
    if type(result) == "table" and result.warning then
      regionScreen(regionName, { text .. ". " .. result.warning, "warning" })
    elseif type(result) == "table" and result.needsDaemon then
      regionScreen(regionName, { text .. ", but controld isn't running.", "warning" })
    else
      regionScreen(regionName, { text .. ".", "success" })
    end
  end
  local function remove()
    kit.confirm(title, "Remove " .. info.name .. " from " .. regionName .. "?", function()
      if kit.call("regions.removeFeature", regionName, info.name) then
        regionScreen(regionName, { "Removed " .. info.name .. ".", "success" })
      end
    end)
  end
  if current then
    kit.addBottomButtons({ "Save", "primary", save }, { "Remove", "danger", remove })
  else
    kit.addBottomButtons({ "Add " .. info.name, "primary", save })
  end
end

-- Pick a feature to add: names with their descriptions.
local function featurePicker(r, all)
  kit.newScreen(r.name .. " - add", kit.backTo(regionScreen, r.name))
  kit.addText(3, "Tap a feature to add it.")
  local list = kit.addList(5, kit.H, "All features are added.")
  for _, fname in ipairs(kit.sortedKeys(all)) do
    if not r.features[fname] and all[fname].available ~= false then
      list:addItem({ text = " " .. fname, callback = function() kit.task(featureForm, r.name, all[fname], nil) end })
      for _, line in ipairs(kit.wrap(all[fname].description or "", kit.W - 3)) do
        list:addItem({ text = "  " .. line, fg = C.muted, selectable = false })
      end
      list:addItem({ text = "", selectable = false })
    end
  end
end

---------------------------------------------------------------------------
-- Region screen: its size, then one list with its shapes and features.

local shapePicker -- defined below

-- The toast after a shape change: features' warnings if there are any.
local function shapeFlash(text, result)
  if type(result) == "table" and result.warnings and #result.warnings > 0 then
    return { text .. " " .. table.concat(result.warnings, " "), "warning" }
  end
  return { text, "success" }
end

function regionScreen(name, flash)
  local token = kit.newScreen(name, kit.backTo(mainScreen), flash)
  local r = kit.call("regions.get", name)
  local all = r and features()
  if not kit.isCurrent(token) or not r or not all then return end

  local a = r.area
  local y = kit.addCard(3, {
    { "World", kit.dimName(r.dim) },
    { "Size", string.format("%dx%dx%d", a[4] - a[1] + 1, a[5] - a[2] + 1, a[6] - a[3] + 1) },
  })

  local list = kit.addList(y + 1, kit.H - 2)
  local function header(text)
    list:addItem({ text = " " .. text, fg = C.muted, selectable = false })
  end

  header("Shapes")
  for i, s in ipairs(r.shapes) do
    kit.addItem(list, " " .. shapes.describe(s), function()
      if #r.shapes == 1 then
        return kit.toast("A region needs at least one shape.", "info", 3)
      end
      kit.confirm(r.name, "Remove " .. shapes.describe(s) .. "?", function()
        local result = kit.call("regions.removeShape", r.name, i)
        if result then
          regionScreen(r.name, shapeFlash("Shape removed.", result))
        end
      end)
    end)
  end
  kit.addItem(list, " + Add shape", function()
    shapePicker(r.name .. " - add shape", kit.backTo(regionScreen, r.name), function(shape, dim)
      if dim ~= r.dim then
        return kit.toast("That's in another dimension than the region.", "error", 4)
      end
      kit.confirm(r.name, "Add " .. shapes.describe(shape) .. "?", function()
        local result = kit.call("regions.addShape", r.name, shape)
        if result then
          regionScreen(r.name, shapeFlash("Shape added.", result))
        end
      end)
    end)
  end, C.headIcon)

  list:addItem({ text = "", selectable = false })
  header("Features")
  for _, fname in ipairs(kit.sortedKeys(r.features)) do
    local warning = r.warnings and r.warnings[fname]
    kit.addItem(list, " " .. fname .. (warning and "  (!)" or ""), function()
      if all[fname] then featureForm(r.name, all[fname], r.features[fname], warning)
      else kit.toast("Unknown feature: " .. fname, "error", 4) end
    end, warning and C.warn or nil)
    if warning then
      for _, line in ipairs(kit.wrap(warning, kit.W - 5)) do
        list:addItem({ text = "    " .. line, fg = C.warn, selectable = false })
      end
    end
  end
  kit.addItem(list, " + Add feature", function() featurePicker(r, all) end, C.headIcon)

  kit.addBottomButtons(
    { "Teleport", "neutral", function()
      local dest = kit.call("regions.teleport", kit.player(), r.name)
      if dest then
        kit.toast(string.format("Teleported to %.1f, %.1f, %.1f", dest[1], dest[2], dest[3]), "success")
      end
    end },
    { "Delete", "danger", function()
      kit.confirm(r.name, "Delete region " .. r.name .. "? Its features are removed too.", function()
        if kit.call("regions.delete", r.name) then mainScreen({ "Deleted " .. r.name .. ".", "success" }) end
      end)
    end })
end

---------------------------------------------------------------------------
-- Making a shape by walking: pick a type, then follow its steps (stand
-- somewhere, tap Set); the shape type turns the recorded spots into a shape.

-- Run a shape type's steps. onShape(shape, dim) gets the result.
local function shapeSteps(title, typeName, back, onShape, points)
  points = points or {}
  local t = shapes.type(typeName)
  local step = t.steps[#points + 1]
  kit.newScreen(title, back)
  kit.root:addLabel({ x = 2, y = 3, text = string.format("%s, step %d of %d", t.description, #points + 1, #t.steps),
    foreground = C.muted })
  local _, y = kit.addText(5, step.prompt, C.text)
  if #points > 0 then
    local rows = {}
    for i, p in ipairs(points) do rows[i] = { "Spot " .. i, string.format("%d, %d, %d", p[1], p[2], p[3]) } end
    y = kit.addCard(y + 1, rows)
  end
  kit.addButton(kit.root, 2, y + 1, kit.W - 2, step.button, "primary", function()
    local pos = kit.call("core.playerPos", kit.player())
    if not pos then return end
    if points[1] and pos.dim ~= points[1].dim then
      return kit.toast("All spots must be in the same dimension.", "error", 4)
    end
    local next_ = {}
    for i, p in ipairs(points) do next_[i] = p end
    next_[#next_ + 1] = pos
    if #next_ < #t.steps then return shapeSteps(title, typeName, back, onShape, next_) end
    local shape, err = t.fromPoints(next_)
    if not shape then return kit.toast(err, "error", 4) end
    shape.type = typeName
    onShape(shape, pos.dim)
  end, 3)
end

-- Pick a shape type, then make it by walking.
function shapePicker(title, back, onShape)
  kit.newScreen(title, back)
  kit.addText(3, "Pick a shape, then walk to the spots it asks for.")
  local list = kit.addList(6, kit.H)
  for _, n in ipairs(shapes.typeNames()) do
    local t = shapes.type(n)
    if t then
      kit.addItem(list, t.description, function() shapeSteps(title, n, back, onShape) end)
    end
  end
end

local function newRegion()
  kit.prompt("New region", "Name for the new region (letters, numbers, - and _):", "", function(name)
    if name == "" then return end
    shapePicker("New: " .. name, kit.backTo(mainScreen), function(shape, dim)
      kit.confirm("New: " .. name, string.format("Create %s: %s in %s?", name, shapes.describe(shape),
        kit.dimName(dim)), function()
        local r = kit.call("regions.create", name, shape, dim)
        if r then regionScreen(r.name, { "Created " .. r.name .. ".", "success" }) end
      end)
    end)
  end)
end

---------------------------------------------------------------------------
-- Region list.

function mainScreen(flash)
  local token = kit.newScreen("Regions", kit.home, flash)
  local W, H = kit.W, kit.H
  local status = kit.root:addLabel({ x = 1, y = 2, width = W, height = 1, text = " Locating you...",
    background = C.status, foreground = C.statusText })

  local search = kit.root:addInput({ x = 2, y = 4, width = W - 2, placeholder = "Search regions",
    background = C.field, foreground = C.fieldText, placeholderColor = C.muted })
  local count = kit.root:addLabel({ x = 2, y = 5, text = "", foreground = C.faint })
  local list = kit.addList(6, H - 2, "Loading...")
  kit.addBottomButtons({ "+ New", "primary", newRegion })

  local all = kit.call("regions.list")
  if not kit.isCurrent(token) then return end
  local names = kit.sortedKeys(all)

  local function fill()
    local query = search.text:lower()
    list:clear()
    local shown = 0
    for _, name in ipairs(names) do
      if query == "" or name:lower():find(query, 1, true) then
        kit.addItem(list, name, function() regionScreen(name) end)
        shown = shown + 1
      end
    end
    if not all then
      list.emptyText = "Couldn't load regions."
    elseif #names == 0 then
      list.emptyText = "No regions yet. Tap + New."
    else
      list.emptyText = "No matches."
    end
    count.text = query == "" and (#names .. " region" .. (#names == 1 and "" or "s"))
      or (shown .. " of " .. #names)
  end
  search:onChange(fill)
  fill()

  -- Keep "You're in" up to date while this screen is shown.
  while kit.isCurrent(token) do
    local ok, here = kit.callQuiet("regions.regionsAt", 5, kit.player())
    if not kit.isCurrent(token) then return end
    if not ok then
      status.text = " Location unknown"
    elseif #here == 0 then
      status.text = " Not in a region"
    else
      status.text = (" You're in: " .. table.concat(here, ", ")):sub(1, W)
    end
    sleep(2)
  end
end

return {
  title = "Regions",
  order = 10,
  open = function(k)
    kit, C = k, k.C
    mainScreen()
  end,
}
