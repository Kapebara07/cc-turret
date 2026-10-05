-- seataim.lua
-- Makes a CC:CBC cannon mount (cannon_mount) aim wherever the player sitting in a
-- Create seat (SeatLook create_seat) is looking.
--
-- Usage:   seataim [seat] [mount]     (stop with Ctrl+T, the cannon returns to manual control)
--   example: seataim create_seat_3 cannon_mount_1
-- Autostart: add this line to startup.lua:  shell.run("seataim", "create_seat_3", "cannon_mount_1")
--
-- Requirements: the cannon is assembled (the script assembles it if not), and the shafts on the
-- Cannon Mount interfaces (yaw / pitch) are spinning - shaft speed is the cannon's aiming speed.

-- Peripheral names can be passed as arguments; without arguments the defaults below are used.
local args = { ... }
local SEAT_NAME  = args[1] or "create_seat_1"
local MOUNT_NAME = args[2] or "cannon_mount_0"

-- If the cannon aims mirrored, flip the sign here.
local YAW_SIGN    = 1    -- 1 = cannon looks where the player looks; -1 = mirrored horizontally
local PITCH_SIGN  = -1   -- seat pitch: up = negative, down = positive; the cannon is the opposite, hence -1
local YAW_OFFSET  = 0    -- correction in degrees if the cannon is rotated relative to the seat
local EPSILON     = 0.05 -- do not send a command if the aim moved less than this many degrees

local seat = peripheral.wrap(SEAT_NAME)
local mount = peripheral.wrap(MOUNT_NAME)
if not seat then error("Seat not found: " .. SEAT_NAME, 0) end
if not mount then error("Cannon mount not found: " .. MOUNT_NAME, 0) end

-- Assemble the cannon if it is not assembled yet.
local info = mount.getInfo()
if not info.assembled then
  print("Cannon is not assembled, assembling...")
  if not mount.assemble(true) then
    error("Could not assemble the cannon (check that the cannon blocks are attached to the Cannon Mount)", 0)
  end
  sleep(0.5)
end

mount.setComputerControl(true)
print("Aiming by look direction: " .. SEAT_NAME .. " -> " .. MOUNT_NAME)
print("Ctrl+T to exit")

local function wrapYaw(a)
  a = (a + 180) % 360 - 180
  return a
end

-- Last aim. While nobody sits in the seat the cannon keeps pointing where it was pointing.
local aimYaw, aimPitch = nil, nil

-- Read the rider's look direction (yaw and pitch are read in parallel so no ticks are wasted).
local function reader()
  while true do
    local yaw, pitch
    parallel.waitForAll(
      function() yaw = seat.getYaw() end,
      function() pitch = seat.getPitch() end
    )
    if yaw ~= nil and pitch ~= nil then
      aimYaw = wrapYaw(YAW_SIGN * yaw + YAW_OFFSET)
      aimPitch = PITCH_SIGN * pitch
    end
  end
end

-- Send the aim to the cannon, only when it has changed.
local function writer()
  local sentYaw, sentPitch
  while true do
    local yaw, pitch = aimYaw, aimPitch
    if yaw ~= nil then
      local dYaw = sentYaw and math.abs(wrapYaw(yaw - sentYaw)) or math.huge
      local dPitch = sentPitch and math.abs(pitch - sentPitch) or math.huge
      if dYaw >= EPSILON or dPitch >= EPSILON then
        mount.setTargetAngles(yaw, pitch)
        sentYaw, sentPitch = yaw, pitch
      else
        sleep(0.05)
      end
    else
      sleep(0.05)
    end
  end
end

local ok, err = pcall(parallel.waitForAny, reader, writer)

-- Exit (Ctrl+T or an error): give the cannon back to manual control.
pcall(mount.setComputerControl, false)
if not ok and err ~= "Terminated" then
  error(err, 0)
end
print("Stopped, the cannon is under manual control again.")
