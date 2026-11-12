-- args: generic command-line option parsing for CC:Tweaked programs.
--
-- Each program describes its own options and passes them in:
--
--   package.path = "/lib/?.lua;" .. package.path
--   local args = require("args")
--
--   local options = {
--     { name = "walls", type = "boolean", default = true, desc = "Draw walls" },
--     { name = "opacity", type = "number", default = 20, min = 0, max = 100,
--       arg = "<0-100>", desc = "Wall opacity" },
--     { name = "yes", short = "y", type = "boolean", desc = "Don't ask" },
--   }
--   local pos, opts = args.parse(options, { ... })
--   if not pos then
--     printError(opts) -- the error message
--     return
--   end
--
-- Option fields:
--   name     Long name, used as --name and as the key in the returned opts.
--   type     "boolean" (default), "string" or "number".
--   short    Optional single letter, used as -x. Booleans can be combined: -xy.
--   default  Value when the option isn't given.
--   min/max  Bounds for numbers.
--   pattern  Lua pattern that strings must match (e.g. "^[%w_:]+$").
--   choices  List of allowed values (strings).
--   convert  Function(value) -> converted, or nil and an error, for structured
--            values: gets the text from the command line, or the value as
--            sent (e.g. a table) when validating. Replaces the checks above.
--   check    Optional function(value) returning an error string if invalid.
--   arg      Placeholder shown in help for non-booleans (default: <type>).
--   desc     Help text (command-line help).
--   hint     Longer explanation for UIs (the control app shows it when the field
--            name is tapped); falls back to desc.
--
-- Accepted forms: --name value, --name=value, -x value, -xvalue, -xy (booleans),
-- --no-name for booleans, and -- to treat everything after it as positional.
-- Arguments like -5 that don't start with "-" + letter are positional, so
-- negative numbers work as positional args.

local M = {}

local function convert(opt, label, raw)
  if opt.convert then
    local v, err = opt.convert(raw)
    if err then return nil, label .. ": " .. err end
    return v
  end
  local t = opt.type or "boolean"
  local v = raw
  if t == "number" then
    v = tonumber(raw)
    if not v then return nil, label .. " must be a number" end
    if opt.min and v < opt.min or opt.max and v > opt.max then
      return nil, string.format("%s must be between %s and %s", label,
        tostring(opt.min or "-inf"), tostring(opt.max or "inf"))
    end
  end
  if opt.choices then
    local found = false
    for _, c in ipairs(opt.choices) do if c == v then found = true end end
    if not found then return nil, label .. " must be one of: " .. table.concat(opt.choices, ", ") end
  end
  if opt.pattern and not tostring(v):match(opt.pattern) then
    return nil, label .. ": invalid value '" .. tostring(v) .. "'"
  end
  if opt.check then
    local err = opt.check(v)
    if err then return nil, label .. ": " .. err end
  end
  return v
end

--- Validate a table of option values (e.g. received over the network)
-- against an options list: converts and checks each value like parse()
-- does, fills in defaults, and rejects unknown keys.
-- @return the validated table, or nil and an error message.
function M.validate(options, values)
  local byName, result = {}, {}
  for _, o in ipairs(options) do byName[o.name] = o end
  for k in pairs(values or {}) do
    if not byName[k] then return nil, "Unknown option: " .. tostring(k) end
  end
  for _, o in ipairs(options) do
    local v = (values or {})[o.name]
    if v == nil then
      result[o.name] = o.default
    elseif (o.type or "boolean") == "boolean" then
      if type(v) ~= "boolean" then return nil, o.name .. " must be true or false" end
      result[o.name] = v
    else
      local converted, err = convert(o, o.name, o.convert and v or tostring(v))
      if err then return nil, err end
      result[o.name] = converted
    end
  end
  return result
end

--- Parse argv against an options list.
-- @return positional args and an opts table keyed by option name,
--         or nil and an error message.
function M.parse(options, argv)
  local byName, byShort, opts, pos = {}, {}, {}, {}
  for _, o in ipairs(options) do
    byName[o.name] = o
    if o.short then byShort[o.short] = o end
    opts[o.name] = o.default
  end

  local i = 1
  local function nextValue(label)
    i = i + 1
    if argv[i] == nil then return nil, label .. " needs a value" end
    return argv[i]
  end

  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      for j = i + 1, #argv do pos[#pos + 1] = argv[j] end
      break
    elseif a:match("^%-%-.") then
      local key, val = a:match("^%-%-([^=]+)=(.*)$")
      key = key or a:sub(3)
      local o, negated = byName[key], false
      if not o and key:sub(1, 3) == "no-" then
        local base = byName[key:sub(4)]
        if base and (base.type or "boolean") == "boolean" then o, negated = base, true end
      end
      if not o then return nil, "Unknown option: --" .. key end
      local label = "--" .. key
      if (o.type or "boolean") == "boolean" then
        if val then return nil, label .. " takes no value" end
        opts[o.name] = not negated
      else
        if val == nil then
          local err
          val, err = nextValue(label)
          if not val then return nil, err end
        end
        local v, err = convert(o, label, val)
        if err then return nil, err end
        opts[o.name] = v
      end
    elseif a:match("^%-%a") then
      local j = 2
      while j <= #a do
        local c = a:sub(j, j)
        local o = byShort[c]
        if not o then return nil, "Unknown option: -" .. c end
        local label = "-" .. c
        if (o.type or "boolean") == "boolean" then
          opts[o.name] = true
          j = j + 1
        else
          local val = a:sub(j + 1)
          if val == "" then
            local err
            val, err = nextValue(label)
            if not val then return nil, err end
          end
          local v, err = convert(o, label, val)
          if err then return nil, err end
          opts[o.name] = v
          break
        end
      end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return pos, opts
end


--- A `convert` function for options holding several values (type = "list"):
-- accepts text ("a,b c") from the command line or a list (from an app); each
-- item must be one of choices (if given) and match pattern (if given).
function M.listOf(choices, pattern)
  local allowed
  if choices then
    allowed = {}
    for _, c in ipairs(choices) do allowed[c] = true end
  end
  return function(v)
    local items = {}
    if v == nil then return {} end
    if type(v) == "string" then
      for w in v:gmatch("[^,%s]+") do items[#items + 1] = w end
    elseif type(v) == "table" then
      for _, w in ipairs(v) do items[#items + 1] = w end
    else
      return nil, "must be a list"
    end
    local out, seen = {}, {}
    for _, w in ipairs(items) do
      if type(w) ~= "string" then return nil, "must be a list of names" end
      if allowed and not allowed[w] then return nil, "unknown value '" .. w .. "'" end
      if pattern and not w:match(pattern) then return nil, "invalid value '" .. w .. "'" end
      if not seen[w] then
        seen[w] = true
        out[#out + 1] = w
      end
    end
    return out
  end
end
--- Help lines describing the options, for printing under a usage message.
function M.help(options)
  local rows, width = {}, 0
  for _, o in ipairs(options) do
    local t = o.type or "boolean"
    local flag
    if t == "boolean" and o.default == true then
      flag = "--no-" .. o.name
    else
      flag = (o.short and ("-" .. o.short .. ", ") or "") .. "--" .. o.name
      if t ~= "boolean" then flag = flag .. " " .. (o.arg or ("<" .. t .. ">")) end
    end
    rows[#rows + 1] = { flag, o.desc or "" }
    width = math.max(width, #flag)
  end
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = "  " .. r[1] .. string.rep(" ", width - #r[1] + 2) .. r[2]
  end
  return lines
end

return M
