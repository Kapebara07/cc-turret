-- install.lua  -  one-command installer / updater for the turret programs.
--
--   wget run https://raw.githubusercontent.com/Kapebara07/cc-turret/main/install.lua
--
-- It downloads the latest turret.lua and seataim.lua and writes startup.lua so the program starts by itself.
-- Role: just press Enter for "auto" - the computer finds its role from the devices it sees (seat, sensor, yaw
-- bearing, pitch bearing). Type "control" only on the one computer where you enter the device numbers.
-- Run the same command again any time to update.

local BASE = "https://raw.githubusercontent.com/Kapebara07/cc-turret/main/"
local FILES = { "turret.lua", "seataim.lua" }
local ROLES = { auto = true, control = true, seat = true, sensor = true, yaw = true, pitch = true }

if not http then error("HTTP is disabled in the ComputerCraft config", 0) end

local function download(name)
  local url = BASE .. name .. "?t=" .. os.epoch("utc")   -- the query string skips stale caches
  local response, err = http.get(url, nil, true)
  if not response then return false, tostring(err) end
  local code = response.getResponseCode and response.getResponseCode() or 200
  local body = response.readAll()
  response.close()
  if code ~= 200 or not body or #body < 50 then return false, "HTTP " .. tostring(code) end
  return true, body
end

-- download everything first, so a failed download never leaves a half-updated computer
local fetched = {}
for _, name in ipairs(FILES) do
  write("Downloading " .. name .. " ... ")
  local ok, body = download(name)
  if not ok then
    print("FAILED (" .. body .. ")")
    error("Nothing was changed.", 0)
  end
  print("ok (" .. #body .. " bytes)")
  fetched[name] = body
end

for name, body in pairs(fetched) do
  local f = fs.open(name, "w")
  f.write(body)
  f.close()
end

-- role + startup.lua
local role = ...
while not ROLES[role or ""] do
  write("Role (Enter = auto, recommended; control = the number-entry computer; none = no startup): ")
  role = read():lower()
  if role == "" then role = "auto" end
  if role == "none" then role = nil break end
end

if role then
  local line = 'shell.run("turret", "' .. role .. '")'
  if fs.exists("startup.lua") then
    local f = fs.open("startup.lua", "r")
    local old = f.readAll()
    f.close()
    if not old:find("turret", 1, true) then   -- somebody else's startup: keep a copy
      fs.delete("startup.bak")
      fs.copy("startup.lua", "startup.bak")
      print("Old startup.lua saved as startup.bak")
    end
  end
  local f = fs.open("startup.lua", "w")
  f.write("-- written by install.lua\n" .. line .. "\n")
  f.close()
  print("startup.lua now runs: turret " .. role)
  print("Starting turret " .. role .. " ...")
  sleep(1)
  shell.run("turret", role)
else
  print("Installed. Run:  turret auto   (or turret control)")
end
