# CC-Mek-SCADA setup guide

A practical walkthrough for wiring up and configuring this SCADA system against a Mekanism fission reactor build, using the patched source in this conversation. Follow the sections in order — the components genuinely need to come online in this sequence.

---

## 1. What you need before starting

**Facility size:** this patched version supports up to **8 reactor units** per facility (raised from the upstream limit of 4), with the configurator's cooling/coolant/tank screens and the coordinator's main overview monitor all genuinely scaling to that count rather than being hardcoded. See §9 for multi-supervisor options if you want to split a large facility's workload across more than one supervisor, or add a hot-standby backup, and §8 for custom automation rules.

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

### Facility Dynamic Tanks for 5-8 unit facilities

The supervisor's shared "Facility Dynamic Tanks" option now works for any unit count up to 8, not just 4. Facilities of 4 or fewer units still see the original visual pipe-diagram picker with its 8 preset layouts, completely unchanged. Facilities of 5 or more units get a different screen instead — a simple list where you assign each unit's tank a group number, and any units sharing the same number share one physical tank. This is actually more flexible than the original 4-unit presets (which could only group contiguous units); groups don't need to be contiguous, so unit 1 and unit 3 can share a tank while unit 2 has its own.

This required real verification, not just extending a pattern: the legacy 4-unit mode logic turned out to have several non-obvious edge cases for unusual tank configurations that don't reduce to a clean general formula, so rather than risk quietly changing what an existing saved configuration means, the original 4-unit code is left completely untouched and the new mechanism only applies to facilities of more than 4 units, which never had this option before. The equivalence and correctness of the underlying logic in both paths was checked programmatically (`build/verify_tank_modes.lua`), not just by inspection.

## 8. Custom automation rules

This patched version can run custom "when X happens, do Y" rules on the supervisor, written as real Lua files rather than a fixed schema — this is a Lua-based platform already, and a rigid JSON format didn't do it justice.

### Setting it up

Copy the files from `automation.examples/` into a directory named `/automation` on your supervisor computer (adjacent to `startup.lua`), edit them to suit your facility, and restart the supervisor. An empty or missing directory means automation is simply disabled — this is fully opt-in.

Each rule is a `.lua` file that returns a table:

```lua
return {
    id = "unit1_high_temp_warning",
    enabled = true,
    cooldown_s = 30,

    trigger = function(api)
        local temp = api.unit(1).temp()
        return temp ~= nil and temp > 1100
    end,

    action = function(api)
        api.warn("Unit 1 temperature above 1100K, approaching RPS trip threshold")
    end
}
```

`trigger` is checked every tick (subject to `cooldown_s`); when it returns true, `action` runs once, immediately after. Because this is ordinary Lua, you can combine conditions with `and`/`or`, keep your own local state between calls (a closure works fine, see `automation.examples/hourly_status_log.lua` for a periodic rule built entirely out of a local timestamp variable), loop over units, or do anything else the logic actually needs — there's no fixed set of trigger types to work around.

### What `api` gives you

See `AUTOMATION_API.md` for the complete reference — every function, every valid redstone port and alarm name, and a working example for each. The short version:

- `api.unit(n)` — a handle for one reactor unit: `.temp()`, `.damage()`, `.waste_fill()`, `.coolant_fill()`, `.heated_coolant_fill()`, `.fuel_fill()`, `.burn_rate()`, `.heating_rate()`, `.alarm_tripped(name)`, plus the actions `.scram()`, `.ack_alarm(name)`, `.ack_all()`, and unit-scoped redstone via `.redstone_read(port)`/`.redstone_write(port, value)`.
- `api.facility.energy_fill()` — the induction matrix's current charge fraction, if one is connected.
- `api.redstone.read(port_name)` / `api.redstone.write(port_name, value)` / `api.redstone.write_analog(port_name, value, min, max)` — facility-level redstone ports.
- `api.log(message)` / `api.warn(message)` — writes to the supervisor log; every rule that fires also gets an automatic log line regardless, so you should never have to wonder whether "the automation did that."
- `api.tone(name)` — see the limitation below before relying on this for anything.
- `api.time_ms()` — for building your own interval/periodic logic, as in the hourly-log example.

### Why rule files run in their own environment

