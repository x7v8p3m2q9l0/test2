-- Demonstrates a genuinely custom, multi-condition trigger that a fixed schema
-- couldn't express cleanly: SCRAM unit 2 if unit 2 is running hot AND unit 1 has
-- already tripped its own containment breach alarm - the idea being a breach on
-- one unit is reason to be more conservative with a neighboring unit that's
-- already running warm, even before unit 2's own limits are hit.
--
-- This is a real safety-relevant example, not just a syntax demo - treat it as
-- a starting point to adapt to your own facility's actual layout and risk
-- tolerance, not something to copy verbatim.

return {
    id = "unit2_conservative_scram_on_neighbor_breach",
    enabled = false, -- disabled by default; this is an example to adapt, not a default policy
    cooldown_s = 60,

    trigger = function(api)
        local u1_breach = api.unit(1).alarm_tripped("ContainmentBreach")
        local u2_temp = api.unit(2).temp()

        return u1_breach == true and u2_temp ~= nil and u2_temp > 900
    end,

    action = function(api)
        api.unit(2).scram()
        api.warn("Unit 2 SCRAMmed as a precaution following unit 1 containment breach")
    end
}
