function widget:GetInfo()
    return {
        name    = "Auto DGun",
        desc    = "Commander auto dgun queens, mini queens, penguin and matronas when in range",
        author  = "augustin",
        date    = "2025-07-20",
        layer   = 0,
        enabled = true,
        handler = true,
    }
end

local echo = Spring.Echo
local i18n = Spring.I18N
local GetSelectedUnits = Spring.GetSelectedUnits
local GetUnitDefID = Spring.GetUnitDefID
local GetUnitTeam = Spring.GetUnitTeam
local GetUnitPosition = Spring.GetUnitPosition
local GetUnitsInCylinder = Spring.GetUnitsInCylinder
local GiveOrderToUnit = Spring.GiveOrderToUnit
local GetUnitCommands = Spring.GetUnitCommands
local IsUnitInLos = Spring.IsUnitInLos

local CMD_DGUN = CMD.DGUN
local CMD_AUTO_DGUN = 28340
local CMDTYPE = CMDTYPE or { ICON_MODE = 5 }
local ENEMY_UNITS = Spring.ENEMY_UNITS

local CMD_AUTO_DGUN_DESCRIPTION = {
    id = CMD_AUTO_DGUN,
    type = CMDTYPE.ICON_MODE,
    name = "Auto DGun",
    cursor = nil,
    action = "auto_dgun",
    params = { 0, "auto_dgun_off", "auto_dgun_on" }
}

i18n.set("en.ui.orderMenu." .. CMD_AUTO_DGUN_DESCRIPTION.params[2], "Auto DGun Off")
i18n.set("en.ui.orderMenu." .. CMD_AUTO_DGUN_DESCRIPTION.params[3], "Auto DGun On")
i18n.set("en.ui.orderMenu." .. CMD_AUTO_DGUN_DESCRIPTION.action .. "_tooltip", "Auto-DGun enemies in range")

local commanderDefs = {}
for uDefID, uDef in pairs(UnitDefs) do
    if uDef.customParams and uDef.customParams.iscommander == '1' then
        commanderDefs[uDefID] = true
    end
end

local TARGET_UNITDEF_NAMES = {
    "raptor_queen_easy",            "raptor_queen_veryeasy",
    "raptor_queen_hard",            "raptor_queen_veryhard",
    "raptor_queen_epic",            "raptor_queen_normal",
    "raptor_miniq_a",               "raptor_miniq_b",           "raptor_miniq_c",
    "raptor_consort",               "critter_penguinking",      "raptor_doombringer",
    "raptor_matriarch_basic",       "raptor_mama_ba",
	"raptor_matriarch_fire",        "raptor_mama_fi",
	"raptor_matriarch_electric",    "raptor_mama_el",
	"raptor_matriarch_acid",        "raptor_mama_ac",
}

local AUTO_DGUN_ENABLED = {}

local function checkUnits(update)
    local ids = GetSelectedUnits()
    local found = false
    for i = 1, #ids do
        local id = ids[i]
        if commanderDefs[GetUnitDefID(id)] then
            found = true
            if update then
                local mode = CMD_AUTO_DGUN_DESCRIPTION.params[1]
                if mode == 0 then
                    AUTO_DGUN_ENABLED[id] = nil
                else
                    AUTO_DGUN_ENABLED[id] = true
                end
            end
        end
    end
    return found
end

local function handleAutoDGun()
    checkUnits(true)
end

function widget:CommandsChanged()
    local ids = GetSelectedUnits()
    local found_mode = 0
    for i = 1, #ids do
        if AUTO_DGUN_ENABLED[ids[i]] then
            found_mode = 1
            break
        end
    end
    CMD_AUTO_DGUN_DESCRIPTION.params[1] = found_mode
    if checkUnits(false) then
        local cmds = widgetHandler.customCommands
        cmds[#cmds + 1] = CMD_AUTO_DGUN_DESCRIPTION
    end
end

function widget:CommandNotify(cmd_id)
    if cmd_id == CMD_AUTO_DGUN then
        local mode = CMD_AUTO_DGUN_DESCRIPTION.params[1]
        mode = (mode + 1) % 2
        CMD_AUTO_DGUN_DESCRIPTION.params[1] = mode
        checkUnits(true)
        return true
    end
end

widget.UnitDestroyed = function(_, unitID)
    AUTO_DGUN_ENABLED[unitID] = nil
end
widget.UnitTaken = widget.UnitDestroyed

local TARGET_UNITDEF_IDS = {}
for _, name in ipairs(TARGET_UNITDEF_NAMES) do
    local def = UnitDefNames and UnitDefNames[name]
    if def then
        TARGET_UNITDEF_IDS[def.id] = true
    end
end

local commanderDefIDs = {}
for id, def in pairs(UnitDefs) do
    if def.customParams and def.customParams.iscommander == "1" then
        commanderDefIDs[id] = true
    end
end

local lastCheckTime = 0
local CHECK_INTERVAL = 0.5

function widget:GameFrame(frame)
    local now = Spring.GetTimer()
    if lastCheckTime == 0 then
        lastCheckTime = now
    end
    local elapsed = Spring.DiffTimers(now, lastCheckTime)
    if elapsed < CHECK_INTERVAL then return end
    lastCheckTime = now

    for unitID in pairs(AUTO_DGUN_ENABLED) do
        local defID = GetUnitDefID(unitID)
        if commanderDefIDs[defID] then
            local ux, uy, uz = GetUnitPosition(unitID)
            if ux then
                local found = false
                local units = GetUnitsInCylinder(ux, uz, 600)
                for _, otherID in ipairs(units) do
                    if otherID ~= unitID then
                        local otherDefID = GetUnitDefID(otherID)
                        if otherDefID and TARGET_UNITDEF_IDS[otherDefID] then
                            local tx, ty, tz = GetUnitPosition(otherID)
                            if tx then
                                GiveOrderToUnit(unitID, CMD_DGUN, {tx, ty, tz}, {})
                                echo("Auto-DGun: Commander " .. unitID .. " DGunned target " .. otherID)
                                found = true
                                break
                            end
                        end
                    end
                end
                if not found then
                    echo("Checked: No target in range for commander " .. unitID)
                end
            end
        end
    end
end

function widget:Initialize()
    widgetHandler.actionHandler:AddAction(self, "auto_dgun", handleAutoDGun, nil, "p")
end

function widget:Shutdown()
    widgetHandler.actionHandler:RemoveAction(self, "auto_dgun", "p")
end