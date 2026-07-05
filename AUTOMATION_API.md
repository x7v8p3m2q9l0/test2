# Automation API reference

This is the complete reference for the `api` table passed to every rule's `trigger(api)` and `action(api)` functions. If something isn't listed here, it isn't available to a rule — see `supervisor/automation.lua`'s module header for why the surface is deliberately bounded to this.

For the basics — what a rule file looks like, how `cooldown_s` works, how to set the feature up — see §8 of `SETUP_GUIDE.md`. This document assumes you've read that and covers every function in depth, with a working example for each.

---

## `api.unit(n)`

Returns a handle for reactor unit `n` (1-indexed). Every reading method returns `nil` if the unit doesn't exist or hasn't reported status yet — checking `api.unit(9).temp()` on a 4-unit facility gives you `nil` (falsy), not a crash.

### `api.unit(n).exists()`

Returns `true`/`false`. Useful as a guard at the top of a trigger before calling anything else on a unit that might not exist — relevant mainly if you write one rule file intended to be copied across a facility with a variable number of units.

```lua
trigger = function(api)
    return api.unit(5).exists() and api.unit(5).temp() > 1000
end
```

### `api.unit(n).temp()`

Reactor core temperature in Kelvin. `nil` if unavailable.

```lua
-- automation.examples/unit1_high_temp_warning.lua
trigger = function(api)
    local temp = api.unit(1).temp()
    return temp ~= nil and temp > 1100
end
```

### `api.unit(n).damage()`

Reactor damage percentage, 0-100. `nil` if unavailable.

```lua
trigger = function(api)
    local dmg = api.unit(3).damage()
    return dmg ~= nil and dmg > 50
end,
action = function(api)
    api.warn("Unit 3 damage above 50% - well below RPS trip but worth checking on")
end
```

### `api.unit(n).waste_fill()`

Waste tank fill fraction, 0-1. `nil` if unavailable.

```lua
trigger = function(api)
    local w = api.unit(2).waste_fill()
    return w ~= nil and w > 0.8
end,
action = function(api)
    api.log("Unit 2 waste tank above 80% - check waste processing routing")
end
```

### `api.unit(n).coolant_fill()`

Coolant fill fraction, 0-1 (the reactor's coolant supply, e.g. cooled sodium or water depending on your reactor's cooling type). `nil` if unavailable.

```lua
trigger = function(api)
    local c = api.unit(1).coolant_fill()
    return c ~= nil and c < 0.15
end,
action = function(api)
    api.warn("Unit 1 coolant fill below 15%")
end
```

### `api.unit(n).heated_coolant_fill()`

