# RZMacro

Macro keys, button remapping and synced RGB lighting for Razer keyboards and mice on macOS.

Razer's own Mac software doesn't support many of its devices, older ones in particular. On a
Mac that leaves a keyboard's macro keys doing nothing, a mouse's extra buttons stuck with
whatever was last stored on them, and the lighting running each device's own effect. RZMacro
is a small free app that fills that gap: it talks to the devices directly and gives you a
window to configure them in.

![The keyboard page: a drawing of the keyboard with its macro keys, the button tiles, and the action picker](docs/keyboard.png)

> **Tested on two devices only:** the **BlackWidow V4 X** keyboard and the **Naga X** mouse —
> the ones I own. Other Razer keyboards and mice get generic support that nobody has tried
> yet. If you have one, please try it and open an issue with what you find; pull requests
> adding devices are very welcome. See [Other devices](#other-devices).

## What it does

- **Assign anything to a button.** Macro keys, the mouse's thumb grid, its right button, wheel
  click and wheel directions, the keyboard's volume roller: a
  keyboard shortcut, a macro, typed text, an app, a link or file, a media key, a mouse click,
  a lighting change, a shell command — or nothing. Run once, hold while held, or repeat.
- **Macros.** Record them by typing, or build them step by step: key presses, held keys,
  text, pauses, clicks. Choose per macro whether keys go out instantly or with a delay (some
  games need one).
- **Per-app profiles.** A button can do one thing in your editor and another in a game.
- **Lighting in sync.** Off, static, breathing, spectrum or wave, rendered from one clock and
  streamed to every device, so keyboard and mouse never drift apart.
- **Lives in the menu bar**, and everything is also in a plain config file and a small
  command-line tool.

| | |
|---|---|
| ![The mouse page with the thumb grid](docs/mouse.png) | ![The macro editor: a timeline of steps with a Record button](docs/macros.png) |
| ![The lighting page with a live preview](docs/lighting.png) | ![The settings page: permissions, devices, key speed](docs/settings.png) |

## Install

Requires macOS 14 or later.

### Download

1. Get `RZMacro-<version>.zip` from the [latest release](../../releases/latest) (Apple silicon),
   unzip it and move `RZMacro.app` to your Applications folder.
2. Open it. The app is not notarized by Apple (that needs a paid developer account), so macOS
   will refuse the first time: go to **System Settings → Privacy & Security**, scroll down, and
   click **Open Anyway**.
3. Give it the two permissions it asks for — see [Permissions](#permissions).

Each release is a new app as far as macOS is concerned, so the permissions have to be granted
again after updating. Building from source with your own signing identity avoids that.

### Build from source

With Xcode (or its command line tools) installed:

```sh
git clone https://github.com/vshaveyko/rzmacro.git
cd rzmacro
./scripts/install.sh
```

That builds the app, puts it in `~/Applications`, links the `rzmacro` command into
`~/.local/bin` if that folder exists, and opens it. If you have an Apple Development
certificate it is used for signing, which lets macOS remember the permissions across rebuilds.

To have it running all the time, turn on **Settings → Start RZMacro when I log in**.
`./scripts/uninstall.sh` removes the app again; your configuration is kept.

## Permissions

macOS asks you to allow two things, in **System Settings → Privacy & Security**:

- **Input Monitoring** — to read button presses from the devices. macOS doesn't always prompt
  for this one; if RZMacro isn't in the list, add it with the `+` button.
- **Accessibility** — to send the keystrokes your macros contain, and to swallow the keystroke
  a mouse button would otherwise type when you have given that button something else to do.

What it does with them: it opens only USB devices with Razer's vendor id, and looks at keyboard
events only to decide whether one came from a bound mouse button (or is an Fn combination the
keyboard has handed over). Nothing you type is stored or sent anywhere. The app makes no
network connections, with one exception that happens only if you click it: the **Photo** button
on a device page downloads that model's product picture from razer.com.

## Using it

- **Keyboard / Mouse.** Click a button in the picture or in the list — or just press it on the
  device — and choose an action from the tiles on the right. *Shortcut* starts listening
  straight away. *Macro* lets you pick a saved macro or record a new one on the spot. The menu
  in the top corner switches between "All apps" and per-app profiles.
- **Macros.** *Record* captures the keys you type (optionally with the pauses between them).
  Steps can be changed, reordered, duplicated and added by hand. A **Hold** step keeps a key
  down until you let go of the button, so "Press F4, Hold F4" is a double-tap-and-hold.
  *Assign to button* binds the macro without leaving the page; *Test* runs it after three
  seconds.
- **Lighting.** Pick an effect, colours, speed and brightness. Fn+F11 / Fn+F12 on the keyboard
  dim and brighten everything together.
- **Settings.** Permissions, connected devices, driver mode, key speed, start at login.

## Other devices

Only the two models above have been tested. Everything specific to a model lives in one table,
[`Sources/rzmacro/DeviceProfiles.swift`](Sources/rzmacro/DeviceProfiles.swift): its special
buttons and how its LEDs are addressed. Any other device with Razer's USB vendor id (`1532`)
gets a generic profile:

- **Buttons.** The page lists special buttons as you press them. This covers what Razer
  devices have in common: keys the device reports as vendor codes once it is in driver mode
  (macro keys, extra mouse buttons), and mouse buttons that type keyboard keys.
- **Lighting.** One colour per device, set with the plain "static" command on the usual zones:
  static, breathing and spectrum still stay in sync; wave becomes a colour cycle.

**If you try it on another device, please report back** — working or not. Useful to include:

```sh
rzmacro status        # what was detected, and which interfaces opened
rzmacro sniff         # then press the special buttons: shows what each one sends
```

To add a model properly, add a profile: USB product id, the buttons (`rzmacro sniff` shows
their codes), and the LED matrix size — OpenRazer's device list has `MATRIX_DIMS` for most
models. Keyboards with a macro column or a volume roller, and mice with a thumb grid, get a
drawing for free. Pull requests welcome.

## How it works

RZMacro is an ordinary app, not a kernel or DriverKit extension. It talks to the devices
through IOKit HID:

- **Driver mode.** Razer devices have a "driver mode" — what Synapse switches on under Windows.
  In it a keyboard reports its macro keys as vendor codes on a HID report macOS ignores; in
  normal mode those keys send nothing at all. A mouse reports all of its buttons with their
  factory keys regardless of what is stored in its on-board profile. RZMacro switches devices
  into driver mode while it runs and back when it quits.
- **Telling buttons from keys.** Presses are read straight from the device, so a thumb button
  that types `1` is told apart from the real `1` key. If the button is bound, an event tap
  swallows the keystroke and the assignment runs instead. Unbound buttons behave as usual.
- **Putting back what driver mode takes away.** In driver mode the BlackWidow's volume roller
  turns into a scroll wheel and its Fn layer stops working. RZMacro claims the roller's
  interface and sends volume keys, and handles Fn+F11/F12 (brightness) itself.
- **Lighting.** Effects are computed in the app and streamed to the devices as frames. The
  devices' built-in effects each run on their own timer, which is why they drift.

The only thing it stores on a device is the LED brightness level (set to full, so the frames
it sends are visible). Button assignments and macros live on the Mac, not on the device.

## Config file and command line

Everything the window does is stored in `~/.config/rzmacro/config.json5`, which can also be
written by hand (JSON with comments; comments are lost when the app next saves):

```json5
{
  devices: { keyboard: { driverMode: true }, mouse: { driverMode: true } },

  lighting: { effect: "wave", period: 6, brightness: 80 },

  // How keys are pressed, in ms held and ms paused per key; 0 (the default) is instant.
  keyDelay: 0,

  macros: {
    "Copy to other app": [ "cmd+c", { delay: 80 }, "cmd+tab", { delay: 250 }, "cmd+v" ],
    // A macro with its own key speed, whose second press is held until the button is let go:
    "Double-tap and hold": { steps: [ "f4", { down: "f4" } ], keyDelay: 30 },
  },

  bindings: {
    "keyboard.M1": "cmd+space",
    "keyboard.M2": { text: "hello there" },
    "keyboard.M3": { macro: "Copy to other app" },
    "keyboard.M4": { keys: "space", repeat: 80 },      // turbo while held
    "keyboard.M6": { light: "static red" },
    "mouse.1": "cmd+c",
    "mouse.5": { keys: "shift", hold: true },          // the button is Shift while held
    "mouse.7": [],                                     // disabled
    "mouse.12": { app: "Terminal" },
  },

  // Different bindings while an app is frontmost, by bundle identifier.
  apps: {
    "com.apple.Safari": { "mouse.1": "cmd+t", "mouse.2": "cmd+w" },
  },
}
```

Buttons are named `keyboard.M1`…, `keyboard.roller-up` / `roller-down`, `mouse.1`…`mouse.12`,
`mouse.right-click`, `mouse.wheel-click`, `mouse.wheel-up` / `wheel-down`, `mouse.back` /
`forward`, or by what `rzmacro sniff` shows (`keyboard.raw:2a`, `mouse.key:3d`). Actions are a shortcut string
or one of `keys`, `text`, `shell`, `app`, `open`, `media`, `click`, `light`, `macro`, `delay`,
`down`, `up`; a list is a sequence. Options: `hold`, `repeat`, `on: "release"`.

```
rzmacro show                        open the window
rzmacro status                      devices, permissions, bindings, lighting
rzmacro check                       validate the config file
rzmacro light wave period=4         try an effect
rzmacro press keyboard.M1 500       run a button's assignment as if held for 500 ms
rzmacro sniff                       show button events as you press them
rzmacro keys                        key names usable in shortcuts
rzmacro quit                        stop (devices go back to normal mode)
```

The log is at `~/Library/Logs/rzmacro.log`.

## Good to know

- Animated lighting costs a few percent of one CPU core; static and off cost nothing.
- Password fields hide keystrokes from event taps, so a bound thumb button types its usual
  character there.
- Keys held by a macro don't auto-repeat: a game sees the key as down, a text field gets one
  character.
- The recorder captures key presses made in RZMacro's own window. Shortcuts macOS takes first
  (⌘Tab, Spotlight) have to be added as steps by hand.
- The left mouse button can't be reassigned, on purpose: losing it by accident would leave no
  way to click. A reassigned wheel direction applies to any wheel mouse that is plugged in
  (a turn of the wheel can't be traced to one device); trackpad scrolling is never affected.
- Bindings are per kind of device (`keyboard.…`, `mouse.…`), so two mice share theirs.
- Razer Synapse can stay installed alongside.

## Credits and licence

MIT — see [LICENSE](LICENSE). Free to use, change and share.

What is known about Razer's USB protocol comes from the [OpenRazer](https://github.com/openrazer/openrazer)
project's years of reverse engineering, and from probing the two devices above. No OpenRazer
code is used here.

RZMacro is an independent project and is not affiliated with or endorsed by Razer Inc. "Razer",
"BlackWidow", "Naga" and "Synapse" are trademarks of their owner, used here only to say which
hardware this works with. It sends devices the same kind of commands Razer's own software
does, but you use it at your own risk.
