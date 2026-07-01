# CC-Mek-SCADA setup guide

A practical walkthrough for wiring up and configuring this SCADA system against a Mekanism fission reactor build, using the patched source in this conversation. Follow the sections in order — the components genuinely need to come online in this sequence.

---

## 1. What you need before starting

**Mods** (confirm versions in-game, not just from memory):
- CC: Tweaked
- Mekanism v10.1 or later — earlier versions don't have full CC:Tweaked peripheral support
- Advanced Peripherals — optional, only needed if you want radiation monitoring via an Environment Detector
- Any mod providing bundled redstone (Immersive Engineering, Project Red, etc.) — optional, only needed if you want redstone-based auxiliary control (activating coolant valves, alarms, etc.)

**Computers, one set per reactor unit plus shared infrastructure:**

| Role | Computer type | How many |
|---|---|---|
| Reactor PLC | Advanced Computer | 1 per reactor |
| RTU | Advanced Computer | 1 minimum, can host multiple device links (see §4) |
| Supervisor | Advanced Computer | Exactly 1 for the whole facility |
| Coordinator | Advanced Computer | Exactly 1 for the whole facility |
| Pocket (optional) | Advanced Pocket Computer | As many as you want operators |

Regular (non-Advanced) computers won't work — the configurator UIs need color and the peripheral APIs used throughout require the Advanced tier.

**Modems:** every computer above needs at least one modem (wired or wireless) attached before you install anything. Wired is generally more reliable for short facility-internal links (PLC/RTU to supervisor); wireless is easier if your reactor units are spread out, and works fine with `TrustedRange` set appropriately.

---

## 2. Run the preflight check first

Before installing anything, place `preflight.lua` (included in the patched bundle) on each computer and run it:

```
preflight
```

It scans every attached peripheral — direct and through wired modems — and tells you in plain language what role that computer is wired for, whether a modem is present, and (for coordinators) what monitors it can see and their block dimensions. It makes no changes to any file; it's read-only. Run it again any time you add or remove a peripheral and aren't sure the computer sees it.

This catches the single most common setup mistake: a wired modem placed but not activated. In-game, right-click a wired modem to toggle it on — you'll see the connection cable highlight. An unactivated modem shows up to CC:Tweaked as if nothing is connected at all, and `preflight` will report zero peripherals even though the block is sitting right there.

---

## 3. Install order

Install and configure in this order. Later components depend on earlier ones being reachable on the network during their own configuration (the coordinator, for instance, syncs monitor-size requirements live from the supervisor).

1. **Supervisor** — the facility's brain. Install and configure first so everything else has something to link to.
2. **Reactor PLC(s)** — one per reactor, configured to link to the supervisor.
3. **RTU(s)** — one or more, configured to report Mekanism multiblock and redstone data to the supervisor.
4. **Coordinator** — the HMI. Configure last among the fixed infrastructure since its monitor-layout step actively syncs against the supervisor.
5. **Pocket(s)** — optional, configure any time after the coordinator is up.

### Installing each component

On each computer:

```
wget https://raw.githubusercontent.com/MikaylaFischler/cc-mek-scada/main/ccmsi.lua
ccmsi install <app>
```

Where `<app>` is one of `supervisor`, `reactor-plc`, `rtu`, `coordinator`, `pocket`. If your network has HTTP disabled, use the offline release-bundle method described in the project's README instead.

If you're deploying the patched version from this conversation rather than the upstream release, copy the patched tree onto each computer directly (via a disk drive, `pastebin put`, or your own transfer method) instead of running `ccmsi`, since `ccmsi` will pull the unpatched upstream files.

After installing, each component's `startup.lua` will detect it hasn't been configured yet and launch its configurator automatically on first boot. You can also run the configurator manually later with `<app>/configure` if you need to change settings.

---

## 4. What to physically connect, per component

### Supervisor
No Mekanism peripherals needed at all — just a modem. It's a pure network/logic node. Place it anywhere convenient, ideally central to your facility for wired cable runs.

### Reactor PLC
One per reactor. Connect it to the **reactor logic port** — either by placing the computer directly adjacent to the logic port block, or via a wired modem run if the computer needs to sit elsewhere. Confirm with `preflight` that it reports a `fissionReactorLogicAdapter` peripheral before configuring.

The PLC also needs network reach to the supervisor (wired or wireless modem, matching whichever the supervisor uses).

