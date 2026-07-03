--
-- Main SCADA Coordinator GUI
--

local util          = require("scada-common.util")

local ioctl         = require("coordinator.ioctl")

local style         = require("coordinator.ui.style")

local imatrix       = require("coordinator.ui.components.imatrix")
local process_ctl   = require("coordinator.ui.components.process_ctl")
local unit_overview = require("coordinator.ui.components.unit_overview")

local core          = require("graphics.core")

local TextBox       = require("graphics.elements.TextBox")

local DataIndicator = require("graphics.elements.indicators.DataIndicator")

local ALIGN = core.ALIGN

-- create new main view
---@param main DisplayBox main displaybox
local function init(main)
    local s_header = style.theme.header

    local fac   = ioctl.get_db().facility
    local units = ioctl.get_db().units

    -- window header message
    local header = TextBox{parent=main,y=1,text="Nuclear Generation Facility SCADA Coordinator",alignment=ALIGN.CENTER,fg_bg=s_header}
    local ping = DataIndicator{parent=main,y=1,label="SVTT",format="%d",value=0,unit="ms",lu_colors=style.lg_white,width=12,fg_bg=s_header}
    -- max length example: "01:23:45 AM - Wednesday, September 28 2022"
    local datetime = TextBox{parent=main,x=(header.get_width()-42),y=1,text="",alignment=ALIGN.RIGHT,width=42,fg_bg=s_header}

    ping.register(fac.ps, "sv_ping", ping.update)
    datetime.register(fac.ps, "date_time", datetime.set_value)

    -- [FIX] previously hardcoded to exactly 2 columns x 2 rows (4 units max), with the
    -- 2nd row's 2nd column gated by "== 4" rather than a loop. Rebuilt as a genuine
    -- N-row loop: 2 columns wide, as many rows as needed for fac.num_units. Each row's
    -- height is the max of its two column heights, same accumulation approach the
    -- original 2-row version used, just generalized. The existing vertical-space assert
    -- below already anticipated needing more rows ("add an additional row of monitors"),
    -- so this completes what that message implied rather than introducing a new pattern.
    local cnc_y_start = 3
    local num_rows = math.ceil(fac.num_units / 2)

    for row = 1, num_rows do
        local left_idx = ((row - 1) * 2) + 1
        local right_idx = left_idx + 1

        local uo_left = unit_overview(main, 2, cnc_y_start, units[left_idx])
        local row_height = uo_left.get_height()

        if right_idx <= fac.num_units then
            local uo_right = unit_overview(main, 84, cnc_y_start, units[right_idx])
            row_height = math.max(row_height, uo_right.get_height())
        end

        cnc_y_start = cnc_y_start + row_height + 1

        util.nop()
    end

    -- command & control

    -- induction matrix and process control interfaces are 24 tall + space needed for divider
    local cnc_bottom_align_start = main.get_height() - 26

    assert(cnc_bottom_align_start >= cnc_y_start, "main display not of sufficient vertical resolution (add an additional row of monitors)")

    TextBox{parent=main,y=cnc_bottom_align_start,text=string.rep("\x8c", header.get_width()),alignment=ALIGN.CENTER,fg_bg=style.lg_gray}

    cnc_bottom_align_start = cnc_bottom_align_start + 2

    process_ctl(main, 2, cnc_bottom_align_start)

    util.nop()

    imatrix(main, 131, cnc_bottom_align_start, fac.induction_ps_tbl[1])
end

return init
