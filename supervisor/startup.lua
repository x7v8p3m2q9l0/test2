--
-- Nuclear Generation Facility SCADA Supervisor
--

require("/initenv").init_env()

local crash      = require("scada-common.crash")
local comms      = require("scada-common.comms")
local constants  = require("scada-common.constants")
local log        = require("scada-common.log")
local network    = require("scada-common.network")
local ppm        = require("scada-common.ppm")
local tcd        = require("scada-common.tcd")
local types      = require("scada-common.types")
local util       = require("scada-common.util")

local core       = require("graphics.core")

local backplane  = require("supervisor.backplane")
local configure  = require("supervisor.configure")
local databus    = require("supervisor.databus")
local facility   = require("supervisor.facility")
local failover   = require("supervisor.failover")
local renderer   = require("supervisor.renderer")
local supervisor = require("supervisor.supervisor")

local svsessions = require("supervisor.session.svsessions")

local SUPERVISOR_VERSION = "v1.10.1"

local println = util.println
local println_ts = util.println_ts

----------------------------------------
-- get configuration
----------------------------------------

if not supervisor.load_config() then
    -- try to reconfigure (user action)
    local success, error = configure.configure(true)
    if success then
        if not supervisor.load_config() then
            println("failed to load a valid configuration, please reconfigure")
            return
        end
    else
        println("configuration error: " .. error)
        return
    end
end

local config = supervisor.config

local cfv = util.new_validator()

