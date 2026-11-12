-- predicate: data-driven rules about which players something applies to.
--
-- A rule is plain data (so it can be saved in settings and sent over the
-- network):
--   nil or { all = {} }                     everyone
--   { type = "team", team = "blue" }        a condition (see below)
--   { ["not"] = rule }                      the opposite of a rule
--   { all = { rule, ... } }                 every rule matches
--   { any = { rule, ... } }                 at least one rule matches
--
-- Condition types are modules in lib/predicates/<type>.lua. Each returns:
--   description  e.g. "On a team" (shown in the app).
--   params       Option specs for its parameters (see lib/args.lua); the
--                first one is what the text form sets ("team:blue").
--   describe(p)  Short text for a condition, e.g. "on team blue".
--   term(p)      The Minecraft selector argument it stands for, as
--                { key = "team", value = "blue" }. Add `negatable = false` to
--                the module if the selector argument can't be negated with !.
--   fromText(s)  Optional: parse the text after "type:" into params (when
--                there's more than one param).
--   toText(p)    Optional: the inverse of fromText.
--
-- Rules have a text form for the command line:
--   team:blue and not (gamemode:creative or tag:referee)
--
-- Rules compile to selector arguments, so Minecraft does the filtering: see
-- M.selectors.

local args = require("args")

local M = {}

local MAX_DEPTH = 8
local MAX_CLAUSES = 16

---------------------------------------------------------------------------
-- Types.

local typeCache = {}

--- A condition type module by name, or nil and an error.
function M.type(name)
  if type(name) ~= "string" or not name:match("^[%w_]+$") then return nil, "Bad condition type" end
  if typeCache[name] == nil then
    local ok, mod = pcall(require, "predicates." .. name)
    typeCache[name] = ok and mod or false
  end
  return typeCache[name] or nil, typeCache[name] == false and ("Unknown condition type: " .. name) or nil
end

--- Names of installed condition types.
function M.typeNames()
  local names = {}
  if fs.isDir("/lib/predicates") then
    for _, f in ipairs(fs.list("/lib/predicates")) do
      local n = f:match("^([%w_]+)%.lua$")
      if n then names[#names + 1] = n end
    end
  end
  table.sort(names)
  return names
end

--- Condition types without functions (for the app): { name, description,
-- params, negatable }.
function M.types()
  local list = {}
  for _, name in ipairs(M.typeNames()) do
    local t = M.type(name)
    if t then
      local params = {}
      for i, o in ipairs(t.params or {}) do
        local c = {}
        for k, v in pairs(o) do if type(v) ~= "function" then c[k] = v end end
        params[i] = c
      end
      list[#list + 1] = { name = name, description = t.description, params = params,
        negatable = t.negatable ~= false }
    end
  end
  return true, list
end

local function paramsOf(node)
  local p = {}
  for k, v in pairs(node) do if k ~= "type" then p[k] = v end end
  return p
end

---------------------------------------------------------------------------
-- Validation.

-- Check a rule's structure and every condition's params. Returns a cleaned
-- copy, or nil and an error.
local function check(node, depth)
  if depth > MAX_DEPTH then return nil, "Rule is nested too deeply" end
  if type(node) ~= "table" then return nil, "Bad rule" end
  if node.all ~= nil or node.any ~= nil then
    local key = node.all ~= nil and "all" or "any"
    if type(node[key]) ~= "table" then return nil, "Bad rule" end
    local out = {}
    for i, child in ipairs(node[key]) do
      local c, err = check(child, depth + 1)
      if not c then return nil, err end
      out[i] = c
    end
    return { [key] = out }
  elseif node["not"] ~= nil then
    local c, err = check(node["not"], depth + 1)
    if not c then return nil, err end
    return { ["not"] = c }
  else
    local t, err = M.type(node.type)
    if not t then return nil, err end
    local p, perr = args.validate(t.params or {}, paramsOf(node))
    if not p then return nil, perr end
    p.type = node.type
    return p
  end
end

--- Validate a rule (a table, or nil for everyone). Returns the cleaned rule
-- (nil for everyone), or nil and an error.
function M.validate(rule)
  if rule == nil then return nil end
  local r, err = check(rule, 1)
  if not r then return nil, err end
  if r.all and #r.all == 0 then return nil end -- everyone
  -- Make sure it compiles (e.g. "not level:5.." can't be expressed).
  local ok, cerr = pcall(M.clauses, r)
  if not ok then return nil, tostring(cerr):gsub("^.-:%d+: ", "") end
  return r
end

---------------------------------------------------------------------------
-- Text form.

local function tokenize(s)
  local tokens, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "(" or c == ")" then
      tokens[#tokens + 1] = c
      i = i + 1
    else
      local word = s:match("^[^%s()]+", i)
      tokens[#tokens + 1] = word
      i = i + #word
    end
  end
  return tokens
end

--- Parse the text form into a rule ("" or "everyone" = nil). Returns the
-- rule, or nil and an error (check with the second value).
function M.parse(s)
  if type(s) ~= "string" then return nil, "Bad rule" end
  local tokens, pos = tokenize(s), 1
  if #tokens == 0 or (#tokens == 1 and tokens[1]:lower() == "everyone") then return nil end
  local function peek() return tokens[pos] and tokens[pos]:lower() end
  local expr
  local function unary()
    local t = tokens[pos]
    if not t then error("Rule ends too early", 0) end
    local lower = t:lower()
    pos = pos + 1
    if lower == "not" then return { ["not"] = unary() } end
    if t == "(" then
      local e = expr()
      if tokens[pos] ~= ")" then error("Missing )", 0) end
      pos = pos + 1
      return e
    end
    local name, rest = t:match("^([%w_]+):(.*)$")
    if not name then error("Expected a condition like team:blue, got '" .. t .. "'", 0) end
    local ty, err = M.type(name)
    if not ty then error(err, 0) end
    local node
    if ty.fromText then
      node = ty.fromText(rest)
      if not node then error("Bad " .. name .. " condition: " .. rest, 0) end
    else
      node = { [ty.params[1].name] = rest }
    end
    node.type = name
    return node
  end
  local function andExpr()
    local items = { unary() }
    while peek() == "and" do
      pos = pos + 1
      items[#items + 1] = unary()
    end
    return #items == 1 and items[1] or { all = items }
  end
  function expr()
    local items = { andExpr() }
    while peek() == "or" do
      pos = pos + 1
      items[#items + 1] = andExpr()
    end
    return #items == 1 and items[1] or { any = items }
  end
  local ok, result = pcall(function()
    local e = expr()
    if tokens[pos] then error("Unexpected '" .. tokens[pos] .. "'", 0) end
    return e
  end)
  if not ok then return nil, tostring(result) end
  return M.validate(result)
end

--- The text form of a rule.
function M.toText(rule, inner)
  if rule == nil or (rule.all and #rule.all == 0) then return "everyone" end
  local function group(items, word)
    local parts = {}
    for i, r in ipairs(items) do parts[i] = M.toText(r, true) end
    local s = table.concat(parts, " " .. word .. " ")
    return inner and ("(" .. s .. ")") or s
  end
  if rule.all then return group(rule.all, "and") end
  if rule.any then return group(rule.any, "or") end
  if rule["not"] then return "not " .. M.toText(rule["not"], true) end
  local t = M.type(rule.type)
  local p = paramsOf(rule)
  if t and t.toText then return rule.type .. ":" .. t.toText(p) end
  return rule.type .. ":" .. tostring(t and p[t.params[1].name] or "?")
end

--- A short description, e.g. "on team blue and not in creative".
function M.describe(rule, inner)
  if rule == nil or (rule.all and #rule.all == 0) then return "everyone" end
  local function join(items, word)
    local parts = {}
    for i, r in ipairs(items) do parts[i] = M.describe(r, true) end
    local s = table.concat(parts, " " .. word .. " ")
    return inner and ("(" .. s .. ")") or s
  end
  if rule.all then return join(rule.all, "and") end
  if rule.any then return join(rule.any, "or") end
  if rule["not"] then return "not " .. M.describe(rule["not"], true) end
  local t = M.type(rule.type)
  return t and t.describe(paramsOf(rule)) or rule.type
end

--- For option specs: converts a rule's text form (command line) or table
-- (from the app) into a validated rule. Returns the rule (nil = everyone),
-- or nil and an error.
function M.convert(v)
  if v == nil or v == "" then return nil end
  if type(v) == "string" then return M.parse(v) end
  return M.validate(v)
end

---------------------------------------------------------------------------
-- Compiling to selector arguments.

-- Selector keys: "single" ones allow one positive value per selector (and
-- any number of negated ones); "multi" ones repeat freely; scores merge.
local KEYS = {
  team = "single", gamemode = "single", name = "single", level = "single", type = "single",
  tag = "multi", predicate = "multi",
  scores = "scores",
}

-- Disjunctive normal form: a list of clauses (OR), each a list of terms
-- (AND); a term is { key, value, negated }.
local function dnf(rule, negate)
  if rule == nil then return negate and {} or { {} } end
  local function product(lists)
    local result = { {} }
    for _, clauses in ipairs(lists) do
      local next_ = {}
      for _, a in ipairs(result) do
        for _, b in ipairs(clauses) do
          local c = {}
          for _, t in ipairs(a) do c[#c + 1] = t end
          for _, t in ipairs(b) do c[#c + 1] = t end
          next_[#next_ + 1] = c
          if #next_ > MAX_CLAUSES then error("Rule is too complex", 0) end
        end
      end
      result = next_
    end
    return result
  end
  local function union(lists)
    local result = {}
    for _, clauses in ipairs(lists) do
      for _, c in ipairs(clauses) do result[#result + 1] = c end
    end
    if #result > MAX_CLAUSES then error("Rule is too complex", 0) end
    return result
  end
  local function children(items)
    local lists = {}
    for i, r in ipairs(items) do lists[i] = dnf(r, negate) end
    return lists
  end
  if rule.all then return negate and union(children(rule.all)) or product(children(rule.all)) end
  if rule.any then return negate and product(children(rule.any)) or union(children(rule.any)) end
  if rule["not"] then return dnf(rule["not"], not negate) end
  local t = assert(M.type(rule.type))
  if negate and t.negatable == false then
    error("A " .. rule.type .. " condition can't be negated", 0)
  end
  local term = t.term(paramsOf(rule))
  return { { { key = term.key, value = term.value, negated = negate } } }
end

-- Turn a clause into selector arguments, or nil if it can never match.
local function render(clause)
  local positive, negatives, scores, multi = {}, {}, {}, {}
  for _, t in ipairs(clause) do
    local kind = KEYS[t.key] or "multi"
    if kind == "scores" then
      if t.negated then error("Score conditions can't be negated", 0) end
      local obj, range = t.value:match("^([^=]+)=(.+)$")
      if scores[obj] and scores[obj] ~= range then return nil end -- conflicting ranges
      scores[obj] = range
    elseif kind == "single" then
      if t.negated then
        negatives[t.key] = negatives[t.key] or {}
        negatives[t.key][t.value] = true
      else
        if positive[t.key] and positive[t.key] ~= t.value then return nil end -- can't be both
        positive[t.key] = t.value
      end
    else
      multi[#multi + 1] = t.key .. "=" .. (t.negated and "!" or "") .. t.value
    end
  end
  local parts = {}
  for key, value in pairs(positive) do
    if negatives[key] and negatives[key][value] then return nil end -- x and not x
    parts[#parts + 1] = key .. "=" .. value
  end
  for key, values in pairs(negatives) do
    -- With a positive value set, the negatives are implied (and Minecraft
    -- rejects mixing them), so only add them when there's no positive one.
    if not positive[key] then
      for value in pairs(values) do parts[#parts + 1] = key .. "=!" .. value end
    end
  end
  for _, p in ipairs(multi) do parts[#parts + 1] = p end
  local objs = {}
  for obj, range in pairs(scores) do objs[#objs + 1] = obj .. "=" .. range end
  if #objs > 0 then
    table.sort(objs)
    parts[#parts + 1] = "scores={" .. table.concat(objs, ",") .. "}"
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

--- The rule's clauses (for validation): errors if it can't be compiled.
function M.clauses(rule)
  return dnf(rule, false)
end

--- Compile a rule, combined with extra required conditions (e.g. exemptions,
-- as a rule), into a list of selector-argument strings, one per alternative:
-- a player matches if they match any of them. An empty list means the rule
-- can never match anyone.
function M.selectors(rule, extra)
  local combined = rule
  if extra then combined = rule and { all = { rule, extra } } or extra end
  local out, seen = {}, {}
  for _, clause in ipairs(dnf(combined, false)) do
    local s = render(clause)
    if s and not seen[s] then
      seen[s] = true
      out[#out + 1] = s
    end
  end
  return out
end

return M
