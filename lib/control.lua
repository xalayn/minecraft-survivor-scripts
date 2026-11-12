-- control: core of the control system, a management server (controld) plus
-- a pocket app (control) made of pluggable modules (regions, teams, ...).
--
-- A module is a folder lib/modules/<name>/ (installed as /lib/modules/<name>/)
-- with either or both of:
--
--   server.lua  Loaded by controld. Returns a table with:
--     title      Display name, e.g. "Regions".
--     handlers   Requests the pocket app can make: { <method> = function(...)
--                returning ok, result }. Pocket apps call them as
--                "<module>.<method>" (see lib/rpc.lua). Inputs come from the
--                network: validate everything that ends up in a command.
--     tick()     Optional. Called repeatedly by controld for continuous work
--                (it must yield, e.g. by running commands). Returns true if
--                it did anything; when no module does, controld idles.
--     init(log)  Optional. Called once when controld starts.
--
--   ui.lua  Loaded by the control app. Returns a table with:
--     title      Shown on the home screen.
--     order      Optional number; lower comes first on the home screen.
--     open(kit)  Opens the module's first screen. kit is lib/ui/kit.lua,
--                with the screen helpers and kit.call("<module>.<method>").
--
-- This file also holds the controld lock, so only one computer runs it.

local cmd = require("cmd")

local M = {}

local STORE = "control:core"
M.MODULE_DIR = "/lib/modules"

---------------------------------------------------------------------------
-- Modules.

--- Names of installed modules (sorted).
function M.moduleNames()
  local names = {}
  if fs.isDir(M.MODULE_DIR) then
    for _, n in ipairs(fs.list(M.MODULE_DIR)) do
      if fs.isDir(fs.combine(M.MODULE_DIR, n)) and n:match("^[%w_%-]+$") then names[#names + 1] = n end
    end
  end
  table.sort(names)
  return names
end

-- Load lib/modules/<name>/<part>.lua; nil (and an error) if missing or broken.
local function load(name, part)
  if not fs.exists(fs.combine(M.MODULE_DIR, name .. "/" .. part .. ".lua")) then return nil end
  local ok, mod = pcall(require, "modules." .. name .. "." .. part)
  if not ok then return nil, tostring(mod) end
  return mod
end

--- A module's server part, or nil (and an error if it failed to load).
function M.server(name) return load(name, "server") end

--- A module's UI part, or nil (and an error if it failed to load).
function M.ui(name) return load(name, "ui") end

---------------------------------------------------------------------------
-- controld lock. Stored as "<computer id>|x,y,z|<dimension>|<heartbeat ms>".

local LOCK_STALE_MS = 10000 -- a lock without a heartbeat for this long is abandoned

local function readLock()
  local _, out = commands.exec("data get storage " .. STORE .. " lock")
  local s = cmd.parseStoredString(out)
  if not s then return nil end
  local id, pos, dim, beat = s:match("^(%d+)|([^|]*)|([^|]*)|(%d+)$")
  if not id then return nil end
  return { id = tonumber(id), pos = pos, dim = dim, beat = tonumber(beat) }
end

local function writeLock()
  local x, y, z = commands.getBlockPosition()
  commands.exec(string.format('data modify storage %s lock set value "%d|%d,%d,%d|%s|%d"',
    STORE, os.getComputerID(), x, y, z, cmd.dimension(), os.epoch("utc")))
end

--- Claim the lock. Returns true, or false and a description of the computer
-- holding it.
function M.claimLock()
  local lock = readLock()
  if lock and lock.id ~= os.getComputerID() then
    local age = os.epoch("utc") - lock.beat
    if age < LOCK_STALE_MS then
      return false, string.format("computer #%d at %s (%s), last seen %ds ago",
        lock.id, lock.pos, lock.dim, math.floor(age / 1000))
    end
  end
  writeLock()
  return true
end

--- Refresh the lock's heartbeat. Returns false (and the holder) if another
-- computer has taken it over in the meantime.
function M.heartbeat()
  local lock = readLock()
  if lock and lock.id ~= os.getComputerID() then
    return false, string.format("computer #%d at %s (%s)", lock.id, lock.pos, lock.dim)
  end
  writeLock()
  return true
end

--- Description of the computer running controld ("computer #3 at ..."), or
-- nil if it isn't running.
function M.daemon()
  local lock = readLock()
  if lock and os.epoch("utc") - lock.beat < LOCK_STALE_MS then
    return string.format("computer #%d at %s (%s)", lock.id, lock.pos, lock.dim)
  end
end

--- Release the lock, if this computer holds it.
function M.releaseLock()
  local lock = readLock()
  if lock and lock.id == os.getComputerID() then
    commands.exec("data remove storage " .. STORE .. " lock")
  end
end

return M
