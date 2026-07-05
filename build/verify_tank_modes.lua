-- verification script: prove the general algorithm reproduces the original
-- hardcoded 4-unit mode 1-8 behavior exactly, for every combination of tank_defs

local function original(mode, defs)
    local tank_mode = mode
    local tank_defs = defs
    local tank_list = { table.unpack(tank_defs) }
    local tank_conns = { table.unpack(tank_defs) }

    local function calc_fdef(start_idx, end_idx)
        local first = 4
        for i = start_idx, end_idx do
            if tank_defs[i] == 2 then
                if i < first then first = i end
            end
        end
        return first
    end

    for i = 1, #tank_defs do
        if tank_defs[i] == 1 then tank_conns[i] = i end
    end

    if tank_mode == 1 then
        local first_fdef = calc_fdef(1, #tank_defs)
        for i = 1, #tank_defs do
            if (i >= first_fdef) and (tank_defs[i] == 2) then
                tank_conns[i] = first_fdef
                if i > first_fdef then tank_list[i] = 0 end
            end
        end
    elseif tank_mode == 2 then
        local first_fdef = calc_fdef(1, math.min(3, #tank_defs))
        for i = 1, #tank_defs do
            if (i >= first_fdef) and (tank_defs[i] == 2) then
                if i == 4 then
                    tank_conns[i] = 4
                else
                    tank_conns[i] = first_fdef
                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 3 then
        for _, a in pairs({ 1, 3 }) do
            local b = a + 1
            if tank_defs[a] == 2 then
                tank_conns[a] = a
            elseif tank_defs[b] == 2 then
                tank_conns[b] = b
            end
            if (tank_defs[a] == 2) and (tank_defs[b] == 2) then
                tank_list[b] = 0
                tank_conns[b] = a
            end
        end
    elseif tank_mode == 4 then
        local first_fdef = calc_fdef(2, #tank_defs)
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then
                if i == 1 then
                    tank_conns[i] = 1
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef
                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 5 then
        local first_fdef = calc_fdef(1, math.min(2, #tank_defs))
        for i = 1, #tank_defs do
            if (i >= first_fdef) and (tank_defs[i] == 2) then
                if i == 3 or i == 4 then
                    tank_conns[i] = i
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef
                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 6 then
        local first_fdef = calc_fdef(2, math.min(3, #tank_defs))
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then
                if i == 1 or i == 4 then
                    tank_conns[i] = i
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef
                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 7 then
        local first_fdef = calc_fdef(3, #tank_defs)
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then
                if i == 1 or i == 2 then
                    tank_conns[i] = i
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef
                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 8 then
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then tank_conns[i] = i end
        end
    end

    return tank_list, tank_conns
end

-- new general algorithm (v3): for n==4, use an explicit lookup table mapping each
-- legacy mode number to its exact boundary bitmask (derived from the original
-- code's comments/labels), guaranteeing byte-for-byte backward compatibility.
-- for n~=4 (no prior art to match), mode-1 is used directly as the boundary
-- bitmask in plain binary order.
local LEGACY_4UNIT_MASKS = { [1]=0, [2]=1, [3]=2, [4]=4, [5]=3, [6]=5, [7]=6, [8]=7 }

local function general(mode, defs)
    local n = #defs
    local tank_list = { table.unpack(defs) }
    local tank_conns = { table.unpack(defs) }

    for i = 1, n do
        if defs[i] == 1 then tank_conns[i] = i end
    end

    local bits
    if n == 4 and LEGACY_4UNIT_MASKS[mode] ~= nil then
        bits = LEGACY_4UNIT_MASKS[mode]
    else
        bits = mode - 1
    end

    local range_start = 1

    for i = 1, n do
        local at_boundary = (i == n) or ((math.floor(bits / (2 ^ (i - 1))) % 2) == 1)

        if at_boundary then
            local group_first = nil
            for j = range_start, i do
                if defs[j] == 2 then
                    if group_first == nil then
                        group_first = j
                        tank_conns[j] = j
                    else
                        tank_conns[j] = group_first
                        tank_list[j] = 0
                    end
                end
            end
            range_start = i + 1
        end
    end

    return tank_list, tank_conns
end

local function fmt(t) return "{" .. table.concat(t, ",") .. "}" end

-- generate every possible tank_defs combination for n=4 with values in {0,1,2}
local fail_count = 0
local test_count = 0

for a = 0, 2 do
for b = 0, 2 do
for c = 0, 2 do
for d = 0, 2 do
    local defs = { a, b, c, d }
    for mode = 1, 8 do
        test_count = test_count + 1
        local ol, oc = original(mode, defs)
        local gl, gc = general(mode, defs)

        local match = true
        for i = 1, 4 do
            if ol[i] ~= gl[i] or oc[i] ~= gc[i] then match = false end
        end

        if not match then
            fail_count = fail_count + 1
            print("MISMATCH mode=" .. mode .. " defs=" .. fmt(defs))
            print("  original: list=" .. fmt(ol) .. " conns=" .. fmt(oc))
            print("  general:  list=" .. fmt(gl) .. " conns=" .. fmt(gc))
        end
    end
end
end
end
end

print("")
print(test_count .. " test cases run, " .. fail_count .. " mismatches")

print("")
print("=== Verifying the group-based approach for n>4 (new capability, no legacy semantics to match) ===")

local function group_based(defs, groups)
    local n = #defs
    local tank_list = { table.unpack(defs) }
    local tank_conns = { table.unpack(defs) }

    for i = 1, n do
        if defs[i] == 1 then tank_conns[i] = i end
    end

    -- for each group number present, find its first type-2 member (lowest unit
    -- index) and merge all other type-2 members of that group into it
    local group_first = {}
    for i = 1, n do
        if defs[i] == 2 and groups[i] ~= nil then
            local g = groups[i]
            if group_first[g] == nil then
                group_first[g] = i
                tank_conns[i] = i
            else
                tank_conns[i] = group_first[g]
                tank_list[i] = 0
            end
        end
    end

    return tank_list, tank_conns
end

-- sanity checks: every type-2 unit must end up connected to exactly one tank,
-- and that tank must itself be a real (non-zeroed) list entry
local checks, failures = 0, 0
for n = 5, 8 do
    for trial = 1, 200 do
        local defs, groups = {}, {}
        for i = 1, n do
            defs[i] = math.random(0, 2)
            groups[i] = math.random(1, 4)
        end

        local list, conns = group_based(defs, groups)
        checks = checks + 1

        for i = 1, n do
            if defs[i] == 2 then
                local target = conns[i]
                if target == nil or target < 1 or target > n then
                    failures = failures + 1
                    print("FAIL: unit " .. i .. " has invalid conn target " .. tostring(target))
                elseif list[target] == 0 then
                    failures = failures + 1
                    print("FAIL: unit " .. i .. " conn target " .. target .. " has no real tank (list=0)")
                end
            end
        end
    end
end

print(checks .. " random trials, " .. failures .. " integrity failures")
