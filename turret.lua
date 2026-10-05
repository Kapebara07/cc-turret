-- turret.lua  -  one file for all four computers.
--
-- The guns follow the look direction of the player sitting in a Create seat, with hard angle limits.
--
--   computer with the seat     :  turret seat   [create_seat_5]
--   computer with the sensor   :  turret sensor [sublevel_sensor_0]
--   computer with horizontal bearing:  turret yaw   [swivel_bearing_2]
--   computer with vertical bearing   :  turret pitch [swivel_bearing_3]
--
-- Names in [] are the defaults from CFG below; give a name as the second argument to override it.
-- Every computer needs a WIRELESS (or ender) modem for rednet, in addition to the modem that sees its peripheral.
-- Autostart: put  shell.run("turret", "yaw")  (or seat / sensor / pitch)  into startup.lua.
--
-- Aligning the horizontal direction (the guns point 180 degrees wrong / sideways at first):
--   * quick way:   turret offset yaw 180      (any number of degrees; 180 = the guns pointed backwards)
--                  turret offset pitch 0
--   * exact way:   press C on the yaw computer; the guns freeze for 10 seconds - walk to the seat, look EXACTLY along
--                  the gun barrels, and when the countdown ends the offset is stored.
-- The sign (which way the bearing has to turn) is detected automatically with a small test movement the first time the
-- sensor and the bearing are both online.
--
-- Limits: the vertical bearing is kept inside CFG.limits.pitch (degrees from the pose it was assembled in). The limit
-- is enforced every cycle, even when no player sits in the seat or the network is down. The horizontal bearing is
-- not limited by default (CFG.limits.yaw is empty). The sensor is used to align the guns with the view.

local CFG = {
  seatName         = "create_seat_5",
  sensorName       = "sublevel_sensor_0",
  yawBearingName   = "swivel_bearing_2",
  pitchBearingName = "swivel_bearing_3",

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
  calibrateDelay = 15,   -- seconds between pressing C and storing the offset
  pitchField    = "pitch", -- which sensor angle is the barrel elevation: "pitch" (or "roll" if the barrels point sideways)
}

local PROTOCOL = "turret.v1"
local CAL_FILE = "turret_cal.txt"

------------------------------------------------------------------------------------------------ helpers

local function wrap180(a) return (a + 180) % 360 - 180 end

local function clamp(v, lo, hi)
  if lo ~= nil and v < lo then return lo end
  if hi ~= nil and v > hi then return hi end
  return v
end

