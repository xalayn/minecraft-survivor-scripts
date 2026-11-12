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

local SRC_DIR = "programs/" -- files under this repo folder...
local DEST_DIR = "/bin/"    -- ...are installed here

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

local function download(path, dest)
  local f = fs.open(dest, "w")
  f.write(get(raw .. path))
  f.close()
  print("  " .. dest)
end

local count = 0
for _, entry in ipairs(tree.tree) do
  if entry.type == "blob" and entry.path:sub(1, #SRC_DIR) == SRC_DIR then
    download(entry.path, DEST_DIR .. entry.path:sub(#SRC_DIR + 1))
    count = count + 1
  end
end

-- Keep the installer itself up to date.
download("install.lua", "/install.lua")

-- Make /bin programs runnable by name on every boot.
local startup = "/startup/00-bin-path.lua"
if not fs.exists(startup) then
  local f = fs.open(startup, "w")
  f.write('shell.setPath(shell.path() .. ":' .. DEST_DIR:sub(1, -2) .. '")\n')
  f.close()
end
if not shell.path():find(DEST_DIR:sub(1, -2), 1, true) then
  shell.setPath(shell.path() .. ":" .. DEST_DIR:sub(1, -2))
end

print(("Installed %d program(s) to %s"):format(count, DEST_DIR))
