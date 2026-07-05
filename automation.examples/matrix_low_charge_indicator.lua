-- Turns on the F_MATRIX_LOW redstone output whenever the facility's induction
-- matrix charge drops below 15%, and turns it back off once it recovers. This
-- demonstrates a rule that drives a persistent output rather than a one-shot
-- pulse - since redstone_output is a level, not an event, we just set it to
-- whatever the current condition is every time this rule's trigger passes.

return {
    id = "matrix_low_charge_indicator",
    enabled = true,
    cooldown_s = 5,

    trigger = function(api)
        local fill = api.facility.energy_fill()
        return fill ~= nil
    end,

    action = function(api)
        local fill = api.facility.energy_fill()
        api.redstone.write("F_MATRIX_LOW", fill < 0.15)
    end
}
