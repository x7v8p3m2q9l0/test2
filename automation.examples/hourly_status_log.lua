-- Demonstrates building a periodic/interval trigger directly out of api.time_ms(),
-- rather than needing a dedicated "interval" trigger type - this is the kind of
-- thing that was a fixed enum value in the old JSON-based version and is now
-- just a couple of lines of ordinary Lua.

local last_log = 0
local INTERVAL_MS = 60 * 60 * 1000 -- 1 hour

return {
    id = "hourly_status_log",
    enabled = false,
    cooldown_s = 0, -- interval logic below handles timing itself

    trigger = function(api)
        local now = api.time_ms()
        if (now - last_log) >= INTERVAL_MS then
            last_log = now
            return true
        end
        return false
    end,

    action = function(api)
        api.log("hourly automation heartbeat - facility automation is running")
    end
}
