--
-- Supervisor Automation Engine (Lua rule scripts)
--
-- Loads one or more .lua files from a rules directory (default /automation/) and
-- runs them once per facility update tick. Each file returns a plain table:
--
--   return {
--       id = "unit1_high_temp_warning",  -- required, unique, used in logs
--       enabled = true,                  -- optional, defaults to true
--       cooldown_s = 30,                 -- optional, defaults to 0 (no cooldown)
--
--       trigger = function(api)
--           return api.unit(1).temp() > 1100
--       end,
--
--       action = function(api)
--           api.log("Unit 1 temperature above 1100K")
--       end
--   }
--
-- `trigger` is called every tick (subject to cooldown_s). When it returns true,
-- `action` is called once, immediately after. This is real Lua, not a restricted
-- schema - combine conditions with and/or, use local variables, loop over units,
-- whatever the rule actually needs. The `api` table passed to both functions is
-- the entire surface a rule can touch; see build_api() below for exactly what
-- that is and isn't.
--
-- Why rule files run in their own environment table (the `env` argument to Lua's
-- load()) rather than as plain global-scope scripts: this isn't a security
-- sandbox against an untrusted author - whoever writes a rule file already has
-- unrestricted Lua access to every file on this computer, same as any other CC
-- program here. It's for the same reason CC:Tweaked runs every program that way:
-- one rule file's stray global variable can't leak into another's, a typo'd
-- global read fails fast instead of silently returning nil from some unrelated
-- file, and a bad rule can be isolated and reported by name instead of taking
-- down every other rule loaded alongside it.
--
-- Every action call is a direct call into an existing, already-safe public
-- function the rest of the system already uses - unit.scram(), unit.ack_alarm(),
-- the facility's own digital_write() redstone abstraction, the existing tone
-- state table the coordinator/pocket already read for alarm audio. The api table
-- doesn't expose raw internal state mutation, peripherals, or other computers'
-- files - not as a trust boundary, but because rules going through the same
-- interface the rest of the system uses is what keeps this maintainable. A rule
-- that genuinely needs more than the api table exposes can always be written as
-- a modification to the supervisor's own source instead, which was always true
-- and isn't something this module needs to work around.
--

local log   = require("scada-common.log")
local rsio  = require("scada-common.rsio")
local types = require("scada-common.types")
local util  = require("scada-common.util")

local automation = {}

local IO    = rsio.IO
local ALARM = types.ALARM

