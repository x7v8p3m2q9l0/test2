-- Logs a warning when unit 1's core temperature climbs above 1100K, well before
-- the RPS high-temperature trip. Re-fires at most once every 30 seconds while
-- the temperature stays above threshold, rather than once per tick.

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
