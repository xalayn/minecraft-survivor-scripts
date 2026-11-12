-- Installer / updater for this repo's CC:Tweaked programs.
--
-- First time on a computer:
--   wget https://raw.githubusercontent.com/xalayn/minecraft-survivor-scripts/HEAD/install.lua install
--   install
-- Afterwards, run `install` again to update everything.
--
-- Usage: install [branch]   (default: the repo's default branch)

local OWNER = "xalayn"
local REPO = "minecraft-survivor-scripts"

-- Repo folder -> install location on the computer.
local DIRS = {
  { "programs/", "/bin/" }, -- runnable by name (added to the shell path)
  { "lib/", "/lib/" },      -- shared modules: package.path = "/lib/?.lua;" .. package.path
}
local BIN_DIR = "/bin"

local ref = ({ ... })[1] or "HEAD"

if not http then
  printError("HTTP is disabled. Enable it in the CC:Tweaked server config.")
  return
end

local function get(url)
  local res, err = http.get(url, { ["User-Agent"] = "cc-tweaked-installer" })
  if not res then error("GET " .. url .. " failed: " .. tostring(err), 0) end
  local body = res.readAll()
  res.close()
  return body
end

local function getJSON(url)
  local data = textutils.unserialiseJSON(get(url))
  if not data then error("Bad JSON from " .. url, 0) end
  return data
end

local api = "https://api.github.com/repos/" .. OWNER .. "/" .. REPO

-- Pin to a commit SHA so raw.githubusercontent.com's cache can't serve stale files.
local commit = getJSON(api .. "/commits/" .. ref)
local sha = commit.sha
print("Installing " .. OWNER .. "/" .. REPO .. " @ " .. sha:sub(1, 7))

local tree = getJSON(api .. "/git/trees/" .. sha .. "?recursive=1")
local raw = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. sha .. "/"

-- Update the installer itself first. If it changed, hand over to the new
-- version so changes to the install logic apply in the same run.
do
  local self = shell.getRunningProgram()
  local latest = get(raw .. "install.lua")
  local f = fs.open(self, "r")
  local current = f and f.readAll()
  if f then f.close() end
  if latest ~= current then
    f = fs.open(self, "w")
    f.write(latest)
    f.close()
    print("Installer updated, restarting it...")
    shell.run(self, ref)
    return
  end
end

local function download(path, dest)
  local f = fs.open(dest, "w")
  f.write(get(raw .. path))
  f.close()
  print("  " .. dest)
end

local count, installed = 0, {}
for _, entry in ipairs(tree.tree) do
  if entry.type == "blob" then
    for _, d in ipairs(DIRS) do
      local src, dest = d[1], d[2]
      if entry.path:sub(1, #src) == src then
        local target = dest .. entry.path:sub(#src + 1)
        download(entry.path, target)
        installed[target] = true
        count = count + 1
      end
    end
  end
end

-- Delete files installed last time that are no longer in the repo.
local MANIFEST = "/.installed"
if fs.exists(MANIFEST) then
  local f = fs.open(MANIFEST, "r")
  for line in f.readAll():gmatch("[^\n]+") do
    if not installed[line] and fs.exists(line) then
      fs.delete(line)
      print("  removed " .. line)
    end
  end
  f.close()
end
do
  local f = fs.open(MANIFEST, "w")
  for path in pairs(installed) do f.write(path .. "\n") end
  f.close()
end

-- Programs renamed when regions became part of the control system: keep their
-- start-on-boot setting working under the new names.
local RENAMED_STARTUP = {
  ["/startup/50-regiond.lua"] = { "/startup/50-controld.lua",
    'if multishell then shell.openTab("/bin/controld") else shell.run("/bin/controld") end\n' },
  ["/startup/60-regionui.lua"] = { "/startup/60-control.lua", 'shell.run("/bin/control")\n' },
}
for old, new in pairs(RENAMED_STARTUP) do
  if fs.exists(old) then
    fs.delete(old)
    local f = fs.open(new[1], "w")
    f.write(new[2])
    f.close()
    print("  " .. old .. " -> " .. new[1])
  end
end

-- Make /bin programs runnable by name on every boot.
local startup = "/startup/00-bin-path.lua"
if not fs.exists(startup) then
  local f = fs.open(startup, "w")
  f.write('shell.setPath(shell.path() .. ":' .. BIN_DIR .. '")\n')
  f.close()
end
if not shell.path():find(BIN_DIR, 1, true) then
  shell.setPath(shell.path() .. ":" .. BIN_DIR)
end

print(("Installed %d file(s)"):format(count))