-- build the api table passed to every rule's trigger() and action() functions.
-- bound to one facility instance (fac_self, the facility module's internal self
-- table) at automation.new() time.
---@param fac_self table
---@param fac_self table
local function build_api(fac_self)
    local api = {}

    -- api.unit(n): accessors for one reactor unit's live state and safe actions.
    -- returns a fresh table each call rather than caching, since state changes
    -- tick to tick and a rule may hold onto a reference across its own logic.
    ---@param n integer unit number, 1-indexed
    function api.unit(n)
        local u = fac_self.units[n]

        local handle = {}

        -- returns nil for any field if the unit doesn't exist or hasn't reported
        -- status yet, rather than erroring - a rule checking `if api.unit(9).temp()
        -- then` on a facility with 4 units gets nil (falsy), not a crash
        local function field(name)
            if u == nil then return nil end
            local status = u.get_reactor_status()
            local mek_status = status[1]
            if mek_status == nil then return nil end
            return mek_status[name]
        end

        function handle.exists() return u ~= nil end
        function handle.temp() return field("temp") end
        function handle.damage() return field("damage") end
        function handle.waste_fill() return field("waste_fill") end
        function handle.coolant_fill() return field("ccool_fill") end
        function handle.heated_coolant_fill() return field("hcool_fill") end
        function handle.fuel_fill() return field("fuel_fill") end
        function handle.burn_rate() return field("act_burn_rate") end
        function handle.heating_rate() return field("heating_rate") end

        -- true/false/nil (nil = alarm id not recognized or unit missing)
        function handle.alarm_tripped(alarm_name)
            if u == nil then return nil end
            local id = ALARM[alarm_name]
            if id == nil then return nil end

            local alarms = u.get_alarms()
            if alarms == nil then return nil end

            local st = types.ALARM_STATE
            local s = alarms[id]
            return s == st.TRIPPED or s == st.ACKED or s == st.RING_BACK
        end

        -- actions - see module header for why this list stops here
        function handle.scram()
            if u == nil then return end
            u.scram()
            log.warning("AUTOMATION: rule commanded SCRAM on unit " .. n)
        end

        function handle.ack_alarm(alarm_name)
            if u == nil then return end
            local id = ALARM[alarm_name]
            if id ~= nil then u.ack_alarm(id) end
        end

        function handle.ack_all()
            if u == nil then return end
            u.ack_all()
        end

        -- [NEW] unit-scoped redstone ports (U_ACK, U_ALARM, U_EMER_COOL,
        -- U_AUX_COOL) are addressed to THIS unit's I/O bank, not the facility's
        -- bank 0 - api.redstone.read/write below only reach facility-scoped
        -- ports (F_*), so unit-scoped ports need this separate accessor.
        function handle.redstone_read(port_name)
            if u == nil then return nil end
            local port = IO[port_name]
            local ctl = u.get_io_ctl()
            if port == nil or ctl == nil then return nil end
            return ctl.digital_read(port)
        end

        function handle.redstone_write(port_name, value)
            if u == nil then return end
            local port = IO[port_name]
            local ctl = u.get_io_ctl()
            if port == nil or ctl == nil then return end
            ctl.digital_write(port, value == true)
        end

        return handle
    end

    -- api.facility: facility-wide readings, not tied to one unit
    api.facility = {}

    function api.facility.energy_fill()
        local imatrix = fac_self.induction and fac_self.induction[1]
        if imatrix == nil then return nil end

        local ok, db = pcall(imatrix.get_db)
        if not ok or db == nil or db.tanks == nil then return nil end

        return db.tanks.energy_fill
    end

    -- api.redstone: read/write facility-level redstone ports by name (matching
    -- the names in scada-common/rsio.lua's IO_PORT table, e.g. "F_ALARM",
    -- "F_MATRIX_LOW"). returns/accepts booleans.
    api.redstone = {}

    function api.redstone.read(port_name)
        local port = IO[port_name]
        if port == nil or fac_self.io_ctl == nil then return nil end
        return fac_self.io_ctl.digital_read(port)
    end

    function api.redstone.write(port_name, value)
        local port = IO[port_name]
        if port == nil or fac_self.io_ctl == nil then return end
        fac_self.io_ctl.digital_write(port, value == true)
    end

    -- [NEW] F_MATRIX_CHG is the one analog port in the whole IO_PORT enum
    -- (scada-common/rsio.lua) - everything else is digital (true/false). This
    -- writes a scaled 0-15 redstone signal strength from a value/min/max range,
    -- matching rsctl.analog_write's own signature.
    function api.redstone.write_analog(port_name, value, min, max)
        local port = IO[port_name]
        if port == nil or fac_self.io_ctl == nil then return end
        fac_self.io_ctl.analog_write(port, value, min, max)
    end

    -- api.log / api.warn: write to the supervisor log. every rule action already
    -- gets an automatic "rule fired" log line regardless of whether it calls
    -- these, see automation.new()'s evaluate() below.
    function api.log(message) log.info("AUTOMATION: " .. tostring(message)) end
    function api.warn(message) log.warning("AUTOMATION: " .. tostring(message)) end

    -- api.tone(name): see module header note on sound_tone-equivalent behavior -
    -- this sets a one-tick pulse in the shared tone state, not a sustained tone,
    -- because the facility's own alarm system fully rebuilds that table every
    -- tick from current alarm conditions. Trip a real alarm or drive a redstone
    -- siren for anything that needs to keep alerting.
    function api.tone(tone_name)
        local audio = require("scada-common.audio")
        local tone = audio.TONE[tone_name]
        if tone ~= nil and fac_self.tone_states ~= nil then
            fac_self.tone_states[tone] = true
        end
    end

    function api.time_ms() return util.time_ms() end

    return api
end

-- public wrapper around build_api(), exposed for testing against a mock
-- facility, and for automation.init() below
---@param fac_self table
function automation.build_api(fac_self) return build_api(fac_self) end

-- the environment every rule file's chunk runs in - see module header for why.
-- includes the standard library subset a rule would plausibly need for its own
-- logic (math, string formatting, table manipulation) plus `api`, bound per
-- facility instance when the file is actually loaded.
---@param api table
local function build_rule_env(api)
    return {
        api = api,
        pairs = pairs, ipairs = ipairs, next = next,
        type = type, tostring = tostring, tonumber = tonumber,
        select = select, assert = assert, error = error, pcall = pcall,
        math = math, string = string, table = table,
        print = print, -- shows up in the supervisor terminal, harmless and useful for testing a rule
    }
end

