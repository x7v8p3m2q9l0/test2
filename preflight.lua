
local function c(...) local t = {...} return table.concat(t) end

local W, H = term.getSize()

local function hr()
    print(string.rep("-", W))
end

local function header(msg)
    hr()
    print(msg)
    hr()
end

-- classify a peripheral type string into a human hint about SCADA relevance
local function classify(ptype, name)
    local hints = {
        fissionReactorLogicAdapter = { role = "reactor-plc", note = "Reactor PLC: connect this computer directly to the reactor logic port." },
        boilerValve                = { role = "rtu",         note = "RTU: boiler multiblock. Wire a valve block and connect via wired modem." },
        turbineValve               = { role = "rtu",         note = "RTU: turbine multiblock. Wire a valve block and connect via wired modem." },
        dynamicValve                = { role = "rtu",        note = "RTU: dynamic tank. Wire a valve block and connect via wired modem." },
        inductionPort               = { role = "rtu",        note = "RTU: induction matrix port." },
        spsPort                     = { role = "rtu",        note = "RTU: SPS (antimatter) port." },
        sna                          = { role = "rtu",       note = "RTU: solar neutron activator." },
        environmentDetector          = { role = "rtu",       note = "RTU: environment detector (radiation). Needs Advanced Peripherals." },
        monitor                      = { role = "coordinator", note = "Coordinator: usable as a main/flow/unit display monitor." },
        modem                        = { role = "any",       note = nil }, -- handled specially below
    }
    return hints[ptype]
end

local function main()
    header("CC-MEK-SCADA PREFLIGHT CHECK")
    print("Computer ID: " .. os.getComputerID())
    if os.getComputerLabel() then print("Label: " .. os.getComputerLabel()) end
    print("")

    local names = peripheral.getNames()

    if #names == 0 then
        print("No peripherals detected at all.")
        print("Every SCADA role needs at least a modem (wired or wireless).")
        print("Attach one and re-run this check.")
        return
    end

    local wired_modem_count, wireless_modem_count = 0, 0
    local role_hits = {}
    local monitor_list = {}
    local unknown = {}

    for _, name in ipairs(names) do
        local ptype = peripheral.getType(name)

        if ptype == "modem" then
            local is_wireless = peripheral.call(name, "isWireless")
            if is_wireless then
                wireless_modem_count = wireless_modem_count + 1
            else
                wired_modem_count = wired_modem_count + 1
            end
        else
            local hint = classify(ptype, name)

            if hint then
                role_hits[hint.role] = role_hits[hint.role] or {}
                table.insert(role_hits[hint.role], { name = name, type = ptype, note = hint.note })

                if ptype == "monitor" then
                    local w, h = peripheral.call(name, "getSize")
                    table.insert(monitor_list, { name = name, w = w, h = h })
                end
            else
                table.insert(unknown, { name = name, type = ptype })
            end
        end
    end

    -- modem summary
    header("MODEMS")
    print("Wired:    " .. wired_modem_count)
    print("Wireless: " .. wireless_modem_count)
    if wired_modem_count == 0 and wireless_modem_count == 0 then
        print("")
        print("!! No modem found. Every SCADA component (PLC, RTU, supervisor,")
        print("   coordinator, pocket) needs at least one modem to talk on the")
        print("   SCADA network. Attach one and re-run this check.")
    elseif wired_modem_count == 0 then
        print("")
        print("Note: only wireless modem(s) found. That's fine for most roles,")
        print("but reactor PLC <-> supervisor links are commonly wired for")
        print("reliability in multi-reactor facilities. Wireless works too if")
        print("your build is spread out - just set TrustedRange appropriately.")
    end
    print("")

    -- peripheral-derived role hints
    header("DETECTED MEKANISM / IO PERIPHERALS")
    if next(role_hits) == nil then
        print("No Mekanism multiblock ports, reactor logic adapters, redstone")
        print("relays, or monitors detected on this computer.")
        print("")
        print("This is normal for a Supervisor (no peripherals needed beyond a")
        print("modem) or a Pocket computer. If you intended this to be an RTU")
        print("or Reactor PLC, check your wired modem connections in-game with")
        print("the modem's peripheral list, and make sure each connected block")
        print("has its wired modem side toggled ON (right-click to activate,")
        print("look for the highlighted connection cable).")
    else
        for role, items in pairs(role_hits) do
            for _, item in ipairs(items) do
                print(c("[", item.type, "] ", item.name))
                if item.note then print("   -> " .. item.note) end
            end
        end
    end
    print("")

    if #monitor_list > 0 then
        header("MONITORS")
        for _, m in ipairs(monitor_list) do
            local size_ok = (m.w and m.h and m.w >= 1 and m.h >= 1)
            print(c(m.name, ": ", tostring(m.w), "x", tostring(m.h), " blocks"))
            if not size_ok then
                print("   !! could not read size - check the monitor is fully formed")
            end
        end
        print("")
        print("Coordinator setup needs at least a Main Monitor. A Flow Monitor")
        print("and per-unit monitors are optional but recommended for larger")
        print("facilities. Recommended minimum size for the main monitor is")
        print("8 wide x 6 tall for a single-unit facility; scale up per unit.")
        print("")
    end

    if #unknown > 0 then
        header("OTHER PERIPHERALS (not SCADA-relevant)")
        for _, u in ipairs(unknown) do
            print(c("[", u.type, "] ", u.name))
        end
        print("")
    end

    header("SUGGESTED NEXT STEP")
    if role_hits["reactor-plc"] then
        print("This computer looks wired for a Reactor PLC. Run the reactor-plc")
        print("installer, then its configurator.")
    elseif role_hits["rtu"] then
        print("This computer looks wired for an RTU. Run the rtu installer,")
        print("then its configurator, and assign each detected device to the")
        print("correct reactor unit number.")
    elseif role_hits["coordinator"] then
        print("This computer has monitor(s) attached - looks like a Coordinator.")
        print("Run the coordinator installer, then its configurator.")
    elseif wired_modem_count + wireless_modem_count > 0 then
        print("Only modem(s) detected, no other peripherals. This computer is")
        print("suited to be a Supervisor (no peripherals needed) or a Pocket")
        print("computer. Run the matching installer for your intended role.")
    else
        print("Attach a modem at minimum before installing any SCADA role.")
    end
    hr()
end

main()
