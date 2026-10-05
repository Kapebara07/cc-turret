# cc-turret

ComputerCraft programs for aiming Create guns with the look direction of the player sitting in a Create seat.

**Install / update (one command on every computer):**

```
wget run https://raw.githubusercontent.com/Kapebara07/cc-turret/main/install.lua
```

It downloads the programs and sets up `startup.lua`. On every computer that touches a device just press **Enter** (role `auto`):
the computer finds its role from the devices it sees - `create_seat_<n>` is the seat, `sublevel_sensor_<n>` the sensor,
`swivel_bearing_<n>` the horizontal (yaw) or vertical (pitch) bearing, depending on the numbers you set. A wrong role is impossible,
and a computer that sees none of the configured devices reports what it does see to the control computer.
Type `control` on the one computer where you enter the numbers. Every computer needs a wireless (or ender) modem for rednet.

## The control computer

Put one computer with role `control` anywhere in wireless range. It shows a small form (51x19 terminal, works in colour):

```
TURRET CONTROL  v10
  Device       Number  Name               State
> Seat         [6    ] create_seat_6      online
  Sensor       [1    ] sublevel_sensor_1  online
  Yaw horiz    [2    ] swivel_bearing_2   online
  Pitch vert   [3    ] swivel_bearing_3   NO SIGNAL

  Yaw offset   [180  ]  deg   mirror off
  Pitch offs.  [0    ]  deg   mirror ON
```

- **Up / Down / Tab** select a row, **digits** type the value (only the device number, not the whole name), **Enter** sends it to every
  computer (they save it, so it survives restarts), **Backspace** erases. Enter on an empty field sends the numbers again.
- **Yaw / Pitch offset** rows take degrees (`-` and `.` allowed). `yaw offset 180` = the guns were pointing backwards.
- **C** calibrates the selected axis: the guns freeze for 15 s, sit in the seat and look exactly along the barrels, the offset is stored.
- **S** repeats the "which way does the bearing turn" test of the selected axis.
- **I** is the **mirror switch** of the selected axis: if the guns move opposite to your head (you look up, they go down), press it. It works for both the vertical and the horizontal axis; the offset rows show `mirror ON` / `mirror off`.
- The **State** column: `online`, `PROBLEM` (the computer cannot find its device / bearing), `OFFLINE` or `NO SIGNAL`.

**Several control computers:** every edit carries a time stamp and the newest settings win everywhere, so an old control computer that
is still running can no longer flip the numbers back. If one is found, the panel shows an orange warning with its computer id.
A device that cannot find its peripheral says where its numbers came from (`numbers from computer #N`) - see the note line under the form.

Without a control computer the numbers in `CFG.defaultNumbers` (top of `turret.lua`) are used. A full name given on the
command line (`turret seat create_seat_9`) always wins.

## Files

| File | What it is |
|---|---|
| `turret.lua` | All roles in one file. Needs the SeatLook, SubLevelSensor and SwivelControl mods. The vertical bearing is limited to 90 degrees up and down, the horizontal one is not limited. See the header of the file. |
| `seataim.lua` | Older single-computer variant for a CC:CBC `cannon_mount` instead of swivel bearings. |
| `install.lua` | The installer/updater. |