-- validate the table a rule file returned; returns true and no message, or
-- false and a human-readable reason
---@param rule table
---@param filename string
---@return boolean ok, string? reason
local function validate_rule(rule, filename)
    if type(rule) ~= "table" then
        return false, filename .. ": file must 'return { ... }', a table"
    end
    if type(rule.id) ~= "string" or #rule.id == 0 then
        return false, filename .. ": missing a non-empty string 'id' field"
    end
    if type(rule.trigger) ~= "function" then
        return false, filename .. " (" .. rule.id .. "): missing a 'trigger' function"
    end
    if type(rule.action) ~= "function" then
        return false, filename .. " (" .. rule.id .. "): missing an 'action' function"
    end
    if rule.enabled ~= nil and type(rule.enabled) ~= "boolean" then
        return false, filename .. " (" .. rule.id .. "): 'enabled' must be true or false if present"
    end
    if rule.cooldown_s ~= nil and (type(rule.cooldown_s) ~= "number" or rule.cooldown_s < 0) then
        return false, filename .. " (" .. rule.id .. "): 'cooldown_s' must be a non-negative number if present"
    end
    return true
end

-- create the automation engine for a facility: builds the api table once, loads
-- every rule script in dir against it, and returns an engine whose evaluate()
-- runs all successfully loaded rules. This is the only entry point most callers
-- need - see automation.load()/build_api() below if you need the pieces
-- separately (e.g. for testing against a mock facility).
---@param dir string rules directory, e.g. "/automation"
---@param fac_self table the facility module's internal self table
function automation.init(dir, fac_self)
    local api = build_api(fac_self)
    local rules = automation.load(dir, api)
    return automation.new(rules, api)
end

-- load every .lua file in a directory as a rule. a file that fails to parse,
-- fails to run, or returns something invalid is skipped with a clear log
-- message identifying exactly which file and why - it does not stop the rest
-- of the directory from loading.
---@param dir string
---@param api table from build_api(), or automation.build_api() if calling directly
---@return table[] rules successfully loaded and validated
function automation.load(dir, api)
    local rules = {}

    if not fs.isDir(dir) then
        log.info("AUTOMATION: no rules directory at " .. dir .. ", automation disabled")
        return rules
    end

    local env = build_rule_env(api)

    for _, name in ipairs(fs.list(dir)) do
        if name:sub(-4) == ".lua" then
            local path = fs.combine(dir, name)
            local file = fs.open(path, "r")

            if file == nil then
                log.error("AUTOMATION: failed to open " .. path)
            else
                local content = file.readAll()
                file.close()

                local chunk, load_err = load(content, "@" .. path, "t", env)

                if chunk == nil then
                    log.error("AUTOMATION: " .. name .. " failed to parse - " .. tostring(load_err))
                else
                    local ok, result = pcall(chunk)

                    if not ok then
                        log.error("AUTOMATION: " .. name .. " failed to run - " .. tostring(result))
                    else
                        local valid, reason = validate_rule(result, name)

                        if valid then
                            result._last_fired = 0
                            table.insert(rules, result)
                        else
                            log.error("AUTOMATION: skipping " .. tostring(reason))
                        end
                    end
                end
            end
        end
    end

    log.info(util.c("AUTOMATION: loaded ", #rules, " rule(s) from ", dir))

    return rules
end

-- create the automation engine given already-loaded rules and an api table
-- (from build_api()/automation.init()). Most callers want automation.init()
-- instead, which does both steps; this is exposed separately for testing
-- against a mock api/facility.
---@param rules table[] validated rules, from automation.load()
---@param api table from automation's internal build_api()
function automation.new(rules, api)
    ---@class supervisor_automation
    local public = {}

    -- evaluate all rules once; call this from the facility's main update tick.
    -- exceptions from a single rule's trigger or action are caught and logged
    -- rather than allowed to interrupt the facility's own update cycle - one
    -- broken rule cannot take down reactor control.
    function public.evaluate()
        local now = util.time_ms()

        for _, rule in ipairs(rules) do
            if rule.enabled ~= false then
                local cooldown_ms = (rule.cooldown_s or 0) * 1000

                if (now - rule._last_fired) >= cooldown_ms then
                    local ok, fired = pcall(rule.trigger, api)

                    if not ok then
                        log.error("AUTOMATION: rule '" .. rule.id .. "' trigger errored: " .. tostring(fired))
                    elseif fired then
                        rule._last_fired = now

                        local run_ok, err = pcall(rule.action, api)

                        if not run_ok then
                            log.error("AUTOMATION: rule '" .. rule.id .. "' action errored: " .. tostring(err))
                        else
                            log.info("AUTOMATION: rule '" .. rule.id .. "' fired")
                        end
                    end
                end
            end
        end
    end

    return public
end

return automation
