-- Demonstrates the analog redstone output (F_MATRIX_CHG is the one analog port
-- in the whole system - everything else is a plain true/false signal) and a
-- custom audio tone.
--
-- Drives a redstone comparator-readable signal strength proportional to the
-- induction matrix's charge percentage - 0 when empty, 15 when full - which is
-- handy for driving an in-world charge-level display built from redstone lamps
-- or a comparator-based meter.

return {
    id = "matrix_charge_analog_meter",
    enabled = true,
    cooldown_s = 2,

    trigger = function(api)
        return api.facility.energy_fill() ~= nil
    end,

    action = function(api)
        local fill = api.facility.energy_fill()

        -- value/min/max mirrors rsctl.analog_write's own signature: scales
        -- `value` from the `min`-`max` range to a 0-15 redstone signal
        api.redstone.write_analog("F_MATRIX_CHG", fill, 0, 1)

        -- a short warning tone the moment the matrix first drops under 10%,
        -- in addition to whatever the facility's own alarms already do -
        -- remember this is a one-tick pulse, not a sustained tone, see the
        -- module header in supervisor/automation.lua
        if fill < 0.10 then
            api.tone("T_745Hz_Int_1Hz")
        end
    end
}
