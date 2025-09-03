function widget:GetInfo()
    return {
        name    = "Queen Ping",
        desc    = "Pings when a Raptor Queen dies",
        author  = "augustin",
        date    = "2025-04-05",
        version = "1.0",
        layer   = 999,
        enabled = true,
        handler = true,
    }
end

local TARGET_UNITDEF_NAMES = {
    "raptor_queen_easy", "raptor_queen_veryeasy",
    "raptor_queen_hard", "raptor_queen_veryhard",
    "raptor_queen_epic",
    "raptor_queen_normal",
}

local raptorQueenDefIDs = {}
for _, name in ipairs(TARGET_UNITDEF_NAMES) do
    local def = UnitDefNames[name]
    if def then
        raptorQueenDefIDs[def.id] = true
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
    local unitDef = UnitDefs[unitDefID]
    if not unitDef then return end

    if raptorQueenDefIDs[unitDefID] then
        local x, y, z = Spring.GetUnitPosition(unitID)
        if x and y and z then
            local pingText = "Raptor Queen Killed!"
            Spring.MarkerAddPoint(x, y, z, pingText, false)
        end
    end
end