Heated coolant fill fraction, 0-1 (the reactor's output side — hot sodium or steam, depending on cooling type, waiting to be processed by boilers/turbines). `nil` if unavailable.

```lua
trigger = function(api)
    local hc = api.unit(1).heated_coolant_fill()
    return hc ~= nil and hc > 0.9
end,
action = function(api)
    api.warn("Unit 1 heated coolant above 90% - check turbine/boiler throughput")
end
```

### `api.unit(n).fuel_fill()`

Fuel tank fill fraction, 0-1. `nil` if unavailable.

```lua
trigger = function(api)
    local f = api.unit(4).fuel_fill()
    return f ~= nil and f < 0.1
end,
action = function(api)
    api.log("Unit 4 fuel below 10% - schedule a refuel")
end
```

### `api.unit(n).burn_rate()`

Current actual burn rate in mB/t. `nil` if unavailable. Note this is a *reading*, not a control — there's no `set_burn_rate` in this API; see the note at the end of this document on why.

```lua
trigger = function(api)
    local rate = api.unit(1).burn_rate()
    return rate ~= nil and rate < 0.1 and api.unit(1).exists()
end,
action = function(api)
    api.log("Unit 1 burn rate near zero while unit exists - check if this is expected")
end
```

### `api.unit(n).heating_rate()`

Current heating rate reported by the reactor. `nil` if unavailable.

```lua
trigger = function(api)
    local hr = api.unit(2).heating_rate()
    return hr ~= nil and hr > 50000
end,
action = function(api)
    api.log("Unit 2 heating rate above 50000 - running hard")
end
```

### `api.unit(n).alarm_tripped(alarm_name)`

Returns `true` if the named alarm is currently tripped, acknowledged, or in ring-back (i.e. the underlying condition is still active, regardless of whether an operator has acknowledged it) — `false` if it's inactive, `nil` if the unit doesn't exist or the name isn't recognized.

Valid `alarm_name` values (case-sensitive, exactly as shown):

| Name | Meaning |
|---|---|
| `ContainmentBreach` | Worst-case critical: containment has been breached |
| `ContainmentRadiation` | Critical: radiation detected in containment |
| `ReactorLost` | Urgent: supervisor lost contact with the reactor |
| `CriticalDamage` | Critical: reactor damage at a critical level |
| `ReactorDamage` | Emergency: reactor taking damage |
| `ReactorOverTemp` | Emergency: reactor over temperature |
| `ReactorHighTemp` | Timely: reactor temperature elevated but not yet critical |
| `ReactorWasteLeak` | Emergency: waste leak detected |
| `ReactorHighWaste` | Timely: waste levels elevated |
| `RPSTransient` | Urgent: an RPS trip condition is active |
| `RCSTransient` | Timely: a reactor coolant system transient condition |
| `TurbineTrip` | Urgent: a turbine has tripped |
| `FacilityRadiation` | Critical: facility-wide radiation detected |

```lua
-- automation.examples/unit2_conservative_scram_on_neighbor_breach.lua
trigger = function(api)
    local u1_breach = api.unit(1).alarm_tripped("ContainmentBreach")
    local u2_temp = api.unit(2).temp()
    return u1_breach == true and u2_temp ~= nil and u2_temp > 900
end
```

### `api.unit(n).scram()`

Commands a SCRAM on this unit — the same action a front panel button or coordinator command would trigger. Always logged at WARNING level in addition to the standard "rule fired" log line, since this is the one action in the whole API that actually changes what the reactor is doing.

```lua
action = function(api)
    api.unit(2).scram()
    api.warn("Unit 2 SCRAMmed as a precaution following unit 1 containment breach")
end
```

### `api.unit(n).ack_alarm(alarm_name)`

Acknowledges one specific alarm on this unit, by the same names listed under `alarm_tripped` above. Silences it for the operator without changing the underlying condition — see the caution in `automation.examples/unit1_alarm_lamp_and_transient_autoack.lua` before using this on anything above a low-severity, expected-to-clear-itself condition.

```lua
-- automation.examples/unit1_alarm_lamp_and_transient_autoack.lua
if u1.alarm_tripped("RCSTransient") then
    u1.ack_alarm("RCSTransient")
end
```

### `api.unit(n).ack_all()`

Acknowledges every alarm currently active on this unit. The same caution applies, more so — this silences everything at once, including anything severe.

```lua
action = function(api)
    api.unit(1).ack_all()
end
```

### `api.unit(n).redstone_read(port_name)` / `api.unit(n).redstone_write(port_name, value)`

Read or write a **unit-scoped** redstone port — one that's addressed to this specific unit's I/O bank, as opposed to `api.redstone` below, which only reaches facility-wide ports. Valid `port_name` values for unit-scoped ports:

| Name | Direction | Meaning |
|---|---|---|
| `U_ACK` | input | active high, unit alarm acknowledge |
| `U_ALARM` | output | active high, unit alarm |
| `U_EMER_COOL` | output | active low, emergency coolant control |
| `U_AUX_COOL` | output | active low, auxiliary coolant control |

```lua
-- automation.examples/unit1_alarm_lamp_and_transient_autoack.lua
u1.redstone_write("U_ALARM", any_alarm == true)
```

Using a facility-scoped port name here (or vice versa, a unit-scoped name with `api.redstone`) returns `nil`/no-ops rather than erroring, since the port simply won't be found on that bank — but it also won't do what you meant, so double-check you're using the right accessor for the port you want.

---

## `api.facility`

Facility-wide readings, not tied to any one unit.

### `api.facility.energy_fill()`

The induction matrix's current charge fraction, 0-1. `nil` if no induction matrix is connected.

```lua
-- automation.examples/matrix_low_charge_indicator.lua
trigger = function(api)
    local fill = api.facility.energy_fill()
    return fill ~= nil
end,
action = function(api)
    local fill = api.facility.energy_fill()
    api.redstone.write("F_MATRIX_LOW", fill < 0.15)
end
```

---

## `api.redstone`

Facility-scoped redstone I/O — ports addressed to bank 0, the facility-wide bank. For a specific unit's own ports (`U_ACK`, `U_ALARM`, `U_EMER_COOL`, `U_AUX_COOL`), use `api.unit(n).redstone_read/write` instead, described above.

### `api.redstone.read(port_name)`

Returns `true`/`false`, or `nil` if the port name isn't recognized or isn't connected. Valid facility-scoped **input** port names:

| Name | Meaning |
|---|---|
| `F_SCRAM` | active low, facility-wide scram |
| `F_ACK` | active high, facility alarm acknowledge |
| `R_SCRAM` | active low, reactor scram |
| `R_RESET` | active high, reactor RPS reset |
| `R_ENABLE` | active high, reactor enable |

```lua
trigger = function(api)
    return api.redstone.read("F_SCRAM") == true
end,
action = function(api)
    api.log("External F_SCRAM input observed active by automation")
end
```

### `api.redstone.write(port_name, value)`

Writes `true`/`false` to a facility-scoped **digital output** port. Valid names:

| Name | Meaning |
|---|---|
| `F_ALARM` | active high, facility-wide alarm (any high priority unit alarm) |
| `F_ALARM_ANY` | active high, any alarm regardless of priority |
| `F_MATRIX_LOW` | active high, induction matrix charge low |
| `F_MATRIX_HIGH` | active high, induction matrix charge high |
| `WASTE_PU` | active low, waste → plutonium → pellets route |
| `WASTE_PO` | active low, waste → polonium route |
| `WASTE_POPL` | active low, polonium → pellets route |
| `WASTE_AM` | active low, polonium → anti-matter route |
| `R_ACTIVE` | active high, reactor is active |
| `R_AUTO_CTRL` | active high, reactor burn rate is automatic |
| `R_SCRAMMED` | active high, reactor is scrammed |
| `R_AUTO_SCRAM` | active high, reactor was automatically scrammed |
| `R_HIGH_DMG` | active high, reactor damage is high |
| `R_HIGH_TEMP` | active high, reactor is at a high temperature |
| `R_LOW_COOLANT` | active high, reactor has very low coolant |
| `R_EXCESS_HC` | active high, reactor has excess heated coolant |
| `R_EXCESS_WS` | active high, reactor has excess waste |
| `R_INSUFF_FUEL` | active high, reactor has insufficient fuel |
| `R_PLC_FAULT` | active high, reactor PLC reports a device access fault |
| `R_PLC_TIMEOUT` | active high, reactor PLC has not been heard from |

These already reflect real facility/reactor state on their own (the supervisor drives most of them itself) — a rule would typically only write to ones like `F_MATRIX_LOW`/`F_MATRIX_HIGH` if you want custom thresholds different from the built-in ones, or want a rule to be the authority for a port not otherwise driven.

```lua
-- automation.examples/matrix_low_charge_indicator.lua
action = function(api)
    local fill = api.facility.energy_fill()
    api.redstone.write("F_MATRIX_LOW", fill < 0.15)
end
```

### `api.redstone.write_analog(port_name, value, min, max)`

Writes a scaled analog (0-15) redstone signal. There's exactly one analog port in the whole system:

| Name | Meaning |
|---|---|
| `F_MATRIX_CHG` | analog charge level of the induction matrix |

`value`, `min`, and `max` work the same way as the rest of this codebase's own analog writes: `value` is scaled from the `min`-`max` range onto 0-15. For a 0-1 fraction like `energy_fill()`, use `min=0, max=1`.

```lua
-- automation.examples/matrix_charge_analog_meter.lua
action = function(api)
    local fill = api.facility.energy_fill()
    api.redstone.write_analog("F_MATRIX_CHG", fill, 0, 1)
end
```

---

## `api.log(message)` / `api.warn(message)`

Write a message to the supervisor log at INFO or WARNING level respectively. Every rule that fires already gets an automatic "rule fired" log line regardless of whether it calls either of these — use them for additional context about *why* it fired or what it did.

```lua
action = function(api)
    api.log("routine check passed")
    api.warn("this one needs attention")
end
```

## `api.tone(tone_name)`

Sets a redstone-adjacent audio tone flag for one tick. **Read this before relying on it**: the facility's own alarm system fully recomputes which tones should be playing every single tick, from current alarm conditions — a tone set here gets overwritten almost immediately unless the rule keeps re-firing. This produces an audible *blip*, not a sustained alarm. For anything that needs to keep alerting until someone deals with it, trip an actual alarm condition or drive an external siren through `api.redstone.write` instead.

Valid `tone_name` values, and which real alarm condition each corresponds to in the existing system (useful as a guide for picking one that "means" something consistent with the rest of the facility, rather than picking arbitrarily):

| Name | Used natively for |
|---|---|
| `T_1800Hz_Int_4Hz` | ContainmentBreach (worst-case critical, highest priority) |
| `T_660Hz_Int_125ms` | CriticalDamage |
| `T_544Hz_440Hz_Alt` | ReactorDamage / ReactorOverTemp / ReactorWasteLeak (emergency level) |
| `T_745Hz_Int_1Hz` | TurbineTrip (urgent) |
| `T_340Hz_Int_2Hz` | ReactorLost (urgent) |
| `T_800Hz_Int` | ReactorHighTemp / ReactorHighWaste / RCSTransient (timely level) |
| `T_1000Hz_Int` | RPSTransient (urgent) |
| `T_800Hz_1000Hz_Alt` | ContainmentRadiation / FacilityRadiation (critical, always plays if active) |

```lua
-- automation.examples/matrix_charge_analog_meter.lua
if fill < 0.10 then
    api.tone("T_745Hz_Int_1Hz")
end
```

## `api.time_ms()`

Returns the current time in milliseconds (the same clock the rest of the supervisor uses internally). Use this to build your own interval/periodic logic — there's no dedicated "run every N seconds" trigger type, because this is all it takes to build one yourself:

```lua
-- automation.examples/hourly_status_log.lua
local last_log = 0
local INTERVAL_MS = 60 * 60 * 1000 -- 1 hour

return {
    id = "hourly_status_log",
    trigger = function(api)
        local now = api.time_ms()
        if (now - last_log) >= INTERVAL_MS then
            last_log = now
            return true
        end
        return false
    end,
    action = function(api)
        api.log("hourly automation heartbeat")
    end
}
```

---

## What's deliberately not here

There's no `set_burn_rate`, no way to change RPS trip thresholds, no waste mode control, and no facility-wide SCRAM-all. A single-unit SCRAM is included because reactors are designed to handle one safely at any time — that's the entire purpose of RPS. Anything that actively changes how a reactor is being steered is a different category of risk: it can conflict with the existing automatic control loop in ways this API can't verify are safe for logic someone wrote for a specific, different situation. If you need that, it deserves a careful, purpose-built design of its own, not an addition to this list.

There's also no filesystem, peripheral, `require`, or networking access from within a rule file — not because the rule's author is untrusted (they already have full Lua access to this computer, the same as any other program on it), but because going through `api` is what keeps rules portable and this feature maintainable. If you need something `api` doesn't expose, that's a sign the right move is a change to the supervisor's own source, which was always available to you anyway.