Each file loads with its own restricted set of globals (`math`, `string`, `table`, the usual control-flow basics, and `api`) rather than the full ordinary Lua environment. This isn't a security boundary against an untrusted author — whoever writes a rule file already has complete Lua access to every file on this computer, the same as any other program here. It's for the same reason CC:Tweaked runs every program this way: one rule's stray global can't leak into another's, a typo'd reference fails with a clear error naming the exact file instead of silently misbehaving, and a broken rule is isolated and reported by name rather than taking the others down with it. A rule that genuinely needs something outside `api` can always be written as a change to the supervisor's own source instead — which was always true, and isn't something this feature needs to work around.

### What the action set deliberately doesn't include

The api's actions stop short of anything that changes how a reactor is being steered. A SCRAM is included because reactors are designed to handle one safely at any time — that's the entire purpose of RPS — so it's reasonable to let a rule trigger one. Setting burn rate, changing RPS trip thresholds, or changing waste mode aren't exposed, because those interact with the existing automatic control loop in ways that are much harder to reason about safely for logic someone wrote for a specific, different situation. If you genuinely need that, it deserves a more careful, purpose-built design, not a quick addition to a general rule's action list.

One real limitation worth knowing: `api.tone()` produces a brief one-tick audio pulse, not a sustained alarm — the facility's existing alarm system fully recomputes what should be playing every single tick, so a custom tone gets overwritten almost immediately unless the rule keeps re-firing. For anything that needs to keep alerting until someone deals with it, trip an actual alarm condition or drive an external siren through `api.redstone.write` instead.

### A note on the included examples

`automation.examples/` ships six rules demonstrating the full range of what this can do: a straightforward threshold warning, a level-based redstone indicator (correctly re-asserting its output every check rather than pulsing once), a cross-unit multi-condition SCRAM, a fully custom time-interval rule built from nothing but a local variable and `api.time_ms()`, a unit-scoped redstone/alarm-acknowledgement example, and an analog redstone meter with a custom tone. The cross-unit SCRAM and alarm-acknowledgement examples ship **disabled** on purpose — they're there to show what's possible, not as default policy for your facility, and you should treat them as starting points to adapt rather than something to enable verbatim.

## 9. Running more than one supervisor

There are two different reasons you might want more than one supervisor, and they're solved two different ways.

### Splitting a large facility's workload (recommended approach)

If you just want to reduce how much one supervisor computer has to handle — say, an 8-unit facility split into two groups of 4 — the straightforward and fully-supported way to do this today is to run **two completely independent supervisor + coordinator stacks**, each with its own disjoint set of reactor units, RTUs, and PLCs. Supervisor A handles units 1-4 with its own coordinator and monitors; Supervisor B handles units 5-8 the same way. Nothing new to install — this is exactly how the system already works, just run twice.

This isn't a limitation-driven workaround: a single coordinator screen that merges live data from multiple independent supervisors into one combined view would need a real rearchitecture of the coordinator's core data model, which currently builds one shared dataset from a single supervisor at startup and has every screen read from it for the coordinator's entire runtime. That's not something to redesign through unverified patches when a mistake would break the coordinator's connection to everything, not just the new feature — so it isn't included here. Running independent stacks per unit group achieves the actual goal (splitting workload, isolating failure to one group of reactors) without that risk.

### Primary/backup failover for the same units

If instead you want a genuine hot-standby — a second supervisor ready to take over the *same* units if the first one dies — this patched version adds that as an opt-in feature. Run `failover_setup.lua` (included in this bundle) on each supervisor involved; it asks a few questions and writes the right settings directly (don't use CC's built-in `set` command for this — this app stores its config in a custom `/supervisor.settings` file that `set` doesn't touch).

How it behaves:

- The **primary** supervisor operates completely normally, and also broadcasts a lightweight heartbeat on a dedicated sync channel every few seconds.
- A **backup** supervisor starts up completely passive: it does not open the channel PLCs, RTUs, or the coordinator actually talk on, so it is structurally incapable of contending with the primary for the same devices — it simply isn't listening. It only listens for the primary's heartbeat.
- If the backup stops hearing that heartbeat for longer than its configured timeout, it promotes itself: opens its command channel and starts operating normally, exactly as the primary would.
- If a restarted primary or a promoted backup ever hears *another* active heartbeat on the same peer group, it does **not** try to resolve that automatically — it logs a clear conflict warning and keeps doing what it was already doing, requiring you to manually stop one of them. This is deliberate: automatically arbitrating which of two live supervisors should back off, over a real network, without the ability to test the timing live, is exactly the kind of decision that's safer left to a person for something controlling a reactor.

This means failover gives you fast, automatic protection against a primary going down, but recovery from an actual conflict (e.g. after fixing whatever took the primary offline) is a manual step by design, not an oversight.
