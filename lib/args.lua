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
--   check    Optional function(value) returning an error string if invalid.
--   arg      Placeholder shown in help for non-booleans (default: <type>).
--   desc     Help text.
--
-- Accepted forms: --name value, --name=value, -x value, -xvalue, -xy (booleans),
-- --no-name for booleans, and -- to treat everything after it as positional.
-- Arguments like -5 that don't start with "-" + letter are positional, so
-- negative numbers work as positional args.

local M = {}

local function convert(opt, label, raw)
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
  if opt.check then
    local err = opt.check(v)
    if err then return nil, label .. ": " .. err end
  end
  return v
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
