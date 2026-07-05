-- Demonstrates unit-scoped redstone (as opposed to api.redstone, which is
-- facility-scoped) and the alarm acknowledgement actions.
--
-- Drives unit 1's U_ALARM redstone output directly from whether unit 1 has any
-- tripped alarm - useful if you've wired an indicator lamp or external siren to
-- that unit's own RTU rather than a facility-wide one. Also demonstrates
-- ack_alarm on a specific, low-stakes alarm.
--
-- CAUTION on ack_alarm/ack_all: acknowledging an alarm silences it for the
-- operator without changing the underlying condition. Auto-acking anything
-- above a low-severity, expected-to-clear-itself condition can hide a real
-- problem from whoever is watching the coordinator. This example only
-- auto-acks RCSTransient, a lower-severity, often-transient condition - it
-- deliberately does NOT do this for anything like ContainmentBreach or
-- CriticalDamage, and neither should you without a specific, considered reason.

return {
    id = "unit1_alarm_lamp_and_transient_autoack",
    enabled = false, -- adapt before enabling, see caution above
    cooldown_s = 10,

    trigger = function(api)
        return api.unit(1).exists()
    end,

    action = function(api)
        local u1 = api.unit(1)

        -- keep unit 1's own alarm lamp in sync with whether it has ANY tripped
        -- alarm, not just the one we're auto-acking below
        local any_alarm = u1.alarm_tripped("ReactorHighTemp")
            or u1.alarm_tripped("ReactorHighWaste")
            or u1.alarm_tripped("RCSTransient")
            or u1.alarm_tripped("ReactorDamage")
            or u1.alarm_tripped("ContainmentBreach")

        u1.redstone_write("U_ALARM", any_alarm == true)

        if u1.alarm_tripped("RCSTransient") then
            u1.ack_alarm("RCSTransient")
        end
    end
}
