-- turret.lua  -  one file for all computers of the turret.
--
-- The guns follow the look direction of the player sitting in a Create seat, with hard angle limits.
--
--   turret control     the CONTROL computer: a form where you type only numbers; it tells the other computers which devices to use
--   turret seat        computer with the seat
--   turret sensor      computer with the sensor on the gun structure
--   turret yaw         computer with the horizontal swivel bearing
--   turret pitch       computer with the vertical swivel bearing
--
-- Every computer needs a WIRELESS (or ender) modem for rednet, in addition to the modem that sees its peripheral.
-- Install / update everything with one command (it also sets up startup.lua):
--   wget run https://raw.githubusercontent.com/Kapebara07/cc-turret/main/install.lua
--
-- THE CONTROL COMPUTER (`turret control`) shows a small form:
--   Seat / Sensor / Yaw / Pitch rows: type only the NUMBER (6 -> create_seat_6), Enter sends it to all computers
--   Yaw offset / Pitch offset rows: alignment in degrees (yaw offset 180 = the guns were pointing backwards)
--   C = calibrate the selected axis (guns freeze for 15 s, sit in the seat and look along the barrels)
--   S = repeat the "which way does the bearing turn" test of the selected axis
--   I = mirror switch of the selected axis: use it when the guns move opposite to your head (up = down)
-- The state column shows which computers are online. The numbers are saved on every computer, so they survive restarts.
-- Without a control computer the numbers in CFG.defaultNumbers are used (or `turret seat create_seat_6`, a full name
-- as the second argument always wins).
--
-- Limits: the vertical bearing is kept inside CFG.limits.pitch (degrees from the pose it was assembled in). The limit
-- is enforced every cycle, even when no player sits in the seat or the network is down. The horizontal bearing is
-- not limited by default (CFG.limits.yaw is empty). The sensor is used to align the guns with the view.

local CFG = {
  -- device numbers used until the control computer says otherwise
  defaultNumbers = { seat = 6, sensor = 1, yaw = 2, pitch = 3 },

  -- Allowed bearing angle range, degrees from the assembled pose. Leave min/max out for "no limit".
  limits = {
    yaw   = {},                        -- horizontal bearing: turns freely, any number of full turns
    pitch = { min = -90, max = 90 },   -- vertical bearing: at most 90 degrees up and 90 down
  },

  sendPeriod    = 0.1,   -- seat / sensor broadcast interval, seconds
  controlPeriod = 0.1,   -- bearing control interval, seconds
  staleAfter    = 1.5,   -- ignore seat / sensor data older than this, seconds
  gain          = 0.6,   -- fraction of the measured error corrected per cycle (lower = smoother)
  deadband      = 0.3,   -- degrees; smaller errors are ignored
  maxStep       = 45,    -- biggest correction per cycle, degrees
  pulse         = 12,    -- size of the sign-detection test movement, degrees
  calibrateDelay = 15,   -- seconds between a calibrate request and storing the offset
  -- Built-in alignment (degrees) used until an offset is stored by `offset ...` or the calibration.
  -- yaw = 180: the guns face the opposite way to the sensor's zero direction, so turn them half a circle.
  defaultOffset = { yaw = 180, pitch = 0 },
  pitchField    = "pitch", -- which sensor angle is the barrel elevation: "pitch" (or "roll" if the barrels point sideways)
  statusPeriod  = 1,     -- how often a computer reports its status to the control computer, seconds
  offlineAfter  = 5,     -- the control computer calls a silent computer offline after this many seconds
}

local VERSION = "8 (2026-10-05)"
local PROTOCOL = "turret.v1"
local CAL_FILE = "turret_cal.txt"
local NET_FILE = "turret_net.txt"

-- peripheral name = prefix .. number
local PREFIX = {
  seat   = "create_seat_",
  sensor = "sublevel_sensor_",
  yaw    = "swivel_bearing_",
  pitch  = "swivel_bearing_",
}
local ROLE_ORDER = { "seat", "sensor", "yaw", "pitch" }

------------------------------------------------------------------------------------------------ helpers

