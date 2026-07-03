--
-- Publisher-Subscriber Interconnect Layer
--

local util = require("scada-common.util")

local psil = {}

-- instantiate a new interconnect layer
---@nodiscard
function psil.create()
    ---@type { [string]: { subscribers: { notify: fun(param: any) }[], value: any } } interconnect table
    local ic = {}

    -- allocate a new interconnect field
    ---@key string data key
    local function alloc(key)
        ic[key] = { subscribers = {}, value = nil, expiry = nil }
    end

    ---@class psil
    local public = {}

    -- subscribe to a data object in the interconnect<br>
    -- will call func() right away if a value is already avaliable
    ---@param key string data key
    ---@param func function function to call on change
    function public.subscribe(key, func)
        -- allocate new key if not found or notify if value is found
        if ic[key] == nil then
            alloc(key)
        elseif ic[key].value ~= nil then
            func(ic[key].value)
        end

        -- subscribe to key
        table.insert(ic[key].subscribers, { notify = func })
    end

    -- unsubscribe a function from a given key
    ---@param key string data key
    ---@param func function function to unsubscribe
    function public.unsubscribe(key, func)
        if ic[key] ~= nil then
            util.filter_table(ic[key].subscribers, function (s) return s.notify ~= func end)
        end
    end

    -- publish data to a given key, passing it to all subscribers if it has changed
    ---@param key string data key
    ---@param value any data value
    function public.publish(key, value)
        if ic[key] == nil then alloc(key) end

        -- a plain publish() clears any TTL previously set on this key, since it now
        -- represents a fresh, non-expiring value again
        ic[key].expiry = nil

        if ic[key].value ~= value then
            ic[key].value = value

            for i = 1, #ic[key].subscribers do
                ic[key].subscribers[i].notify(value)
            end
        end
    end

    -- publish data with a time-to-live; once the TTL elapses, get() on this key
    -- returns nil and subscribers are notified of the expiry with a nil value.
    -- useful for heartbeat/liveness indicators and any reading that should be treated
    -- as unknown rather than stale once its source stops publishing.
    ---@param key string data key
    ---@param value any data value
    ---@param ttl_ms integer milliseconds until this value expires
    function public.publish_ttl(key, value, ttl_ms)
        if ic[key] == nil then alloc(key) end

        ic[key].expiry = util.time_ms() + ttl_ms

        if ic[key].value ~= value then
            ic[key].value = value

            for i = 1, #ic[key].subscribers do
                ic[key].subscribers[i].notify(value)
            end
        end
    end

    -- lazily expire a key if its TTL has passed; called from get() so no timer
    -- infrastructure is needed. Notifies subscribers once on the transition to expired.
    ---@param key string data key
    local function _check_expiry(key)
        local entry = ic[key]
        if entry ~= nil and entry.expiry ~= nil and util.time_ms() >= entry.expiry then
            entry.expiry = nil
            if entry.value ~= nil then
                entry.value = nil
                for i = 1, #entry.subscribers do
                    entry.subscribers[i].notify(nil)
                end
            end
        end
    end

    -- publish a toggled boolean value to a given key, passing it to all subscribers if it has changed<br>
    -- this is intended to be used to toggle boolean indicators such as heartbeats without extra state variables
    ---@param key string data key
    function public.toggle(key)
        if ic[key] == nil then alloc(key) end

        ic[key].value = ic[key].value == false

        for i = 1, #ic[key].subscribers do
            ic[key].subscribers[i].notify(ic[key].value)
        end
    end

    -- get the currently stored value for a key, or nil if not set (or expired)
    ---@param key string data key
    ---@return any
    function public.get(key)
        _check_expiry(key)
        if ic[key] ~= nil then return ic[key].value else return nil end
    end

    -- clear the contents of the interconnect
    function public.purge() ic = {} end

    return public
end

return psil
