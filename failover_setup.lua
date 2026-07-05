--
-- Failover Setup Helper
--
-- [NEW] The supervisor's failover fields (SV_Role, SV_SyncChannel, SV_PeerGroup,
-- SV_FailoverTimeout) are opt-in and have safe defaults (a plain PRIMARY with failover
-- disabled) - see supervisor/failover.lua for the design. There's no page in the main
-- graphical configurator for them; wiring a new screen into that multi-pane wizard
-- without being able to render it was a bigger risk than it was worth for an advanced,
-- opt-in feature. Wiring it into that config wizard is exactly the kind of thing that
-- needs to be checked with the actual live CC display, and this couldn't be verified.
--
-- This script sets them correctly instead. It's important to use this rather than
-- CC's built-in "set" shell command: this app loads/saves its config from a custom
-- path (/supervisor.settings), not CC's default settings location, so the built-in
-- "set" command would silently save to the wrong file and have no effect here.
--
-- Usage: run this on the supervisor computer, before or after normal configuration.
-- Run it again any time to change these settings; existing PLC/RTU/coordinator/
-- facility config is untouched.
--

local function ask(prompt, default)
    write(prompt)
    if default ~= nil then write(" [" .. tostring(default) .. "]") end
    write(": ")
    local input = read()
    if input == "" or input == nil then return default end
    return input
end

local function ask_int(prompt, default)
    while true do
        local raw = ask(prompt, default)
        local n = tonumber(raw)
        if n ~= nil and n == math.floor(n) then return n end
        print("Please enter a whole number.")
    end
end

print("== cc-mek-scada Failover Setup ==")
print("")
print("This configures primary/backup failover between two or more supervisors")
print("covering the SAME reactor units. If you just want to split units across")
print("independent supervisors instead (less work per supervisor, not backup/")
print("redundancy of the same units), you don't need this - just run separate")
print("supervisor + coordinator pairs, each with its own disjoint unit set.")
print("")

if not settings.load("/supervisor.settings") then
    print("Could not find an existing /supervisor.settings file.")
    print("Run this computer's normal supervisor configurator first, then come")
    print("back and run this script.")
    return
end

local current_role = settings.get("SV_Role", "PRIMARY")
print("Current role: " .. current_role)
print("")

local role = nil
while role ~= "PRIMARY" and role ~= "BACKUP" do
    role = string.upper(ask("Role (PRIMARY or BACKUP)", current_role))
    if role ~= "PRIMARY" and role ~= "BACKUP" then
        print("Please enter PRIMARY or BACKUP.")
    end
end

print("")
print("SyncChannel is a dedicated heartbeat channel, separate from your normal")
print("SVR_Channel. It must be the SAME value on every supervisor in this")
print("failover group, and must NOT match SVR_Channel, PLC_Channel, RTU_Channel,")
print("CRD_Channel, or PKT_Channel on any of them.")
local sync_channel = ask_int("SyncChannel", settings.get("SV_SyncChannel", 0))

print("")
print("PeerGroup lets multiple independent failover groups share a network")
print("without cross-detecting each other's heartbeats. Use the same number on")
print("every supervisor in ONE failover group, and a different number for any")
print("other, unrelated failover group on the same network.")
local peer_group = ask_int("PeerGroup", settings.get("SV_PeerGroup", 0))

local failover_timeout = settings.get("SV_FailoverTimeout", 15)
if role == "BACKUP" then
    print("")
    print("FailoverTimeout is how many seconds of silence from the primary before")
    print("this backup promotes itself to active. Too short risks a false")
    print("promotion from normal network jitter; too long means longer downtime")
    print("before the backup takes over. 15-30s is reasonable for most setups.")
    failover_timeout = ask_int("FailoverTimeout (seconds, min 5)", failover_timeout)
    if failover_timeout < 5 then failover_timeout = 5 end
end

settings.set("SV_Role", role)
settings.set("SV_SyncChannel", sync_channel)
settings.set("SV_PeerGroup", peer_group)
settings.set("SV_FailoverTimeout", failover_timeout)

if settings.save("/supervisor.settings") then
    print("")
    print("Saved. Restart this computer for the change to take effect.")
    print("")
    if sync_channel == 0 then
        print("SyncChannel is 0, which means failover is DISABLED - this computer")
        print("will behave exactly as an ordinary standalone supervisor.")
    elseif role == "PRIMARY" then
        print("This supervisor will start active as normal, but will briefly check")
        print("for an already-active peer on PeerGroup " .. peer_group .. " before")
        print("opening its command channel. If one is found, it will refuse to")
        print("activate automatically and will require manual resolution - check")
        print("the log if that happens.")
    else
        print("This supervisor will start PASSIVE - it will not open its command")
        print("channel or respond to any PLC/RTU/coordinator until it either hears")
        print("no heartbeat from the primary for " .. failover_timeout .. "s, or you")
        print("reconfigure it. While passive it is structurally invisible on the")
        print("network - it cannot contend with the primary for the same devices.")
    end
else
    print("")
    print("Failed to save settings.")
end
