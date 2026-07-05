package.path = "../?.lua;../?/init.lua;" .. package.path

dofile("./cc_shim.lua")

package.loaded["scada-common.log"] = {
    info = function(...) print("[INFO] " .. table.concat({...}, "")) end,
    warning = function(...) print("[WARN] " .. table.concat({...}, "")) end,
    error = function(...) print("[ERROR] " .. table.concat({...}, "")) end,
}

local automation = dofile("../supervisor/automation.lua")

-- mock facility, same shape used throughout ------------------------------

local mock_unit = {}
mock_unit.reactor_status = { temp = 500, damage = 0, waste_fill = 0, ccool_fill = 1, hcool_fill = 1, fuel_fill = 1, act_burn_rate = 5 }
mock_unit.alarms = {}
mock_unit.scram_called = false
mock_unit.ack_called = nil
mock_unit.get_reactor_status = function() return { mock_unit.reactor_status } end
mock_unit.get_alarms = function() return mock_unit.alarms end
mock_unit.scram = function() mock_unit.scram_called = true end
mock_unit.ack_alarm = function(id) mock_unit.ack_called = id end
mock_unit.ack_all = function() mock_unit.ack_called = "ALL" end

local mock_unit2 = {}
mock_unit2.reactor_status = { temp = 500, damage = 0 }
mock_unit2.alarms = {}
mock_unit2.scram_called = false
mock_unit2.get_reactor_status = function() return { mock_unit2.reactor_status } end
mock_unit2.get_alarms = function() return mock_unit2.alarms end
mock_unit2.scram = function() mock_unit2.scram_called = true end
mock_unit2.ack_alarm = function() end
mock_unit2.ack_all = function() end

local mock_io_writes = {}
local mock_fac = {
    units = { mock_unit, mock_unit2 },
    induction = {
        { get_db = function() return { tanks = { energy_fill = 0.5 } } end }
    },
    io_ctl = {
        digital_read = function(port) return false end,
        digital_write = function(port, value) table.insert(mock_io_writes, { port = port, value = value }) end,
    },
    tone_states = {},
}

-- test 1: load the real example rules directory ---------------------------

print("=== Loading automation.examples/ (the real shipped examples) ===")
local api = automation.build_api(mock_fac)
local good_rules = automation.load("../automation.examples", api)
print("")
print("Loaded " .. #good_rules .. " rule(s) (expect 4 - two ship disabled by default but still LOAD, they just don't fire):")
for _, r in ipairs(good_rules) do
    print("  - " .. r.id .. " (enabled=" .. tostring(r.enabled ~= false) .. ")")
end

-- test 2: load the deliberately broken rules directory ---------------------

print("")
print("=== Loading intentionally broken rules (bad/) ===")
local bad_rules = automation.load("/tmp/rules_test/bad", api)
print("")
print(#bad_rules .. " rule(s) survived out of 4 broken files (expect exactly 1: syntax_error.lua, missing_action.lua, and runtime_error.lua are all broken in ways caught at LOAD time and correctly rejected; uses_disallowed_global.lua is structurally valid Lua and correctly SURVIVES loading, since its problem only exists inside its trigger function body, which doesn't run until actually triggered - see the isolation test below for that)")

-- test 3: run evaluate() against the good rules with a mock facility -------

print("")
print("=== Running evaluate() against the real example rules ===")

local engine = automation.new(good_rules, api)

-- force-enable the two disabled-by-default examples so we can exercise them
for _, r in ipairs(good_rules) do r.enabled = true end

mock_unit.reactor_status.temp = 1200
engine.evaluate()
print("After unit1 temp=1200: matrix indicator writes = " .. #mock_io_writes .. " (expect 1, from matrix_low_charge_indicator - energy_fill=0.5 is NOT below 0.15, so the write should set F_MATRIX_LOW=false)")
if #mock_io_writes > 0 then
    print("  last write: port=" .. mock_io_writes[#mock_io_writes].port .. " value=" .. tostring(mock_io_writes[#mock_io_writes].value))
end

-- test 4: the cross-unit scram example ------------------------------------

print("")
print("=== Testing the cross-unit SCRAM example rule ===")
mock_unit.alarms[1] = 2 -- ContainmentBreach = 1, ALARM_STATE.TRIPPED = 2
mock_unit2.reactor_status.temp = 950
-- reset cooldowns so this fires immediately in the test
for _, r in ipairs(good_rules) do r._last_fired = 0 end
engine.evaluate()
print("unit2 scram_called = " .. tostring(mock_unit2.scram_called) .. " (expect true)")

-- test 5: a rule that references a disallowed global should fail in isolation

print("")
print("=== Testing runtime isolation: a rule using a disallowed global shouldn't affect others ===")
local isolation_dir = "/tmp/rules_test/isolation"
os.execute("mkdir -p " .. isolation_dir)
os.execute("cp /tmp/rules_test/bad/uses_disallowed_global.lua " .. isolation_dir .. "/")
os.execute("cp ../automation.examples/unit1_high_temp_warning.lua " .. isolation_dir .. "/")

local mixed_rules = automation.load(isolation_dir, api)
print("Loaded " .. #mixed_rules .. " rule(s) from the mixed directory (expect 2 - both load fine, the bad one only fails when its trigger actually RUNS, not at load time)")

for _, r in ipairs(mixed_rules) do r._last_fired = 0; r.enabled = true end
mock_unit.reactor_status.temp = 1200

local before = #mock_io_writes
local ok, err = pcall(function()
    local mixed_engine = automation.new(mixed_rules, api)
    mixed_engine.evaluate()
end)
print("evaluate() completed without crashing the harness: " .. tostring(ok))
print("(the disallowed-global rule's own error was caught and logged internally by evaluate(), not propagated - see [ERROR] line above)")

print("")
print("All tests completed.")

print("")
print("=== Testing unit-scoped redstone and analog write (new additions) ===")

local unit_rs_writes = {}
mock_unit.get_io_ctl = function()
    return {
        digital_read = function(port) return port == 6 end, -- pretend U_ACK reads true
        digital_write = function(port, value) table.insert(unit_rs_writes, {port=port, value=value}) end,
        analog_write = function(port, value, min, max) table.insert(unit_rs_writes, {port=port, value=value, min=min, max=max}) end,
    }
end

local u1 = api.unit(1)
print("unit1 redstone_read('U_ACK') = " .. tostring(u1.redstone_read("U_ACK")) .. " (expect true)")
u1.redstone_write("U_ALARM", true)
print("unit1 redstone_write('U_ALARM', true) recorded write: port=" .. tostring(unit_rs_writes[1] and unit_rs_writes[1].port) .. " value=" .. tostring(unit_rs_writes[1] and unit_rs_writes[1].value))

local analog_writes = {}
mock_fac.io_ctl.analog_write = function(port, value, min, max) table.insert(analog_writes, {port=port, value=value, min=min, max=max}) end
api.redstone.write_analog("F_MATRIX_CHG", 8, 0, 15)
print("facility analog write recorded: " .. tostring(#analog_writes) .. " write(s), port=" .. tostring(analog_writes[1] and analog_writes[1].port))

print("")
print("All extended tests completed.")
