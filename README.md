# macro_keyboard — Linux tool for programming a 1189:8890 macro keyboard

A small Linux tool, written in [V](https://vlang.io), that reprograms the keys,
rotary knob, media keys, mouse actions and backlight of the USB macro keyboard
with USB ID **`1189:8890`**.

## Do I need a kernel driver?

**No.** The device is a standard USB HID keyboard, so Linux's built-in `usbhid`
driver already makes it type normally with zero setup. This tool is only needed
to *reconfigure* what the keys send — it talks to the device's vendor
configuration interface to change the key mappings, then gets out of the way.

## How it works

The keyboard exposes four USB HID interfaces:

* interface 0 — the normal keyboard the OS uses.
* interface 2 — keyboard + consumer/media keys.
* interface 3 — mouse.
* interface 1 (`mi_01`) — a **vendor configuration interface**. Writing reports
  to it reprograms each key, and a trailing "save" report commits the change to
  the device's flash.

The catch on Linux: interface 1 has **only an interrupt-OUT endpoint, no
interrupt-IN endpoint**. The kernel's `usbhid` driver refuses to bind to such an
interface (`dmesg`: *"couldn't find an input interrupt endpoint"*), so it never
creates a `/dev/hidraw` node for it — even though that's the interface we need.

So this tool talks to interface 1 directly through **libusb**: it claims the
interface, reads the HID report descriptor to learn the output report id
(report id 3 on this firmware) and report length (a 64-byte report), then sends
the command in a zero-padded report to the interrupt-OUT endpoint.

## Build

```sh
make
```

Requires the V compiler and **libusb-1.0** (`libusb-1.0.so`, present on virtually
every Linux desktop; the `-dev` package is only needed if you rebuild).

Optionally install the binary onto your `PATH` so you can run `macro_keyboard`
from anywhere (otherwise use `./macro_keyboard`):

```sh
sudo make install
```

## Permissions

libusb opens the device's node under `/dev/bus/usb/`, which is root-only by
default. Either run with `sudo`, or install the included udev rule once:

```sh
sudo make install-udev
```

Then **unplug and replug** the keyboard and run the tool as your normal user.

## Usage

```sh
./macro_keyboard info                       # find the device, show report id
./macro_keyboard set 1 key:CTRL+C           # program a key
./macro_keyboard set 2 key:CTRL+C,CTRL+V    # a macro (keystrokes split by ,)
./macro_keyboard set 13 media:VOL_DOWN      # knob turn-left
./macro_keyboard set 3 mouse:MIDDLE         # a mouse button
./macro_keyboard layer 2                     # switch active layer
./macro_keyboard led 1                       # backlight mode
./macro_keyboard apply example.conf          # batch-program from a file
./macro_keyboard keys                        # list all key/media/mouse names
```

### Key slots

This 3-key + 1-knob unit uses these slots:

| Slot      | Physical control          |
|-----------|---------------------------|
| `1` `2` `3` | the three keys (left→right) |
| `13`      | knob turn **left**        |
| `14`      | knob **press**            |
| `15`      | knob turn **right**       |

The firmware's protocol supports up to 18 slots (`1`–`12` keys, `13`–`15` knob 1,
`16`–`18` knob 2) for larger models in the same family; on this unit the other
slots have no physical control.

### Actions

| Action            | Meaning                                            |
|-------------------|----------------------------------------------------|
| `key:CTRL+C`      | one keystroke; modifiers joined with `+`           |
| `key:CTRL+C,CTRL+V` | a macro of up to 5 keystrokes, separated by `,`  |
| `media:VOL_UP`    | a media / consumer key                             |
| `mouse:LEFT`      | mouse button `LEFT`/`RIGHT`/`MIDDLE`               |
| `mouse:WHEEL_UP`  | mouse wheel up / `WHEEL_DOWN`                       |
| `led:1`           | backlight mode 0–2                                  |

`set` and config lines accept a target layer: `--layer 2` for `set`, or a
trailing `@2` in a config line.

### Config file

One rule per line, `slot = action [@layer]`. Blank lines and `#` comments are
ignored:

```
1  = key:CTRL+C
13 = media:VOL_DOWN
1  = key:F5 @2
```

Validate a config without hardware:

```sh
./macro_keyboard apply example.conf --dry-run
```

### Ready-made presets

Three presets for the 3-key + 1-knob unit are included — apply whichever fits:

| File                    | Keys (1/2/3)            | Knob (left / press / right)     |
|-------------------------|-------------------------|---------------------------------|
| `example.conf`          | prev / play-pause / next | volume down / mute / volume up |
| `example-editing.conf`  | copy / paste / cut       | zoom out / undo / zoom in       |
| `example-browser.conf`  | new tab / close / reopen | scroll down / middle-click / scroll up |

```sh
./macro_keyboard apply example-editing.conf
```

## Launching or hiding apps with a key

The keyboard can only send input events, so it can't launch an app by itself.
The trick is to program a key to a **conflict-free hotkey** and let your desktop
turn that hotkey into a command.

`F13`–`F24` are ideal: they exist in the HID spec but no physical keyboard has
them, so nothing else uses them.

1. Program a key to one of them:

   ```sh
   ./macro_keyboard set 1 key:F13
   ```

2. Bind that hotkey in your desktop's keyboard settings (on Cinnamon: *Keyboard →
   Shortcuts → Custom Shortcuts*). When the settings dialog asks for the key,
   press the macro key — it sends `F13`.

   * **Just open an app:** set the command to e.g. `gtk-launch firefox`.
   * **Open / focus / hide (toggle):** point it at the included helper:

     ```sh
     app-toggle.sh <window-class> <launch-command>
     # e.g.  app-toggle.sh firefox firefox
     ```

     It launches the app if it isn't running, focuses it if it's hidden, and
     minimises it if it's already focused. Find an app's window class with
     `wmctrl -lx`. Requires `xdotool` and `wmctrl` (X11).

## Verifying the protocol

`dump` builds the exact reports for an action without touching any device, so
you can inspect the bytes that would be sent:

```sh
./macro_keyboard dump 1 key:CTRL+C            # report id 3 (layer firmware)
./macro_keyboard dump 1 key:A --rid 0         # report id 0 (no-layer firmware)
```

## Status & limitations

* **Verified on real hardware** (USB `1189:8890`, firmware report id 3, 64-byte
  reports): device detection, report-id/length auto-detection, and programming a
  key macro all confirmed working.
* Reading the current configuration back from the device is not implemented;
  programming is one-way.
* Consumer (media) usage codes are the standard HID Consumer-page values. If a
  particular media key doesn't behave on your unit, `dump` it and inspect the
  emitted usage code.
* The interrupt-OUT endpoint is `0x02` (the value this device reports). If a
  future firmware revision differs, check `lsusb -v` and adjust `out_endpoint`.
