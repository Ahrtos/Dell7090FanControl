# Hardware notice

Dell7090FanControl directly uses Dell's LegacyDiags WMI/SMM fan-control interface.

The public v1.0 release was developed and practically tested on a **Dell OptiPlex 7090 Micro**. Compatibility with other Dell models is not implied.

## Persistent MAX override

MAX mode uses Dell Command | Configure and `FanCtrlOvrd`.

On the development OptiPlex 7090 Micro this setting is persistent and can remain enabled across a reboot. The application therefore verifies that `FanCtrlOvrd=Disabled` when leaving MAX and when the program is intentionally shut down.

Do not casually adapt the MAX implementation to another Dell model without testing its firmware behavior first.
