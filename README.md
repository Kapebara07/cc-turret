# cc-turret

ComputerCraft programs for aiming Create guns with the look direction of the player sitting in a Create seat.

**Install / update (one command on every computer):**

```
wget run https://raw.githubusercontent.com/Kapebara07/cc-turret/main/install.lua
```

It downloads the programs, asks for the role of the computer and sets up `startup.lua`.
Roles: `control`, `seat`, `sensor`, `yaw` (horizontal swivel bearing), `pitch` (vertical swivel bearing).
Every computer needs a wireless (or ender) modem for rednet.

## The control computer

Put one computer with role `control` anywhere in wireless range. On it you type only the **numbers** of the devices:

```
seat 6       -> create_seat_6
sensor 1     -> sublevel_sensor_1
yaw 2        -> swivel_bearing_2
pitch 3      -> swivel_bearing_3
offset yaw 180      alignment of the horizontal direction, degrees
calibrate yaw       guns freeze for 15 s; sit in the seat and look along the barrels; the offset is stored
sign yaw            repeat the "which way does the bearing turn" test
status              which computers are online, what they see
```

The numbers are broadcast to all computers and saved there, so they survive restarts. Without a control computer the numbers
in `CFG.defaultNumbers` (top of `turret.lua`) are used. `turret seat create_seat_9` (a full name) always wins.

## Files

| File | What it is |
|---|---|
| `turret.lua` | All roles in one file. Needs the SeatLook, SubLevelSensor and SwivelControl mods. The vertical bearing is limited to 90 degrees up and down, the horizontal one is not limited. See the header of the file. |
| `seataim.lua` | Older single-computer variant for a CC:CBC `cannon_mount` instead of swivel bearings. |
| `install.lua` | The installer/updater. |