### RTU
This is the most flexible role — a single RTU computer can front multiple physical devices, each registered as a separate logical unit in configuration. Connect wired modems from the RTU computer to whichever of these you have in your build, then activate each modem connection:

| Mekanism block | RTU unit type | What it reports |
|---|---|---|
| Boiler valve | `BOILER_VALVE` | Steam/water levels, temperature, boil rate |
| Turbine valve | `TURBINE_VALVE` | Flow rate, energy output, coolant |
| Dynamic tank valve | `DYNAMIC_VALVE` | Tank fill levels |
| Induction matrix port | `IMATRIX` | Energy storage charge level |
| SPS port | `SPS` | Antimatter production status |
| Solar neutron activator | `SNA` | Polonium production status |
| Environment detector (Advanced Peripherals) | `ENV_DETECTOR` | Radiation levels |
| Redstone (bundled or plain) | `REDSTONE` | Digital I/O — alarms, valve actuation, indicator lamps |

You don't need one RTU computer per device — a single computer with several wired modem runs can host all of them, referenced by separate unit IDs in the RTU configurator. Splitting across multiple RTU computers is also fine and can help if you're hitting per-computer modem limits or want physical redundancy.

Each device you connect must be assigned, during RTU configuration, to the correct reactor unit number so the supervisor knows which reactor's coolant loop that boiler/turbine belongs to.

### Coordinator
Needs at least one **monitor** for the main display. Multiple monitor blocks joined together form one larger logical monitor in CC:Tweaked — build yours to whatever size the configurator tells you it needs once it syncs with the supervisor (this scales with facility size, so don't guess a fixed number in advance). Optionally add:
- A **flow monitor** — a secondary display showing the coolant/energy flow diagram.
- **Per-unit monitors** — one each, useful for larger multi-reactor facilities so operators can watch a specific unit without navigating the main screen.

The coordinator also needs a modem to reach the supervisor, and can optionally serve as an access point for pocket computers if you want field-portable control.

### Pocket
No fixed peripherals — it's handheld. It needs a modem (the Advanced Pocket Computer's built-in modem, or an equipped one) and network reach to the coordinator.

---

## 5. Network configuration

All components on one facility must agree on:
- **Channel numbers** — set during configuration; every node must match the supervisor's configured channels.
- **Comms version** — handled automatically as long as you're running matching component versions across the facility. Mixing versions will get you a `BAD_VERSION` rejection at the establish step, which is by design.
- **Auth key (recommended)** — set a passkey during supervisor configuration and enter the same one on every other component. This turns on HMAC authentication for all traffic. With the patch applied in this conversation, this now protects wired links too, not only wireless — there's no reason to leave it blank.
- **Trusted range** — only relevant for wireless modems; set to 0 for unlimited range, or to a specific block distance to reject traffic from outside your facility's physical footprint.

---

## 6. First boot checklist

Once everything is installed and configured, bring components online in this order and confirm each step before moving to the next:

1. Start the **supervisor**. It should sit idle waiting for connections — check its terminal for no persistent errors.
2. Start each **reactor PLC**. Watch the supervisor terminal for an establish/link message per reactor. If a PLC won't link, re-check its logic port connection with `preflight` and confirm its configured unit number matches what the supervisor expects.
3. Start each **RTU**. Same check — confirm each device establishes and that its readings (visible in supervisor debug logging) look sane, not stuck at zero or nil.
4. Start the **coordinator**. Confirm the main monitor renders and shows live data from the supervisor, not a blank or frozen screen.
5. Start any **pocket** computers and confirm they connect through the coordinator.

If something won't link, the most common causes in order of likelihood are: an unactivated wired modem (re-run `preflight`), a channel or auth key mismatch between the node and the supervisor, or a version mismatch between components installed at different times.

---

## 7. After setup — recommended next steps

- Set the RPS safety limits (damage, temperature, coolant fill thresholds) to match your reactor's actual tolerances rather than leaving Mekanism defaults if your build has different margins.
- If you're running multiple reactors, configure priority groups so the supervisor knows which reactors to ramp first when facility demand changes.
- Review the alarm thresholds in the facility configuration — the defaults are reasonable starting points but you may want tighter margins for a highly-optimized build or looser ones for a more forgiving low-tier setup.
- Keep the patched `preflight.lua` around — it's harmless to re-run any time you're troubleshooting a peripheral that isn't reporting.
