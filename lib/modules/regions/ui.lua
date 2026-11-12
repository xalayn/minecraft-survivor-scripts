-- Regions module, control app screens: searchable region list with "You're
-- in", region details, features (as forms built from their options),
-- teleporting, and creating regions by walking to two corners.

local kit -- set in open()
local C

local mainScreen, regionScreen

local function sizeOf(area)
  return string.format("%dx%dx%d", area[4] - area[1] + 1, area[5] - area[2] + 1, area[6] - area[3] + 1)
end

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

-- The settings of one feature on a region. current: its settings if added.
local function featureForm(regionName, info, current)
  local title = regionName .. " - " .. info.name
  kit.newScreen(title, kit.backTo(regionScreen, regionName))
  local _, y = kit.addText(3, info.description or info.name)
  if #info.options > 0 then _, y = kit.addText(y, "Tap a name for help.", C.faint) end
  local read = kit.addForm(y + 1, kit.H - 2, info.options, current)

  local function save()
    local v, err = read()
    if not v then return kit.toast(err, "error", 4) end
    local result = kit.call("regions.setFeature", regionName, info.name, v)
    if not result then return end
    local text = (current and "Saved " or "Added ") .. info.name
    if type(result) == "table" and result.needsDaemon then
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
    if not r.features[fname] then
      list:addItem({ text = " " .. fname, callback = function() kit.task(featureForm, r.name, all[fname], nil) end })
      for _, line in ipairs(kit.wrap(all[fname].description or "", kit.W - 3)) do
        list:addItem({ text = "  " .. line, fg = C.muted, selectable = false })
      end
      list:addItem({ text = "", selectable = false })
    end
  end
end

---------------------------------------------------------------------------
-- Region screen.

function regionScreen(name, flash)
  local token = kit.newScreen(name, kit.backTo(mainScreen), flash)
  local r = kit.call("regions.get", name)
  local all = r and features()
  if not kit.isCurrent(token) or not r or not all then return end

  local a = r.area
  local y = kit.addCard(3, {
    { "From", string.format("%d, %d, %d", a[1], a[2], a[3]) },
    { "To", string.format("%d, %d, %d", a[4], a[5], a[6]) },
    { "Size", sizeOf(a) },
    { "World", kit.dimName(r.dim) },
  })

  kit.root:addLabel({ x = 2, y = y + 1, text = "Features", foreground = C.muted })
  kit.addButton(kit.root, kit.W - 7, y + 1, 7, "+ Add", "primary", function() featurePicker(r, all) end)
  local list = kit.addList(y + 3, kit.H - 2, "No features yet.")
  for _, fname in ipairs(kit.sortedKeys(r.features)) do
    kit.addItem(list, fname, function()
      if all[fname] then featureForm(r.name, all[fname], r.features[fname])
      else kit.toast("Unknown feature: " .. fname, "error", 4) end
    end)
  end

  kit.addBottomButtons(
    { "Teleport", "neutral", function()
      local dest = kit.call("regions.teleport", kit.player(), r.name)
      if dest then
        kit.toast(string.format("Teleported to %.1f, %d, %.1f", dest[1], dest[2], dest[3]), "success")
      end
    end },
    { "Delete", "danger", function()
      kit.confirm(r.name, "Delete region " .. r.name .. "? Its features are removed too.", function()
        if kit.call("regions.delete", r.name) then mainScreen({ "Deleted " .. r.name .. ".", "success" }) end
      end)
    end })
end

---------------------------------------------------------------------------
-- New region: walk to two corners.

local function cornerScreen(name, first)
  kit.newScreen("New: " .. name, kit.backTo(mainScreen))
  kit.root:addLabel({ x = 2, y = 3, text = first and "Step 2 of 2" or "Step 1 of 2", foreground = C.muted })
  local _, y = kit.addText(5, "Stand at the " .. (first and "opposite" or "first") ..
    " corner of the region, then tap Set.", C.text)
  if first then
    y = kit.addCard(y + 1, { { "First", string.format("%d, %d, %d", first[1], first[2], first[3]) } })
  end

  kit.addButton(kit.root, 2, y + 1, kit.W - 2, "Set " .. (first and "second" or "first") .. " corner", "primary", function()
    local pos = kit.call("core.playerPos", kit.player())
    if not pos then return end
    if not first then return cornerScreen(name, pos) end
    if pos.dim ~= first.dim then
      return kit.toast("Both corners must be in the same dimension.", "error", 4)
    end
    local area = {
      math.min(first[1], pos[1]), math.min(first[2], pos[2]), math.min(first[3], pos[3]),
      math.max(first[1], pos[1]), math.max(first[2], pos[2]), math.max(first[3], pos[3]),
    }
    kit.confirm("New: " .. name, string.format("Create %s? %s in %s.", name, sizeOf(area), kit.dimName(pos.dim)), function()
      local r = kit.call("regions.create", name, { first[1], first[2], first[3] }, { pos[1], pos[2], pos[3] }, pos.dim)
      if r then regionScreen(r.name, { "Created " .. r.name .. ".", "success" }) end
    end)
  end, 3)
end

local function newRegion()
  kit.prompt("New region", "Name for the new region (letters, numbers, - and _):", "", function(name)
    if name ~= "" then cornerScreen(name, nil) end
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
