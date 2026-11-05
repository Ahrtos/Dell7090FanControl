# Security and safety

Dell7090FanControl changes firmware-controlled fan behavior and therefore deserves more caution than an ordinary desktop utility.

## Supported hardware

The project author currently supports and tests only the **Dell OptiPlex 7090 Micro**.

## Reporting a problem

For ordinary bugs, open a GitHub issue.

For a problem that can leave `FanCtrlOvrd` enabled unexpectedly, please make that explicit in the issue title and include:

- BIOS version
- CPU model
- Windows version
- whether Dell Command | Configure is installed
- the value returned by `cctk.exe --FanCtrlOvrd`
- the exact mode transition that triggered the problem

Do not include passwords, tokens, serial numbers, service tags, or other private account/device identifiers.
