function widget:GetInfo()
    return {
        name    = "Holo Place",
        desc    = "Start next holo if assisted and force guarding nano turrets to assist",
        author  = "manshanko",
        date    = "2025-04-14",
        layer   = 2,
        enabled = false,
        handler = true,
    }
end

local echo = Spring.Echo
local i18n = Spring.I18N
local GetSelectedUnits = Spring.GetSelectedUnits
local GetUnitCommandCount = Spring.GetUnitCommandCount
local GetUnitDefID = Spring.GetUnitDefID
local GetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local GetUnitIsBuilding = Spring.GetUnitIsBuilding
local GetUnitCommands = Spring.GetUnitCommands
local GetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local GetUnitPosition = Spring.GetUnitPosition
local GetUnitSeparation = Spring.GetUnitSeparation
local GetUnitsInCylinder = Spring.GetUnitsInCylinder
local GiveOrderToUnit = Spring.GiveOrderToUnit
local UnitDefs = UnitDefs
local CMD_REPAIR = CMD.REPAIR
local CMD_REMOVE = CMD.REMOVE
local CMD_FIGHT = CMD.FIGHT

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
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[4], "Holo Place 30") -- don't use % sign, it breaks the UI for some reason
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[5], "Holo Place 60")
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.params[6], "Holo Place 90")
i18n.set("en.ui.orderMenu." .. CMD_HOLO_PLACE_DESCRIPTION.action .. "_tooltip", "Start next building if assisted")

local BUILDER_DEFS = {}
local NANO_DEFS = {}
local BT_DEFS = {}
local MAX_DISTANCE = 0
local HOLO_PLACERS = {}

for unit_def_id, unit_def in pairs(UnitDefs) do
    BT_DEFS[unit_def_id] = unit_def.buildTime
    if unit_def.isBuilder and not unit_def.isFactory then
        if #unit_def.buildOptions > 0 then
            BUILDER_DEFS[unit_def_id] = unit_def.buildSpeed
        end
        if not unit_def.canMove then
            NANO_DEFS[unit_def_id] = unit_def.buildDistance
            if unit_def.buildDistance > MAX_DISTANCE then
                MAX_DISTANCE = unit_def.buildDistance
            end
        end
    end
end

local function ntNearUnit(target_unit_id)
    local pos = {GetUnitPosition(target_unit_id)}
    local units_near = GetUnitsInCylinder(pos[1], pos[3], MAX_DISTANCE, -2)
    local unit_ids = {}
    for _, id in ipairs(units_near) do
        local dist = NANO_DEFS[GetUnitDefID(id)]
        if dist ~= nil and target_unit_id ~= id then
            if dist > GetUnitSeparation(target_unit_id, id, true) then
                unit_ids[#unit_ids + 1] = id
            end
        end
    end
    return unit_ids
end

local HOLO_THRESHOLDS = {
    [0] = nil,   -- off
    [1] = 0,     -- instant
    [2] = 0.3,   -- 30%
    [3] = 0.6,   -- 60%
    [4] = 0.9,   -- 90%
}

local function checkUnits(update)
    local mode = 0
    local num_hp = 0
    local num_builders = 0

    local ids = GetSelectedUnits()
    for i=1, #ids do
        local def_id = GetUnitDefID(ids[i])

        if HOLO_PLACERS[ids[i]] then
            num_hp = num_hp + 1
        end

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
        mode = (mode + 1) % 5 -- 5 options (0 to 4)
        CMD_HOLO_PLACE_DESCRIPTION.params[1] = mode
        checkUnits(true)
        return true
    end
end

local CMD_WAIT = CMD.WAIT

local function unitHasWait(unit_id)
    local cmds = GetUnitCommands(unit_id, 20)
    for i = 1, #cmds do
        if cmds[i].id == CMD_WAIT then
            return true
        end
    end
    return false
end

function widget:GameFrame()
    for unit_id, builder in pairs(HOLO_PLACERS) do
        local target_id = GetUnitIsBuilding(unit_id)
        if builder.nt_id and target_id == builder.building_id then
            local building_id = GetUnitIsBuilding(builder.nt_id)
            local num_cmds = GetUnitCommands(builder.nt_id, 0)
            if building_id == builder.building_id and num_cmds == 1 then
                local build_progress = select(5, Spring.GetUnitHealth(builder.building_id)) or 0
                local threshold = builder.threshold or 0.6 -- default to 60% if not set
                if build_progress >= threshold then
                    builder.nt_id = false
                    GiveOrderToUnit(unit_id, CMD_REMOVE, builder.cmd_tag, 0)
                end
            elseif builder.tick > 30 then
                builder.nt_id = false
                builder.building_id = false
            else
                builder.tick = builder.tick + 1
            end
        elseif target_id and target_id ~= builder.building_id then

            local nt_ids = ntNearUnit(target_id)
            for i=1, #nt_ids do
                local nt_id = nt_ids[i]
                local cmds = GetUnitCommands(nt_id, 2)
                if (cmds[2] and cmds[2].id == CMD_FIGHT)
                    or (cmds[1] and cmds[1].id == CMD_FIGHT)
                then
                    -- Check wait status and if nano is already building before issuing order
                    if not unitHasWait(nt_id) and not unitHasWait(unit_id) and not GetUnitIsBuilding(nt_id) then
                        local _, _, tag = GetUnitCurrentCommand(unit_id)
                        builder.nt_id = nt_id
                        builder.tick = 0
                        builder.building_id = target_id
                        builder.cmd_tag = tag
                        if not builder.threshold then
                            builder.threshold = HOLO_THRESHOLDS[CMD_HOLO_PLACE_DESCRIPTION.params[1]] or 0.6
                        end
                        GiveOrderToUnit(nt_id, CMD_REPAIR, target_id, 0)
                    end
                    break
                end
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