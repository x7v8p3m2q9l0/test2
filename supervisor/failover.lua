--
-- Supervisor Primary/Backup Failover Controller
--
-- [NEW] Lightweight heartbeat-based failover between a PRIMARY supervisor and one or
-- more BACKUP supervisors covering the same reactor units.
--
-- Design intent, read this before changing behavior:
--
-- 1. A BACKUP supervisor must be structurally incapable of contending with an active
--    PRIMARY for the same PLCs/RTUs. This module does not attempt that by being clever
--    over the network - it does it by making sure a passive BACKUP never opens its
--    SVR_Channel (the channel PLCs/RTUs/coordinators actually talk on) at all. A
--    computer that isn't listening on a channel cannot respond on it, full stop. See
--    supervisor/backplane.lua for where SVR_Channel opening is gated on this module's
--    is_active() state.
--
-- 2. This module only ever promotes a BACKUP to active automatically. It never demotes
--    an active supervisor automatically, and it never lets a restarting PRIMARY silently
--    reclaim control if something else is already active for its peer group. Both of
--    those are conflict states that get logged loudly and left for a human to resolve.
--    Automatic conflict resolution in a live distributed system, without the ability to
--    test real network timing, is exactly the kind of thing that fails in ways that are
--    hard to predict - and this is reactor control, so the conservative default (stop
--    and ask a human) is the correct one, not an oversight.
--
-- 3. The heartbeat protocol is intentionally NOT the authenticated SCADA_MGMT/session
--    protocol used for PLC/RTU/coordinator links. It carries no control authority by
--    itself - hearing a heartbeat only ever influences whether THIS supervisor opens
--    its own channels; it can't make a PLC do anything. That keeps this feature fully
--    isolated from the existing secured protocol stack, so a bug here can't compromise
--    the integrity of actual reactor control traffic.
--

local util = require("scada-common.util")
local log  = require("scada-common.log")

local failover = {}

local HEARTBEAT_MAGIC = "CCMSCADA_SV_HB"
local HEARTBEAT_INTERVAL_MS = 3000

