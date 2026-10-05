# cc-turret

ComputerCraft programs for aiming Create guns with the look direction of the player sitting in a Create seat.

**Install / update (one command on each computer):**

```
wget run https://raw.githubusercontent.com/Kapebara07/cc-turret/main/install.lua
```

It downloads the programs, asks for the role of the computer and sets up `startup.lua`.

| File | What it is |
|---|---|
| `turret.lua` | Four roles in one file: `seat` (reads the seat), `sensor` (reads the gun structure rotation), `yaw` and `pitch` (drive two Simulated swivel bearings). Needs the SeatLook, SubLevelSensor and SwivelControl mods and a wireless modem on every computer. The vertical bearing is limited to 90 degrees up and down, the horizontal one is not limited. See the header of the file. |
| `seataim.lua` | Older single-computer variant for a CC:CBC `cannon_mount` instead of swivel bearings. |
| `install.lua` | The installer/updater. |

**Guns point the wrong way horizontally?** On the `yaw` computer run `turret offset yaw 180` (guns backwards = 180, sideways = 90 or -90).
Or press `C` on the `yaw` computer: the guns freeze, you have 15 seconds to sit in the seat and look exactly along the barrels, then the offset is stored.
