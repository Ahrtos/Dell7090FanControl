# Changelog

## v1.0

First public release.

### Added

- Live Dell sensor and fan-RPM monitoring
- Manual Level 1 and Level 2 control through Dell LegacyDiags WMI/SMM
- MAX mode through Dell Command | Configure `FanCtrlOvrd`
- Explicit persistent-MAX disable verification
- Dell BIOS Auto restore
- Adjustable two-stage automatic fan curve
- Default 55 °C / 45 °C switching thresholds
- 1-second status refresh
- Stable system-tray lifecycle
- Color-coded fan tray icon
- Windows autostart through a scheduled task
- Saved settings
- Busy/progress feedback during mode changes
- Debug launcher and log file

### Hardware notes

- Developed and tested on Dell OptiPlex 7090 Micro
- State 3 intentionally not used as a manual fan level
- Observed speeds on development machine:
  - Level 1 ~1140 RPM
  - Level 2 ~3980–4000 RPM
  - MAX ~5560–5800 RPM