-- create a new failover controller
---@nodiscard
---@param modem table modem peripheral, already had SyncChannel opened on it by the caller
---@param sync_channel integer the dedicated heartbeat channel (must differ from SVR_Channel)
---@param peer_group integer identifies which supervisors should hear each other's heartbeats
---@param role string "PRIMARY" or "BACKUP"
---@param failover_timeout_s integer seconds without a heartbeat before a BACKUP promotes
function failover.new(modem, sync_channel, peer_group, role, failover_timeout_s)
    assert(role == "PRIMARY" or role == "BACKUP", "failover.new: role must be PRIMARY or BACKUP")

    local self = {
        modem = modem,
        sync_channel = sync_channel,
        peer_group = peer_group,
        role = role,
        active = (role == "PRIMARY"),
        promoted = false,
        conflict = false,
        last_hb_rx = util.time_ms(),
        last_hb_tx = 0
    }

    ---@class supervisor_failover
    local public = {}

    -- send a heartbeat now if this instance is active and the interval has elapsed;
    -- call this once per main loop tick regardless of role/state, it no-ops otherwise
    function public.tick_transmit()
        if not self.active then return end

        local now = util.time_ms()
        if (now - self.last_hb_tx) < HEARTBEAT_INTERVAL_MS then return end

        self.last_hb_tx = now
        self.modem.transmit(self.sync_channel, self.sync_channel, {
            magic = HEARTBEAT_MAGIC,
            group = self.peer_group,
            promoted = self.promoted,
            time = now
        })
    end

    -- feed this every "modem_message" event; it ignores anything not a matching
    -- heartbeat and returns false so the caller knows not to treat it as consumed
    ---@param channel integer
    ---@param message any
    ---@return boolean was_heartbeat
    function public.handle_message(channel, message)
        if channel ~= self.sync_channel then return false end
        if type(message) ~= "table" then return false end
        if message.magic ~= HEARTBEAT_MAGIC or message.group ~= self.peer_group then return false end

        if self.active then
            -- we are active (either the configured PRIMARY, or a promoted BACKUP) and
            -- just heard ANOTHER active peer on our group - conflict, do not resolve
            -- automatically, just make it loud and keep operating as we were
            if not self.conflict then
                self.conflict = true
                log.error("FAILOVER: detected another active supervisor on peer group " ..
                    tostring(self.peer_group) .. " while this unit is also active. This " ..
                    "will NOT be resolved automatically. Verify only one supervisor should " ..
                    "be controlling these units and stop the other one manually.")
            end
        else
            -- passive backup: this is our lifeline signal from the primary
            self.last_hb_rx = util.time_ms()
        end

        return true
    end

    -- call periodically (e.g. once per main loop tick) while passive; returns true the
    -- one time this call causes a promotion to active, so the caller can react (open
    -- SVR_Channel via backplane and start normal supervisor operation)
    ---@return boolean just_promoted
    function public.check_promote()
        if self.active then return false end

        local elapsed_s = (util.time_ms() - self.last_hb_rx) / 1000
        if elapsed_s < failover_timeout_s then return false end

        log.warning(util.c("FAILOVER: no heartbeat from primary for ", util.round(elapsed_s, 1),
            "s (timeout ", failover_timeout_s, "s) - promoting this supervisor to ACTIVE"))

        self.active = true
        self.promoted = true

        return true
    end

    -- for a PRIMARY on startup only: listen for a grace period before opening the real
    -- command channels, in case a backup already promoted while this computer was down.
    -- this is a BLOCKING call for up to grace_period_s seconds - call it before backplane
    -- opens SVR_Channel, not from inside the main event loop.
    ---@param grace_period_s integer
    ---@return boolean safe_to_activate false if a conflicting active peer was detected
    function public.startup_check(grace_period_s)
        log.info(util.c("FAILOVER: listening ", grace_period_s,
            "s for an already-active peer before activating..."))

        local deadline = util.time_ms() + (grace_period_s * 1000)

        while util.time_ms() < deadline do
            local remaining = (deadline - util.time_ms()) / 1000
            local timer_id = os.startTimer(math.max(0.05, remaining))
            local ev = { os.pullEvent() }

            if ev[1] == "modem_message" and ev[3] == self.sync_channel then
                local message = ev[5]
                if type(message) == "table" and message.magic == HEARTBEAT_MAGIC and
                   message.group == self.peer_group then
                    os.cancelTimer(timer_id)

                    log.error(util.c("FAILOVER: another supervisor is already active for peer ",
                        "group ", self.peer_group, " - refusing to activate automatically. ",
                        "Stop the other supervisor first and restart this one, or change this ",
                        "computer's Role to BACKUP if it should now be the standby."))

                    self.active = false
                    self.conflict = true
                    return false
                end
            elseif ev[1] == "timer" and ev[2] == timer_id then
                break
            end
        end

        self.active = true
        return true
    end

    -- blocking wait loop for a BACKUP at startup: does nothing but listen for heartbeats
    -- and check the failover timeout until promotion happens. returns once promoted.
    -- the caller is expected to have NOT opened SVR_Channel yet when calling this.
    function public.wait_as_backup()
        log.info(util.c("FAILOVER: starting as BACKUP for peer group ", self.peer_group,
            ", waiting for primary heartbeat (timeout ", failover_timeout_s, "s)..."))

        while true do
            local timer_id = os.startTimer(1)
            local ev = { os.pullEvent() }

            if ev[1] == "modem_message" and ev[3] == self.sync_channel then
                public.handle_message(ev[3], ev[5])
            elseif ev[1] == "timer" and ev[2] == timer_id then
                if public.check_promote() then return end
            end
        end
    end

    function public.is_active() return self.active end
    function public.has_conflict() return self.conflict end
    function public.is_promoted() return self.promoted end
    function public.get_role() return self.role end

    return public
end

return failover
