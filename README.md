# Dell7090FanControl

[![Latest release](https://img.shields.io/github/v/release/Ahrtos/Dell7090FanControl?display_name=tag)](https://github.com/Ahrtos/Dell7090FanControl/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Ahrtos/Dell7090FanControl/total)](https://github.com/Ahrtos/Dell7090FanControl/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D4)](#requirements)

A lightweight Windows fan-control utility built specifically for the **Dell OptiPlex 7090 Micro**.

It provides a practical alternative to Dell's very conservative stock fan behavior by using Dell's `LegacyDiags` WMI/SMM interface for the normal fan levels and Dell Command | Configure for the persistent MAX override.

### [⬇ Download the latest release](https://github.com/Ahrtos/Dell7090FanControl/releases/latest)

## Quick start

1. Download the latest portable ZIP from **Releases**.
2. Extract it to a permanent folder.
3. Install **Dell Command | Configure** if you want to use MAX mode.
4. Run `Dell7090FanControl.vbs`.
5. Accept the Windows UAC prompt.

> [!TIP]
> If you only want the custom Level 1 / Level 2 automatic control, Dell Command | Configure is only required for the separate MAX mode.

> [!WARNING]
> **Tested hardware: Dell OptiPlex 7090 Micro only.**  
> Do not assume compatibility with other Dell models. Direct firmware/SMM fan control can behave differently on different systems.

## Features

- Live Dell sensor temperature and fan RPM display
- Manual **Level 1** (~1140 RPM)
- Manual **Level 2** (~3980–4000 RPM)
- Manual **MAX** (~5560–5800 RPM)
- Restore **Dell BIOS Auto** at any time
- Custom two-stage automatic fan control
- Default curve:
  - Level 1 → Level 2 at **55 °C**
  - Level 2 → Level 1 below **45 °C**
- 1-second live refresh
- System-tray operation
- Tray icon shows the current mode:
  - 🟢 Level 1
  - 🟠 Level 2
  - 🔴 MAX
  - ⚪ Dell BIOS Auto
- Optional Windows autostart, minimized to tray
- Persistent MAX override is explicitly verified as disabled when leaving MAX
- Busy/progress feedback while settings are being applied

## Why this exists

On the tested OptiPlex 7090 Micro, Dell's stock fan curve waits far too long before increasing fan speed. The machine can therefore run substantially warmer than necessary even though the blower has plenty of cooling capacity.

Dell7090FanControl gives the owner a simple way to use the fan earlier without replacing Dell's firmware or flashing modified BIOS code.

## Tested system

The original development/test machine uses:

- Dell OptiPlex 7090 Micro
- Intel Core i7-11700T
- Windows 11
- Dell BIOS 1.45.0 during development
- Dell 180 W power supply

Observed fan speeds on this machine:

| Mode | Approx. RPM |
|---|---:|
| Level 1 | 1140 |
| Level 2 | 3980–4000 |
| MAX | 5560–5800 |

These RPM values are **observations from the test system**, not guaranteed values for every 7090 Micro.

## Requirements

- Windows 11 (the project was developed and tested there)
- Administrator privileges
- Dell `LegacyDiags` WMI interface available at:
  - `root\dcim\sysman\diagnostics`
- **Dell Command | Configure** for MAX mode

Expected `cctk.exe` path:

```text
C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe
```

Level 1 and Level 2 use Dell's WMI/SMM interface directly. MAX uses Dell's `FanCtrlOvrd` setting through `cctk.exe`.

## Installation / portable use

The short version is in [Quick start](#quick-start). The latest packaged build is always available on the [Releases page](https://github.com/Ahrtos/Dell7090FanControl/releases/latest).

The application can create its own scheduled task when **Start with Windows (minimized to tray)** is enabled.

### Debug start

If something does not work, run:

```text
DEBUG-Dell7090FanControl.cmd
```

This keeps the PowerShell window visible so errors can be inspected.

## Fan-control implementation

The tested OptiPlex 7090 exposes Dell's `LegacyDiags.Execute` WMI method. Dell SMM commands used by this project include:

- `0x00A3` — read fan state
- `0x02A3` — read fan RPM
- `0x04A3` — read nominal RPM for a fan state
- `0x01A3` — set fan state
- `0x10A3` — read temperature sensor
- `0x30A3` — disable BIOS/EC automatic fan control
- `0x31A3` — return control to BIOS/EC

### Important: State 3 is intentionally not used

Although the tested firmware reports a nominal ~5600 RPM entry for state 3, actually setting state 3 did **not** produce a stable third manual fan level on the test system. It fell back to another firmware-controlled state.

For that reason Dell7090FanControl uses only:

- SMM Level 1
- SMM Level 2
- Dell `FanCtrlOvrd` for MAX

## MAX safety behavior

> [!CAUTION]
> Dell `FanCtrlOvrd` is **persistent**. It can remain enabled across a reboot until explicitly disabled.

This was verified on the development machine. Therefore Dell7090FanControl does not treat MAX as a normal temporary SMM state.

When leaving MAX, the program explicitly verifies:

```text
FanCtrlOvrd=Disabled
```

The same safety step is performed when switching to Level 1, Level 2, custom auto control, Dell BIOS Auto, and when the application is intentionally exited.

## Temperature sensor

The custom automatic curve currently uses **Dell Sensor 0**, because on the development system this sensor clearly tracked CPU load.

This is **not the same reading as CPU Package temperature shown by tools such as HWiNFO**. Configure thresholds based on the Dell sensor shown by Dell7090FanControl rather than copying CPU Package limits directly.

## Autostart and tray behavior

- Minimizing the window hides it to the system tray.
- Closing the window with **X** also hides it to the tray.
- The fan control continues running in the background.
- Double-click the tray icon to reopen the window.
- Use **Exit** from the tray menu for a real application shutdown.
- A real shutdown restores Dell BIOS Auto and verifies that MAX is disabled.

Autostart and minimized tray operation were tested successfully on the development machine.

## Configuration and log files

The application creates these files next to the script:

```text
Dell7090FanControl.json
Dell7090FanControl.log
```

They are intentionally excluded from the repository.

## Known scope / limitations

- Only the **OptiPlex 7090 Micro** has been tested by the project author.
- Other Dell models may expose different sensors, fan states, WMI behavior, or firmware semantics.
- MAX requires Dell Command | Configure.
- The current v1.0 release is a portable PowerShell/WinForms application, not a native signed Windows executable.
- Code signing is not currently provided, so Windows may show the normal UAC/security prompts for scripts.

## Reporting bugs or compatibility results

GitHub issue forms are included for both bug reports and hardware compatibility reports.

If you test this on another **OptiPlex 7090 Micro**, please report:

- CPU model
- BIOS version
- Windows version
- Level 1 RPM
- Level 2 RPM
- MAX RPM
- Whether Sensor 0 follows CPU load
- Any unexpected behavior when returning to Dell BIOS Auto

[Open a new issue](https://github.com/Ahrtos/Dell7090FanControl/issues/new/choose)

Please **do not test MAX on an unsupported Dell model unless you understand the persistence warning above**.

## Project status

**v1.0 — stable release for the tested Dell OptiPlex 7090 Micro.**

The core control behavior, tray operation, mode colors, and Windows autostart were tested in real use on the development system.

## Credits

**Powered by Ahrtos – https://www.ahrtos.de | assisted by ChatGPT**

Dell7090FanControl is an independent community project and is **not affiliated with or endorsed by Dell Technologies**.

## License

MIT License. See [`LICENSE`](LICENSE).