local function wrap180(a) return (a + 180) % 360 - 180 end

local function clamp(v, lo, hi)
  if lo ~= nil and v < lo then return lo end
  if hi ~= nil and v > hi then return hi end
  return v
end

local function isNumber(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function loadFile(name)
  if not fs.exists(name) then return {} end
  local f = fs.open(name, "r")
  if not f then return {} end
  local t = textutils.unserialise(f.readAll())
  f.close()
  return type(t) == "table" and t or {}
end

local function saveFile(name, t)
  local f = fs.open(name, "w")
  if f then f.write(textutils.serialise(t)) f.close() end
end

local function loadCal() return loadFile(CAL_FILE) end
local function saveCal(t) saveFile(CAL_FILE, t) end

local function openRednet()
  local opened = false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local okW, wireless = pcall(peripheral.call, name, "isWireless")
      if okW and wireless then
        if not rednet.isOpen(name) then rednet.open(name) end
        opened = true
      end
    end
  end
  if not opened then   -- no wireless modem: fall back to wired ones (works when everything is on one cable network)
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "modem" then
        if not rednet.isOpen(name) then rednet.open(name) end
        opened = true
      end
    end
  end
  return opened
end

local statusRow = 1
local function status(text)
  local w = term.getSize()
  term.setCursorPos(1, statusRow)
  term.clearLine()
  term.write(string.sub(text, 1, w))
end

------------------------------------------------------------------------------------------------ device numbers

-- The numbers the control computer sent (saved in NET_FILE); falls back to CFG.defaultNumbers.
local net = loadFile(NET_FILE)

local function numberFor(role)
  local n = net[role]
  if isNumber(n) then return n end
  return CFG.defaultNumbers[role]
end

-- Full peripheral name of a role. An explicit name (second command line argument) always wins.
local function deviceName(role, explicit)
  if explicit then return explicit end
  return PREFIX[role] .. tostring(numberFor(role))
end

-- Handles a "config" message from the control computer. Returns true if some number changed.
local function applyConfig(msg)
  if type(msg) ~= "table" or msg.t ~= "config" then return false end
  local changed = false
  for _, role in ipairs(ROLE_ORDER) do
    local n = msg[role]
    if isNumber(n) and n >= 0 and n % 1 == 0 and net[role] ~= n then
      net[role] = n
      changed = true
    end
  end
  if changed then saveFile(NET_FILE, net) end
  return changed
end

local lastAnnounce = {}
-- Tell the control computer what this computer is doing (at most once per CFG.statusPeriod).
local function announce(role, device, ok, note, extra)
  local now = os.clock()
  if lastAnnounce[role] and now - lastAnnounce[role] < CFG.statusPeriod then return end
  lastAnnounce[role] = now
  local m = { t = "status", role = role, device = device, ok = ok and true or false, note = note }
  if extra then for k, v in pairs(extra) do m[k] = v end end
  rednet.broadcast(m, PROTOCOL)
end

-- Runs `main` next to a listener that keeps the device numbers up to date.
local function withConfigListener(main)
  local function listener()
    while true do
      local _, msg = rednet.receive(PROTOCOL)
      applyConfig(msg)
    end
  end
  return parallel.waitForAny(main, listener)
end

------------------------------------------------------------------------------------------------ seat / sensor

local function runSeat(explicit)
  local seat, seatName, seq = nil, nil, 0
  local function loop()
    while true do
      local name = deviceName("seat", explicit)
      if name ~= seatName then seat, seatName = nil, name end   -- the control computer changed the number
      -- the named seat first; if it is gone (renumbered / replaced), any seat this computer can see
      if not seat then seat = peripheral.wrap(name) or peripheral.find("create_seat") end
      if not seat then
        status("waiting for seat " .. name)
        announce("seat", name, false, "device not found")
      else
        local yaw, pitch
        local ok = pcall(parallel.waitForAll,
          function() yaw = seat.getYaw() end,
          function() pitch = seat.getPitch() end)
        if not ok then
          seat = nil
        else
          seq = seq + 1
          rednet.broadcast({ t = "aim", seq = seq, occ = isNumber(yaw) and isNumber(pitch), yaw = yaw, pitch = pitch }, PROTOCOL)
          local text = isNumber(yaw) and string.format("%s: yaw %.1f pitch %.1f", name, yaw, pitch) or (name .. ": empty")
          status(text)
          announce("seat", name, true, text)
        end
      end
      sleep(CFG.sendPeriod)
    end
  end
  withConfigListener(loop)
end

local function runSensor(explicit)
  local sensor, sensorName, seq = nil, nil, 0
  local function loop()
    while true do
      local name = deviceName("sensor", explicit)
      if name ~= sensorName then sensor, sensorName = nil, name end
      -- the named sensor first; if it is gone (renumbered / replaced), the only sensor this computer can see
      if not sensor then
        sensor = peripheral.wrap(name)
        if not sensor then
          local found = { peripheral.find("sublevel_sensor") }
          if #found == 1 then sensor = found[1] end   -- with several sensors we do not guess
        end
      end
      if not sensor then
        status("waiting for sensor " .. name)
        announce("sensor", name, false, "device not found")
      else
        local ok, rot = pcall(sensor.getRotation)
        if not ok then
          sensor = nil
        else
          seq = seq + 1
          if type(rot) == "table" and isNumber(rot.yaw) then
            rednet.broadcast({ t = "state", seq = seq, ok = true, yaw = rot.yaw, pitch = rot.pitch, roll = rot.roll }, PROTOCOL)
            local text = string.format("%s: yaw %.1f pitch %.1f roll %.1f", name, rot.yaw, rot.pitch, rot.roll)
            status(text)
            announce("sensor", name, true, text)
          else
            rednet.broadcast({ t = "state", seq = seq, ok = false }, PROTOCOL)
            status(name .. ": block is not on a structure")
            announce("sensor", name, false, "block is not on a structure")
          end
        end
      end
      sleep(CFG.sendPeriod)
    end
  end
  withConfigListener(loop)
end

------------------------------------------------------------------------------------------------ bearing controller

-- Returns a controller object. `axis` is "yaw" or "pitch". `bearingName` is a name or a function returning the
-- current name (it can change when the control computer sends new numbers). All state lives in the object so it
-- can be tested.
local function newAxisController(axis, bearingName, cal)
  local lim = CFG.limits[axis] or {}
  local nameFn = type(bearingName) == "function" and bearingName or function() return bearingName end
  local c = {
    axis = axis, name = nameFn(), cal = cal,
    bearing = nil,
    aim = nil, aimAt = -1e9, state = nil, stateAt = -1e9,
    lastSent = nil, goal = nil, note = "starting",
    now = os.clock,
  }

  function c.onMessage(msg)
    if type(msg) ~= "table" then return end
    if msg.t == "aim" then
      c.aim, c.aimAt = msg, c.now()
    elseif msg.t == "state" then
      c.state, c.stateAt = msg, c.now()
    elseif msg.t == "cmd" and msg.target == axis then
      c.onCommand(msg)
    end
  end

  -- Commands typed on the control computer.
  function c.onCommand(msg)
    if msg.cmd == "offset" and isNumber(msg.value) then
      c.cal[axis .. "Offset"] = msg.value
      saveCal(c.cal)
      c.note = "offset set to " .. msg.value
    elseif msg.cmd == "calibrate" then
      c.wantCalibrate = true
    elseif msg.cmd == "invert" then
      local now = (c.cal[axis .. "Invert"] or 0) ~= 0
      local want
      if msg.value == nil then want = not now else want = (msg.value == true or (isNumber(msg.value) and msg.value ~= 0)) end
      c.cal[axis .. "Invert"] = want and 1 or 0
      saveCal(c.cal)
      c.note = want and "mirror: ON" or "mirror: off"
    elseif msg.cmd == "sign" then
      c.cal[axis .. "Sign"] = nil     -- the control loop repeats the sign test
      saveCal(c.cal)
    end
  end

  local function fresh(at) return c.now() - at <= CFG.staleAfter end

  local function measured()
    local st = c.state
    if not (st and st.ok and fresh(c.stateAt)) then return nil end
    local v = (axis == "yaw") and st.yaw or st[CFG.pitchField]
    return isNumber(v) and v or nil
  end

  -- Mirror switch: with it on, looking up makes the guns go down and the other way round (and left/right for yaw).
  -- Needed when the sensor or the bearing is mounted so that the guns move opposite to the view.
  local function inverted() return (c.cal[axis .. "Invert"] or 0) ~= 0 end
  c.isInverted = inverted

  local function wanted()
    local a = c.aim
    if not (a and a.occ and fresh(c.aimAt)) then return nil end
    local v = (axis == "yaw") and a.yaw or a.pitch
    if not isNumber(v) then return nil end
    if axis == "pitch" then v = clamp(v, -90, 90) end
    if inverted() then v = -v end
    return v
  end

  local function offset() return c.cal[axis .. "Offset"] or (CFG.defaultOffset or {})[axis] or 0 end
  local function sign() return c.cal[axis .. "Sign"] or 1 end
  c.getOffset, c.getSign = offset, sign

  -- bearing access, every call protected; a failure drops the handle so it is re-wrapped next cycle
  local function call(method, ...)
    local want = nameFn()
    if want ~= c.name then c.name, c.bearing, c.engaged, c.lastSent = want, nil, false, nil end
    if not c.bearing then c.bearing = peripheral.wrap(c.name) end
    if not c.bearing then return false end
    local ok, v = pcall(c.bearing[method], ...)
    if not ok then c.bearing = nil return false end
    return true, v
  end

  local function send(goal)
    goal = clamp(goal, lim.min, lim.max)
    if c.lastSent == nil or math.abs(goal - c.lastSent) >= 0.05 then
      local ok = call("setTargetAngle", goal)
      if ok then c.lastSent = goal end
    end
    c.goal = goal
  end

  -- Take control and hold the angle the bearing is at now (inside the limits).
  function c.engage()
    local ok = call("setComputerControl", true)
    if not ok then return false end
    local okT, target = call("getTargetAngle")
    if not (okT and isNumber(target)) then return false end
    send(target)
    c.engaged = true
    return true
  end

  -- One control cycle. Never raises.
  function c.step()
    if not c.engaged then
      if not c.engage() then c.note = "waiting for bearing " .. c.name return end
    end
    local okT, target = call("getTargetAngle")
    if not (okT and isNumber(target)) then c.engaged = false c.note = "bearing lost" return end
    local okC, ctl = call("isComputerControl")
    if okC and ctl == false then   -- control was dropped (restart, other program): take it back
      c.engaged = false
      return
    end

    -- hard limit watchdog: runs every cycle, whatever else is going on
    if (lim.min and target < lim.min - 0.5) or (lim.max and target > lim.max + 0.5) then
      send(target)   -- send() clamps
      c.note = "LIMIT: pulled back inside"
      return
    end

    if c.hold then return end   -- frozen while a calibration countdown runs
    local want, have = wanted(), measured()
    if want == nil then c.note = "hold (nobody in the seat / no aim data)" return end
    if have == nil then c.note = "hold (no sensor data)" return end
    if c.testing then return end

    local err
    if axis == "yaw" then err = wrap180(want - (have + offset())) else err = want - (have + offset()) end
    local desired = target + sign() * err          -- bearing angle that would remove the error
    local reach = desired
    if axis == "yaw" and lim.min ~= nil and lim.max ~= nil then
      -- The bearing cannot turn all the way round. Pick the equivalent angle (+-360) that lies inside the allowed
      -- arc; if the wanted heading is outside the arc go to the nearer end, and on a tie stay on the side we are on.
      local x = lim.min + ((desired - lim.min) % 360)
      if x <= lim.max then
        reach = x
      else
        local toMax, toMin = x - lim.max, lim.min + 360 - x
        if math.abs(toMax - toMin) < 1e-6 then
          reach = (target >= (lim.min + lim.max) / 2) and lim.max or lim.min
        else
          reach = (toMax < toMin) and lim.max or lim.min
        end
      end
    else
      reach = clamp(desired, lim.min, lim.max)
    end
    local diff = reach - target
    if math.abs(diff) < CFG.deadband then c.note = string.format("on target (err %.2f)", err) return end
    send(target + clamp(diff * CFG.gain, -CFG.maxStep, CFG.maxStep))
    c.note = string.format("aim %.1f  gun %.1f  err %.1f  bearing %.1f -> %.1f", want, have + offset(), err, target, c.goal)
  end

  -- Store the offset that makes the current view equal to the current gun direction.
  function c.calibrate()
    local want, have = wanted(), measured()
    if want == nil or have == nil then return false, "need a player in the seat and sensor data" end
    c.cal[axis .. "Offset"] = (axis == "yaw") and wrap180(want - have) or (want - have)
    saveCal(c.cal)
    return true, string.format("offset saved: %.2f", c.cal[axis .. "Offset"])
  end

  -- Detect which way the bearing has to turn: nudge it and watch the sensor. Returns true on success.
  function c.detectSign(waitSeconds)
    local have0 = measured()
    local okT, target = call("getTargetAngle")
    if have0 == nil or not (okT and isNumber(target)) then return false, "no sensor/bearing data" end
    local dir = 1
    if lim.max and target + CFG.pulse > lim.max then dir = -1 end
    c.testing = true
    send(target + dir * CFG.pulse)
    local deadline = c.now() + (waitSeconds or 8)
    local delta = 0
    while c.now() < deadline do
      sleep(0.2)
      local h = measured()
      if h ~= nil then
        delta = (axis == "yaw") and wrap180(h - have0) or (h - have0)
        if math.abs(delta) >= CFG.pulse * 0.4 then break end
      end
    end
    send(target)    -- back to where it was
    local deadline2 = c.now() + (waitSeconds or 8)
    while c.now() < deadline2 do
      sleep(0.2)
      local h = measured()
      if h ~= nil and math.abs(((axis == "yaw") and wrap180(h - have0) or (h - have0))) < CFG.pulse * 0.25 then break end
    end
    c.testing = false
    if math.abs(delta) < CFG.pulse * 0.4 then
      return false, "the gun did not move (is the shaft turning and the bearing assembled?)"
    end
    c.cal[axis .. "Sign"] = (delta * dir > 0) and 1 or -1
    saveCal(c.cal)
    return true, "sign detected: " .. c.cal[axis .. "Sign"]
  end

  -- Freeze the guns for a while, then store the offset (the player looks along the barrels meanwhile).
  function c.runCalibration()
    c.hold = true
    for i = CFG.calibrateDelay, 1, -1 do
      c.note = "CALIBRATION in " .. i .. " s: guns frozen, sit in the seat and look along the barrels"
      c.step()                         -- keeps the limit watchdog and the status reports alive
      if c.onTick then c.onTick() end
      sleep(1)
    end
    local ok, text = c.calibrate()
    c.note = text
    c.hold = false
  end

  return c
end

local function runAxis(axis, explicit)
  local cal = loadCal()
  local c = newAxisController(axis, function() return deviceName(axis, explicit) end, cal)
  c.onTick = function()
    status(axis .. ": " .. tostring(c.note))
    announce(axis, c.name, c.engaged and true or false, tostring(c.note), { offset = c.getOffset(), sign = c.getSign(), invert = c.isInverted() and 1 or 0 })
  end

  local function receiver()
    while true do
      local _, msg = rednet.receive(PROTOCOL)
      applyConfig(msg)
      c.onMessage(msg)
    end
  end

  local function keys()
    while true do
      local _, ch = os.pullEvent("char")
      if ch == "c" or ch == "C" then
        c.wantCalibrate = true
      elseif ch == "s" or ch == "S" then
        c.onCommand({ cmd = "sign" })
      elseif ch == "i" or ch == "I" then
        c.onCommand({ cmd = "invert" })
      end
    end
  end

  local function control()
    local nextSignTry = 0
    local cycles = 0
    while true do
      cycles = cycles + 1
      if cycles % 10 == 0 then   -- pick up changes made by `turret offset ...`
        for k, v in pairs(loadCal()) do cal[k] = v end
      end
      if c.wantCalibrate then
        c.wantCalibrate = false
        c.runCalibration()
      end
      if cal[axis .. "Sign"] == nil and c.engaged and c.now() >= nextSignTry then
        local ok, text = c.detectSign(8)
        c.note = text
        if not ok then nextSignTry = c.now() + 5 end   -- retry until the sensor and the bearing both answer
      end
      c.step()
      status(axis .. ": " .. tostring(c.note))
      announce(axis, c.name, c.engaged and true or false, tostring(c.note), { offset = c.getOffset(), sign = c.getSign(), invert = c.isInverted() and 1 or 0 })
      sleep(CFG.controlPeriod)
    end
  end

  local ok, err = pcall(parallel.waitForAny, receiver, keys, control)
  -- Exit (Ctrl+T or error): keep the bearing under computer control and hold it where it is. Giving control back
  -- would let the shaft spin it freely.
  pcall(function()
    local b = peripheral.wrap(c.name)
    local target = b and b.getTargetAngle()
    if isNumber(target) then b.setTargetAngle(clamp(target, CFG.limits[axis].min, CFG.limits[axis].max)) end
  end)
  if not ok and err ~= "Terminated" then error(err, 0) end
  print("\nStopped; the bearing keeps holding its angle.")
end

------------------------------------------------------------------------------------------------ control computer

-- The control panel: a small form. Pure logic + drawing through `term`, so it can be tested.
--   up/down (or Tab) select a row, digits type a value, Enter sends it, Backspace erases,
--   C = calibrate the selected axis, S = repeat its direction test.
local function newPanel(deps)
  local ROWS = {
    { kind = "num", role = "seat",   label = "Seat" },
    { kind = "num", role = "sensor", label = "Sensor" },
    { kind = "num", role = "yaw",    label = "Yaw horiz" },
    { kind = "num", role = "pitch",  label = "Pitch vert" },
    { kind = "off", axis = "yaw",    label = "Yaw offset" },
    { kind = "off", axis = "pitch",  label = "Pitch offs." },
  }
  local p = { sel = 1, buf = "", msg = "", msgAt = -1e9, msgBad = false }

  local function say(text, bad)
    p.msg, p.msgBad, p.msgAt = text, bad and true or false, os.clock()
  end

  local function axisOfRow(row)
    return row.axis or ((row.role == "yaw" or row.role == "pitch") and row.role or nil)
  end

  local function allowedChar(row, ch)
    if ch:match("^%d$") then return true end
    if row.kind == "off" and (ch == "-" or ch == ".") then return true end
    return false
  end

  local function maxLen(row) return row.kind == "num" and 3 or 7 end

  local function select(i)
    p.sel = ((i - 1) % #ROWS) + 1
    p.buf = ""
  end

  local function enter()
    local row = ROWS[p.sel]
    if p.buf == "" then
      if row.kind == "num" then deps.resend() say("numbers sent to all computers again") end
      return
    end
    local v = tonumber(p.buf)
    if v == nil then say("'" .. p.buf .. "' is not a number", true) p.buf = "" return end
    if row.kind == "num" then
      if v < 0 or v > 999 or v % 1 ~= 0 then say("device number must be a whole number 0-999", true) p.buf = "" return end
      deps.setNumber(row.role, v)
      say(row.role .. " -> " .. deps.deviceName(row.role) .. "   (sent)")
    else
      deps.sendCmd(row.axis, "offset", v)
      say(row.axis .. " offset " .. v .. " (sent)")
    end
    p.buf = ""
  end

  function p.event(ev, a)
    local row = ROWS[p.sel]
    if ev == "key" then
      if a == keys.up then select(p.sel - 1)
      elseif a == keys.down or a == keys.tab then select(p.sel + 1)
      elseif a == keys.enter or a == keys.numPadEnter then enter()
      elseif a == keys.backspace then p.buf = p.buf:sub(1, -2)
      elseif a == keys.delete then p.buf = "" end
    elseif ev == "char" and type(a) == "string" then
      local ch = a:lower()
      if allowedChar(row, ch) then
        if #p.buf < maxLen(row) then p.buf = p.buf .. ch end
      elseif ch == "c" or ch == "s" or ch == "i" then
        local axis = axisOfRow(row)
        if not axis then say("select a Yaw or Pitch row first", true) return end
        if ch == "i" then
          local st = deps.seen(axis)
          local nowOn = st and st.invert == 1
          deps.sendCmd(axis, "invert", nowOn and 0 or 1)
          say(axis .. ": mirror " .. (nowOn and "OFF" or "ON") .. " (looking up " .. (nowOn and "= guns up" or "= guns down on this axis") .. ")")
        elseif ch == "c" then
          deps.sendCmd(axis, "calibrate")
          say(axis .. ": guns freeze " .. CFG.calibrateDelay .. " s - sit in the seat and look along the barrels")
        else
          deps.sendCmd(axis, "sign")
          say(axis .. ": direction test started")
        end
      end
    end
  end

  -- text + colour of the state column for a role
  local function stateOf(role)
    local s = deps.seen(role)
    if not s then return "NO SIGNAL", colors.red end
    if os.clock() - s.at > CFG.offlineAfter then return "OFFLINE", colors.red end
    if s.ok then return "online", colors.lime end
    return "PROBLEM", colors.orange
  end

  function p.draw()
    local w, h = term.getSize()
    local color = term.isColor and term.isColor()
    local function paint(c) if color and c then term.setTextColor(c) end end
    local function line(y, text, c)
      term.setCursorPos(1, y)
      term.clearLine()
      paint(c or colors.white)
      term.write(string.sub(text, 1, w))
    end
    term.setBackgroundColor(colors.black)
    term.clear()
    line(1, "TURRET CONTROL  v" .. VERSION, colors.yellow)
    line(3, "  Device       Number  Name               State", colors.lightGray)
    local y = 4
    for i, row in ipairs(ROWS) do
      if row.kind == "off" and y == 8 then y = y + 1 end
      local selected = (i == p.sel)
      local shown
      if selected and p.buf ~= "" then shown = p.buf
      elseif row.kind == "num" then shown = tostring(deps.number(row.role))
      else
        local s = deps.seen(row.axis)
        shown = (s and s.offset ~= nil) and string.format("%g", math.floor(s.offset * 100 + 0.5) / 100) or "?"
      end
      local text = string.format("%s %-12s [%-5s]", selected and ">" or " ", row.label, shown)
      if row.kind == "num" then
        local st, stc = stateOf(row.role)
        term.setCursorPos(1, y)
        term.clearLine()
        paint(selected and colors.white or colors.lightGray)
        term.write(text)
        term.write(string.format(" %-18s", deps.deviceName(row.role)))
        paint(stc)
        term.write(st)
      else
        local inv = deps.seen(row.axis)
        local mirror = (inv and inv.invert == 1) and "mirror ON " or ((inv and inv.invert == 0) and "mirror off" or "mirror ?  ")
        line(y, text .. ((selected and p.buf ~= "") and "  Enter = send" or ("  deg   " .. mirror)), selected and colors.white or colors.lightGray)
      end
      y = y + 1
    end
    if os.clock() - p.msgAt <= 8 then line(y + 1, p.msg, p.msgBad and colors.red or colors.lime) end
    line(h - 3, "Up/Down: row   0-9: type   Enter: send", colors.gray)
    line(h - 2, "C: calibrate   S: direction test   I: mirror", colors.gray)
    line(h - 1, "Yaw offset 180 = guns were pointing backwards", colors.gray)
    paint(colors.white)
  end

  p.rows = ROWS
  return p
end

local function runControl()
  local seen = {}                       -- role -> { at=, device=, ok=, note=, offset=, sign= }
  local netRev = 0

  local function configMessage()
    local m = { t = "config", rev = netRev }
    for _, role in ipairs(ROLE_ORDER) do m[role] = numberFor(role) end
    return m
  end

  local panel = newPanel({
    number = numberFor,
    deviceName = function(role) return deviceName(role) end,
    seen = function(role) return seen[role] end,
    setNumber = function(role, n)
      net[role] = n
      saveFile(NET_FILE, net)
      netRev = netRev + 1
      rednet.broadcast(configMessage(), PROTOCOL)
    end,
    resend = function() rednet.broadcast(configMessage(), PROTOCOL) end,
    sendCmd = function(axis, cmd, value)
      rednet.broadcast({ t = "cmd", target = axis, cmd = cmd, value = value }, PROTOCOL)
    end,
  })

  local function listener()
    while true do
      local _, msg = rednet.receive(PROTOCOL)
      if type(msg) == "table" and msg.t == "status" and PREFIX[msg.role or ""] then
        seen[msg.role] = { at = os.clock(), device = msg.device, ok = msg.ok, note = msg.note, offset = msg.offset, sign = msg.sign, invert = msg.invert }
      end
    end
  end

  local function broadcaster()
    while true do
      rednet.broadcast(configMessage(), PROTOCOL)
      sleep(3)
    end
  end

  local function ui()
    panel.draw()
    local timer = os.startTimer(0.5)
    while true do
      local ev, a = os.pullEvent()
      if ev == "timer" then
        if a == timer then
          timer = os.startTimer(0.5)
          panel.draw()
        end
      elseif ev == "key" or ev == "char" then
        panel.event(ev, a)
        panel.draw()
      elseif ev == "term_resize" then
        panel.draw()
      end
    end
  end

  local ok, err = pcall(parallel.waitForAny, listener, broadcaster, ui)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  if not ok and err ~= "Terminated" then error(err, 0) end
end

------------------------------------------------------------------------------------------------ main

local M = { wrap180 = wrap180, clamp = clamp, newAxisController = newAxisController, CFG = CFG,
  runSeat = runSeat, runSensor = runSensor, runAxis = runAxis, runControl = runControl,
  deviceName = deviceName, applyConfig = applyConfig, newPanel = newPanel, net = net, VERSION = VERSION }

local function main(...)
  local args = { ... }
  local role = args[1]
  if role == "offset" then
    local axis, value = args[2], tonumber(args[3])
    if (axis ~= "yaw" and axis ~= "pitch") or value == nil then
      print("usage: turret offset yaw|pitch <degrees>   e.g.  turret offset yaw 180")
      return
    end
    local cal = loadCal()
    cal[axis .. "Offset"] = value
    saveCal(cal)
    print(axis .. " offset set to " .. value .. " (a running turret picks it up within a second)")
    return
  end
  if role ~= "seat" and role ~= "sensor" and role ~= "yaw" and role ~= "pitch" and role ~= "control" then
    print("usage: turret control | seat | sensor | yaw | pitch  [full peripheral name]")
    return
  end
  if not openRednet() then error("No modem found: attach a wireless (or ender) modem", 0) end
  term.clear()
  term.setCursorPos(1, 1)
  if role == "control" then
    print("turret v" .. VERSION .. "  CONTROL computer")
    runControl()
    return
  end
  local shown = deviceName(role, args[2])
  print("turret v" .. VERSION .. "  role: " .. role .. "  device: " .. shown)
  print("(Ctrl+T to stop; numbers and commands come from the control computer)")
  if role == "yaw" or role == "pitch" then print("C = calibrate in " .. CFG.calibrateDelay .. " s (look along the barrels), S = redo sign test") end
  print("")
  local _, row = term.getCursorPos()
  statusRow = row
  if role == "seat" then runSeat(args[2])
  elseif role == "sensor" then runSensor(args[2])
  elseif role == "yaw" then runAxis("yaw", args[2])
  else runAxis("pitch", args[2]) end
end

M.main = main
if _G.TURRET_TESTING then return M end
main(...)
