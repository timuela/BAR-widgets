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

-- Helper function to convert RGB values to Spring-compatible string format
local function colourNames(R, G, B)
    local R255 = math.floor(R * 255)
    local G255 = math.floor(G * 255)
    local B255 = math.floor(B * 255)
    if R255 % 10 == 0 then
        R255 = R255 + 1
    end
    if G255 % 10 == 0 then
        G255 = G255 + 1
    end
    if B255 % 10 == 0 then
        B255 = B255 + 1
    end
    return "\255" .. string.char(R255) .. string.char(G255) .. string.char(B255)
end

-- Define target unitDefIDs based on names
local TARGET_UNITDEF_NAMES = {
    "raptor_queen_easy", "raptor_queen_veryeasy",
    "raptor_queen_hard", "raptor_queen_veryhard",
    "raptor_queen_epic",
    "raptor_queen_normal",
    -- "raptor_miniq_a", "raptor_miniq_b", "raptor_miniq_c",
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
            local color = {1, 0, 0, 1} -- Red color for the ping
            local pingText = "Raptor Queen Killed!"
            Spring.MarkerAddPoint(x, y, z, colourNames(color[1], color[2], color[3]) .. pingText, false)
        end
    end
end