cfv.assert_eq(#config.CoolingConfig, config.UnitCount)
assert(cfv.valid(), "startup> the number of reactor cooling configurations is different than the number of units")

for i = 1, config.UnitCount do
    cfv.assert_type_table(config.CoolingConfig[i])
    assert(cfv.valid(), "startup> missing cooling entry for reactor unit " .. i)
    cfv.assert_type_int(config.CoolingConfig[i].BoilerCount)
    cfv.assert_type_int(config.CoolingConfig[i].TurbineCount)
    cfv.assert_type_bool(config.CoolingConfig[i].TankConnection)
    assert(cfv.valid(), "startup> missing boiler/turbine/tank fields for reactor unit " .. i)
    cfv.assert_range(config.CoolingConfig[i].BoilerCount, 0, 2)
    cfv.assert_range(config.CoolingConfig[i].TurbineCount, 1, 3)
    assert(cfv.valid(), "startup> out-of-range number of boilers and/or turbines provided for reactor unit " .. i)
end

if config.FacilityTankMode > 0 then
    assert(config.UnitCount == #config.FacilityTankDefs, "startup> the number of facility tank definitions must be equal to the number of units in facility tank mode")

    for i = 1, config.UnitCount do
        local def = config.FacilityTankDefs[i]
        cfv.assert_type_int(def)
        cfv.assert_range(def, 0, 2)
        assert(cfv.valid(), "startup> invalid facility tank definition for reactor unit " .. i)

        local entry = config.FacilityTankList[i]
        cfv.assert_type_int(entry)
        cfv.assert_range(entry, 0, 2)
        assert(cfv.valid(), "startup> invalid facility tank list entry for tank " .. i)

        local conn = config.FacilityTankConns[i]
        cfv.assert_type_int(conn)
        cfv.assert_range(conn, 0, #config.FacilityTankDefs)
        assert(cfv.valid(), "startup> invalid facility tank connection for reactor unit " .. i)

        local type = config.TankFluidTypes[i]
        cfv.assert_type_int(type)
        cfv.assert_range(type, 0, types.COOLANT_TYPE.SODIUM)
        assert(cfv.valid(), "startup> invalid tank fluid type for tank " .. i)
    end
end

----------------------------------------
-- log init
----------------------------------------

log.init(config.LogPath, config.LogMode, config.LogDebug)

log.info("========================================")
log.info("BOOTING supervisor.startup " .. SUPERVISOR_VERSION)
log.info("========================================")
println(">> SCADA Supervisor " .. SUPERVISOR_VERSION .. " <<")

crash.set_env("supervisor", SUPERVISOR_VERSION)
crash.dbg_log_env()

----------------------------------------
-- main application
----------------------------------------

local function main()
    ----------------------------------------
    -- startup
    ----------------------------------------

    -- report versions
    databus.tx_versions(SUPERVISOR_VERSION, comms.version)

    -- report Mekanism configuration
    log.debug("MekanismConfig: JOULES_PER_MB = " .. constants.mek.JOULES_PER_MB)
    log.debug("MekanismConfig: TURBINE_DISPERSER_FLOW = " .. constants.mek.TURBINE_DISPERSER_FLOW)
    log.debug("MekanismConfig: TURBINE_VENT_FLOW = " .. constants.mek.TURBINE_VENT_FLOW)
    log.debug("MekanismConfig: TURBINE_GAS_PER_TANK = " .. constants.mek.TURBINE_GAS_PER_TANK)

    -- mount connected devices
    ppm.mount_all()

    -- message authentication init
    if type(config.AuthKey) == "string" and string.len(config.AuthKey) > 0 then
        network.init_mac(config.AuthKey)
    end

    -- modem initialization
    -- [NEW] failover-aware startup. when SV_SyncChannel is 0 (the default), this is a
    -- single no-op branch that behaves exactly as before - existing configs and anyone
    -- not using failover see zero behavior change. see supervisor/failover.lua for the
    -- design rationale (in particular: why conflicts are never auto-resolved).
    local sv_failover = nil
    local failover_enabled = config.SV_SyncChannel ~= 0

    if not failover_enabled then
        if not backplane.init(config, true) then return end
    else
        -- open only the sync channel first; the command channel (SVR_Channel) stays
        -- closed until this instance is confirmed/promoted to active
        if not backplane.init(config, false) then return end

        local sync_modem = ppm.get_modem(config.WiredModem)
        if sync_modem == nil then sync_modem = ppm.get_wireless_modem() end

        if sync_modem == nil then
            println_ts("startup> no modem available for failover sync channel")
            log.fatal("STARTUP: failover enabled but no modem found for SV_SyncChannel")
            return
        end

        sv_failover = failover.new(sync_modem, config.SV_SyncChannel, config.SV_PeerGroup,
            config.SV_Role, config.SV_FailoverTimeout)

        if config.SV_Role == "PRIMARY" then
            -- brief listen before claiming active status, in case a backup already
            -- promoted while this computer was offline
            if not sv_failover.startup_check(8) then
                println_ts("startup> another supervisor is already active for this peer group, see log")
                log.fatal("STARTUP: refusing to activate, conflicting active peer detected on startup")
                return
            end
        else
            -- BACKUP: block here, doing nothing but listening for the primary's
            -- heartbeat, until either it's heard (stay passive, loop continues) or it
            -- times out (promote and fall through to normal startup below)
            println_ts("startup> starting as BACKUP, waiting for primary...")
            sv_failover.wait_as_backup()
            println_ts("startup> promoted to ACTIVE, continuing startup")
        end

        backplane.activate_command_channel(config)
    end

    -- start UI
    local fp_ok, message = renderer.try_start_ui(config)

    if not fp_ok then
        println_ts(util.c("UI error: ", message))
        log.error(util.c("front panel GUI render failed with error ", message))
    else
        -- redefine println_ts local to not print as we have the front panel running
        println_ts = function (_) end
    end

    -- create facility and unit objects
    local sv_facility = facility.new(config)

    -- create network interface then setup comms
    local superv_comms = supervisor.comms(SUPERVISOR_VERSION, fp_ok, sv_facility)

    -- base loop clock (6.67Hz, 3 ticks)
    local MAIN_CLOCK = 0.15
    local loop_clock = util.new_clock(MAIN_CLOCK)

    -- halve the rate heartbeat LED flash
    local heartbeat_toggle = true

    -- local counters = {}

    -- main loop periodic tasks
    local function loop_tick()
        -- blink heartbeat indicator at half the main loop rate due to how quick it runs
        if heartbeat_toggle then databus.heartbeat() end
        heartbeat_toggle = not heartbeat_toggle

        -- [NEW] send our own failover heartbeat if we're the active instance in a
        -- failover-enabled facility; no-ops entirely when failover is disabled
        if sv_failover ~= nil then sv_failover.tick_transmit() end

        -- iterate sessions
        svsessions.iterate_all()

        -- free any closed sessions
        svsessions.free_all_closed()

        -- report energy mismatches
        databus.tx_energy_mismatch(sv_facility.has_energy_mismatch())

        -- start next clock timer
        loop_clock.start()

        -- log.debug(textutils.serialize(counters, { compact = true })); counters = {}
    end

    -- start clock
    loop_clock.start()

    -- init startup recovery
    sv_facility.boot_recovery_init(supervisor.boot_state)

    -- event loop
    while true do
        local event, param1, param2, param3, param4, param5 = util.pull_event()

        -- counters[event] = (counters[event] or 0) + 1

        -- handle event
        if event == "modem_message" then
            -- [NEW] check for our own failover heartbeat traffic first; these arrive on
            -- SyncChannel, a different channel than any SCADA protocol traffic, and are
            -- fully consumed here rather than passed to the SCADA packet parser
            local was_heartbeat = sv_failover ~= nil and sv_failover.handle_message(param2, param4)

            if not was_heartbeat then
                -- got a packet
                local packet = superv_comms.parse_packet(param1, param2, param3, param4, param5)
                if packet then superv_comms.handle_packet(packet) end
            end
        elseif event == "timer" then
            -- pass this timer event onto the right handler
            if loop_clock.is_clock(param1) then
                -- main loop tick
                loop_tick()
            elseif not svsessions.check_all_watchdogs(param1) then  -- check session watchdogs
                -- notify timer callback dispatcher, no other handler claimed this event
                tcd.handle(param1)
            end
        elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or
               event == "double_click" then
            -- handle a mouse event
            renderer.handle_mouse(core.events.new_mouse_event(event, param1, param2, param3))
        elseif event == "peripheral" then
            local type, device = ppm.mount(param1)
            if type ~= nil and device ~= nil then
                backplane.attach(param1, type, device, println_ts)
            end
        elseif event == "peripheral_detach" then
            local type, device = ppm.handle_unmount(param1)
            if type ~= nil and device ~= nil then
                backplane.detach(param1, type, device, println_ts)
            end
        end

        -- check for termination request
        if event == "terminate" or ppm.should_terminate() then
            println_ts("closing sessions...")
            log.info("terminate requested, closing sessions...")
            svsessions.close_all()
            log.info("sessions closed")
            break
        end
    end

    sv_facility.clear_boot_state()

    renderer.close_ui()

    util.println_ts("exited")
    log.info("exited")
end

if not xpcall(main, crash.handler) then
    pcall(renderer.close_ui)
    crash.exit()
else
    log.close()
end
