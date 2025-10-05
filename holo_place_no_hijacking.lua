function widget:GetInfo()
    return {
        name    = "Holo Place - No hijack",
        desc    = "Start next holo immediately without checking for assisting turrets",
        author  = "augustin, manshanko",
        date    = "2025-04-14",
        layer   = 2,
        enabled = false,
        handler = true,
    }
end

local echo = Spring.Echo
local i18n = Spring.I18N
local GetSelectedUnits = Spring.GetSelectedUnits
local GetUnitDefID = Spring.GetUnitDefID
local GetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local GetUnitIsBuilding = Spring.GetUnitIsBuilding
local GetUnitCommands = Spring.GetUnitCommands
local GetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local GiveOrderToUnit = Spring.GiveOrderToUnit
local UnitDefs = UnitDefs
local CMD_REMOVE = CMD.REMOVE

local CMD_HOLO_PLACE = 28339
local CMD_HOLO_PLACE_DESCRIPTION = {
    id = CMD_HOLO_PLACE,
    type = CMDTYPE.ICON_MODE,
    name = "Holo Place",
    cursor = nil,
    action = "holo_place",
    params = { 0, "holo_place_off", "holo_place_ins", "holo_place_30", "holo_place_60", "holo_place_90" }
}

i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[2], "Holo Place off")
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[3], "Holo Place Ins")
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[4], "Holo Place 30")
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[5], "Holo Place 60")
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[6], "Holo Place 90")
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.action .. "_tooltip", "Start next building automatically")

local BUILDER_DEFS = {}
local BT_DEFS = {}
local HOLO_PLACERS = {}

for unit_def_id, unit_def in pairs(UnitDefs) do
    BT_DEFS[unit_def_id] = unit_def.buildTime
    if unit_def.isBuilder and not unit_def.isFactory then
        if #unit_def.buildOptions > 0 then
            BUILDER_DEFS[unit_def_id] = unit_def.buildSpeed
        end
    end
end

local HOLO_THRESHOLDS = {
    [0] = nil,   -- off
    [1] = 0,     -- instant
    [2] = 0.3,   -- 30%
    [3] = 0.6,   -- 60%
    [4] = 0.9,   -- 90%
}

local function checkUnits(update)
    local num_builders = 0
    local ids = GetSelectedUnits()

    for i=1, #ids do
        local def_id = GetUnitDefID(ids[i])
        if BUILDER_DEFS[def_id] then
            num_builders = num_builders + 1
        end
    end

    if num_builders > 0 then
        if update then
            local mode = CMD_HOLO_PLACE_DESCRIPTION.params[1]
            for i=1, #ids do
                if mode == 0 then
                    HOLO_PLACERS[ids[i]] = nil
                else
                    HOLO_PLACERS[ids[i]] = HOLO_PLACERS[ids[i]] or {}
                    HOLO_PLACERS[ids[i]].threshold = HOLO_THRESHOLDS[mode]
                end
            end
        end
        return true
    end
end

local function handleHoloPlace()
    checkUnits(true)
end

local function ForgetUnit(self, unit_id)
    HOLO_PLACERS[unit_id] = nil
end

widget.UnitDestroyed = ForgetUnit
widget.UnitTaken = ForgetUnit

function widget:CommandsChanged()
    local ids = GetSelectedUnits()
    local found_mode = 0
    for i = 1, #ids do
        local placer = HOLO_PLACERS[ids[i]]
        if placer and placer.threshold then
            for mode, threshold in pairs(HOLO_THRESHOLDS) do
                if placer.threshold == threshold then
                    found_mode = mode
                    break
                end
            end
            break
        end
    end
    CMD_HOLO_PLACE_DESCRIPTION.params[1] = found_mode
    if checkUnits(false) then
        local cmds = widgetHandler.customCommands
        cmds[#cmds + 1] = CMD_HOLO_PLACE_DESCRIPTION
    end
end

function widget:CommandNotify(cmd_id, cmd_params, cmd_options)
    if cmd_id == CMD_HOLO_PLACE then
        local mode = CMD_HOLO_PLACE_DESCRIPTION.params[1]
        mode = (mode + 1) % 5
        CMD_HOLO_PLACE_DESCRIPTION.params[1] = mode
        checkUnits(true)
        return true
    end
end

function widget:GameFrame()
    for unit_id, builder in pairs(HOLO_PLACERS) do
        local target_id = GetUnitIsBuilding(unit_id)

        -- If builder is working on a new target building
        if target_id and target_id ~= builder.building_id then
            builder.building_id = target_id
        end

        -- If builder is still building, check progress
        if builder.building_id then
            local build_progress = select(5, Spring.GetUnitHealth(builder.building_id)) or 0
            local threshold = builder.threshold
            if build_progress >= threshold then
                local _, _, tag = GetUnitCurrentCommand(unit_id)
                if tag then
                    GiveOrderToUnit(unit_id, CMD_REMOVE, tag, 0)
                end
                builder.building_id = false
            end
        end
    end
end

function widget:Initialize()
    widgetHandler.actionHandler:AddAction(self, "holo_place", handleHoloPlace, nil, "p")
end

function widget:Shutdown()
    widgetHandler.actionHandler:RemoveAction(self, "holo_place", "p")
end