local function isNumber(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function loadCal()
  if not fs.exists(CAL_FILE) then return {} end
  local f = fs.open(CAL_FILE, "r")
  if not f then return {} end
  local t = textutils.unserialise(f.readAll())
  f.close()
  return type(t) == "table" and t or {}
end

local function saveCal(t)
  local f = fs.open(CAL_FILE, "w")
  if f then f.write(textutils.serialise(t)) f.close() end
end

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

------------------------------------------------------------------------------------------------ seat / sensor

local function runSeat(name)
  local seat, seq = nil, 0
  while true do
    if not seat then seat = peripheral.wrap(name) end
    if not seat then
      status("waiting for seat " .. name)
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
        status(isNumber(yaw) and string.format("seat: yaw %.1f pitch %.1f", yaw, pitch) or "seat: empty")
      end
    end
    sleep(CFG.sendPeriod)
  end
end

local function runSensor(name)
  local sensor, seq = nil, 0
  while true do
    if not sensor then sensor = peripheral.wrap(name) end
    if not sensor then
      status("waiting for sensor " .. name)
    else
      local ok, rot = pcall(sensor.getRotation)
      if not ok then
        sensor = nil
      else
        seq = seq + 1
        if type(rot) == "table" and isNumber(rot.yaw) then
          rednet.broadcast({ t = "state", seq = seq, ok = true, yaw = rot.yaw, pitch = rot.pitch, roll = rot.roll }, PROTOCOL)
          status(string.format("sensor: yaw %.1f pitch %.1f roll %.1f", rot.yaw, rot.pitch, rot.roll))
        else
          rednet.broadcast({ t = "state", seq = seq, ok = false }, PROTOCOL)
          status("sensor: block is not on a structure")
        end
      end
    end
    sleep(CFG.sendPeriod)
  end
end

------------------------------------------------------------------------------------------------ bearing controller

-- Returns a controller object. `axis` is "yaw" or "pitch". All state lives in the object so it can be tested.
local function newAxisController(axis, bearingName, cal)
  local lim = CFG.limits[axis] or {}
  local c = {
    axis = axis, name = bearingName, cal = cal,
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
    end
  end

  local function fresh(at) return c.now() - at <= CFG.staleAfter end

  local function measured()
    local st = c.state
    if not (st and st.ok and fresh(c.stateAt)) then return nil end
    local v = (axis == "yaw") and st.yaw or st[CFG.pitchField]
    return isNumber(v) and v or nil
  end

  local function wanted()
    local a = c.aim
    if not (a and a.occ and fresh(c.aimAt)) then return nil end
    local v = (axis == "yaw") and a.yaw or a.pitch
    if not isNumber(v) then return nil end
    return (axis == "pitch") and clamp(v, -90, 90) or v
  end

  local function offset() return c.cal[axis .. "Offset"] or 0 end
  local function sign() return c.cal[axis .. "Sign"] or 1 end

  -- bearing access, every call protected; a failure drops the handle so it is re-wrapped next cycle
  local function call(method, ...)
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

  -- C key: store the offset that makes the current view equal to the current gun direction.
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

  return c
end

local function runAxis(axis, bearingName)
  local cal = loadCal()
  local c = newAxisController(axis, bearingName, cal)

  local function receiver()
    while true do
      local _, msg = rednet.receive(PROTOCOL)
      c.onMessage(msg)
    end
  end

  local function keys()
    while true do
      local _, ch = os.pullEvent("char")
      if ch == "c" or ch == "C" then
        c.hold = true            -- freeze the guns so you can see where they really point
        for i = CFG.calibrateDelay, 1, -1 do
          c.note = "CALIBRATION in " .. i .. " s: guns frozen, sit in the seat and look along the barrels"
          sleep(1)
        end
        local ok, text = c.calibrate()
        c.note = text
        c.hold = false
      elseif ch == "s" or ch == "S" then
        cal[axis .. "Sign"] = nil     -- the control loop repeats the sign test
        saveCal(cal)
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
      if cal[axis .. "Sign"] == nil and c.engaged and c.now() >= nextSignTry then
        local ok, text = c.detectSign(8)
        c.note = text
        if not ok then nextSignTry = c.now() + 5 end   -- retry until the sensor and the bearing both answer
      end
      c.step()
      status(axis .. ": " .. tostring(c.note))
      sleep(CFG.controlPeriod)
    end
  end

  local ok, err = pcall(parallel.waitForAny, receiver, keys, control)
  -- Exit (Ctrl+T or error): keep the bearing under computer control and hold it where it is. Giving control back
  -- would let the shaft spin it freely.
  pcall(function()
    local b = peripheral.wrap(bearingName)
    local target = b and b.getTargetAngle()
    if isNumber(target) then b.setTargetAngle(clamp(target, CFG.limits[axis].min, CFG.limits[axis].max)) end
  end)
  if not ok and err ~= "Terminated" then error(err, 0) end
  print("\nStopped; the bearing keeps holding its angle.")
end

------------------------------------------------------------------------------------------------ main

local M = { wrap180 = wrap180, clamp = clamp, newAxisController = newAxisController, CFG = CFG,
  runSeat = runSeat, runSensor = runSensor, runAxis = runAxis }
M.main = nil   -- filled in below

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
  if role ~= "seat" and role ~= "sensor" and role ~= "yaw" and role ~= "pitch" then
    print("usage: turret seat|sensor|yaw|pitch [peripheral name]   or   turret offset yaw|pitch <degrees>")
    return
  end
  if not openRednet() then error("No modem found: attach a wireless (or ender) modem", 0) end
  term.clear()
  term.setCursorPos(1, 1)
  print("turret " .. role .. "   (Ctrl+T to stop)")
  if role == "yaw" or role == "pitch" then print("C = calibrate in " .. CFG.calibrateDelay .. " s (look along the barrels), S = redo sign test") end
  print("")
  local _, row = term.getCursorPos()
  statusRow = row
  if role == "seat" then runSeat(args[2] or CFG.seatName)
  elseif role == "sensor" then runSensor(args[2] or CFG.sensorName)
  elseif role == "yaw" then runAxis("yaw", args[2] or CFG.yawBearingName)
  else runAxis("pitch", args[2] or CFG.pitchBearingName) end
end

M.main = main
if _G.TURRET_TESTING then return M end
main(...)
