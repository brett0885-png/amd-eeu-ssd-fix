# AMD EEU SSD Fix — checker + reversible mitigation

A single-file PowerShell tool that **detects** whether your PC is hit by the
AMD External Events Utility (EEU) continuous-SSD-write bug, and — if it is —
applies the community workaround of stopping that service. Fully reversible.

## The bug

Tom's Hardware reported (Nov 9, 2026) that AMD's **External Events Utility**
service — installed alongside Radeon drivers, running as the processes
`atieclxx.exe` and `atiesrxx.exe` — **continuously writes to the system SSD on
some systems, even at idle**. One user reported sustained writes of roughly
**5 MB/s while the PC was idle**, which works out to about 18 GB of host
writes per hour, ~432 GB per day, or close to 13 TB per month, and claimed
about 1% of SSD health lost per month over 16 months. Those figures are user
reports and have **not** been independently confirmed; host writes also don't
translate 1:1 into NAND wear, because SSD controllers cache and wear-level.
The write activity itself, however, is real and measurable — which is exactly
what this tool checks.

AMD acknowledged the problem on its community forum on **October 21, 2026**:
*"Yes. We're looking into it with the aim to resolve it in a future driver
release."* An AMD representative later added on Reddit: *"This is hopefully
fixed in the next one."* As of this writing **no fix has been released**, and
there is **no clear pattern across driver versions** — reports include
Adrenalin 26.19.2 and older releases, so an older driver is not proof you're
safe. It is also unclear whether integrated graphics are affected or only
discrete cards.

## What this tool does — and does not do

AMD's driver is **closed-source**. Nobody outside AMD can patch it, and this
tool does not pretend to. What it does:

- **Check** — measures the actual write activity of `atieclxx.exe` /
  `atiesrxx.exe` on *your* machine (cumulative counters plus a live
  30-second sample), reads your SSD's health and wear, and prints a plain
  verdict: `QUIET`, `LOW`, `ELEVATED`, or `SEVERE`.
- **Disable** — applies the workaround reported by the community: stop the
  AMD External Events Utility service and set it to Disabled, then
  re-measure for 10 seconds and print before/after.
- **Enable** — reverses Disable: service back to Automatic and started.
- **Status** — one-shot service + process + write counters, no waiting.

**Check first.** Plenty of systems — including the author's (see below) —
show zero writes and are not affected at all. Don't disable driver services
on a healthy machine.

## Our own measured datapoint

Tested on the author's PC: **Radeon RX 9070 XT, driver 32.0.32015.7029**,
Patriot P410 2TB SSD. The EEU service was Running/Automatic, and both
processes had been up since boot (Nov 9, 2026, 11:55):

- Cumulative writes (`WriteTransferCount`): **0 bytes** for both processes
- Live 30-second sample: **0 KB/s**
- SSD: Healthy, **Wear 0%**

Verdict: **QUIET — not affected.** Some systems are fine, which is why you
measure before you mitigate.

## Usage

Requires Windows PowerShell 5.1+ (built into Windows 10/11). No
dependencies, no installation — one `.ps1` file.

```powershell
# Read-only check with a 30-second live write sample (default mode)
powershell -ExecutionPolicy Bypass -File .\AmdEeuSsdFix.ps1 -Mode Check

# Quick one-shot status, no sampling wait
powershell -ExecutionPolicy Bypass -File .\AmdEeuSsdFix.ps1 -Mode Status

# Preview the mitigation without changing anything
powershell -ExecutionPolicy Bypass -File .\AmdEeuSsdFix.ps1 -Mode Disable -WhatIf

# Apply the workaround (must be run from an elevated / Administrator PowerShell)
powershell -ExecutionPolicy Bypass -File .\AmdEeuSsdFix.ps1 -Mode Disable

# Undo it (also elevated)
powershell -ExecutionPolicy Bypass -File .\AmdEeuSsdFix.ps1 -Mode Enable
```

Verdict bands (live sample): **0 KB/s** = QUIET (not affected);
**>0 and <50 KB/s** = LOW chatter, re-check later; **≥50 KB/s** sustained =
ELEVATED (bug-class); **≥500 KB/s** = SEVERE.

Exit codes: `0` = quiet/low or success, `2` = elevated/severe,
`1` = could not measure / needs elevation / error — so Check can also be
used in scripts.

You can also check manually: press **Win+R**, run `resmon`, open the
**Disk** tab, sort by write activity, and look for sustained writes from
`atieclxx.exe` or `atiesrxx.exe`.

## Safety notes

- **Check and Status are read-only.** They change nothing.
- Disabling the EEU service is the reported workaround, but it **may impact
  FreeSync or other driver/display features and gaming performance** on some
  systems. Weigh that before disabling a healthy-feeling machine, and
  re-enable (`-Mode Enable`) if anything misbehaves — and once AMD ships a
  fixed driver.
- Everything this tool changes is **reversible** with `-Mode Enable`.
- The tool collects **no telemetry and makes no network calls**. It's one
  readable script — audit it before you run it.
- When AMD releases the fixed driver, update and re-enable the service.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Brett Roberts.
