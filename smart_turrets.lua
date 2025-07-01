function widget:GetInfo()
    return {
        name = "Smart Construction Turret",
        desc = "Forces nano turrets to assist based on your energy and metal situation",
        author = "timuela",
        date = "2025-06-15",
        layer = 0,
        enabled = true,
    }
end

--------------------------------------------------------------------------------
-- CONFIGURATION: List of all nano turrets and energy converters from units.json
--------------------------------------------------------------------------------

local TURRET_NAMES = {
    "armnanotc", "armnanotcplat", "armnanotct2", "armnanotc2plat", "armrespawn",
    "cornanotc", "cornanotcplat", "cornanotct2", "cornanotc2plat", "correspawn",
    "legnanotc", "legnanotcplat", "legnanotct2", "legnanotct2plat", "legnanotcbase",
    "armnanotct3", "cornanotct3", "legnanotct3",
}

local CONVERTER_NAMES = {
    "armmakr", "armmmkr", "armmmkrt3", "armfmkr",
    "cormakr", "cormmkr", "cormmkrt3", "corfmkr",
    "legfeconv", "legeconv", "legadveconv", "legadveconvt3", "legfmkr"
}

local ENERGY_NAMES = {
    -- Fusion Reactors
    "armafus", "armafust3", "armckfus", "armdf",
    "corafus", "corafust3", "corckfus", "corfus", "coruwfus", "cordf",
    "legafus", "legafust3", "legfus", "freefusion",
    -- Wind Turbines
    "armwin", "armwint2",
    "corwin", "corwint2",
    "legwin", "legwint2",
    -- Solar Collectors
    "armadvsol", "armsolar",
    "coradvsol", "corsolar",
    "legadvsol", "legsolar"
}

-- Convert names to UnitDefIDs for fast lookup
local TURRET_DEF_IDS = {}
local CONVERTER_DEF_IDS = {}
local REACTOR_DEF_IDS = {}
for _, name in ipairs(TURRET_NAMES) do
    local def = UnitDefNames[name]
    if def then TURRET_DEF_IDS[def.id] = true end
end
for _, name in ipairs(CONVERTER_NAMES) do
    local def = UnitDefNames[name]
    if def then CONVERTER_DEF_IDS[def.id] = true end
end
for _, name in ipairs(ENERGY_NAMES) do
    local def = UnitDefNames[name]
    if def then REACTOR_DEF_IDS[def.id] = true end
end

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

local function distance2D(x1, z1, x2, z2)
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx*dx + dz*dz)
end

-- Helper to get converter usage percent
local function GetConverterUsagePercent()
    local myTeamID = Spring.GetMyTeamID()
    local eConverted = Spring.GetTeamRulesParam(myTeamID, "mmUse") or 0
    local eConvertedMax = Spring.GetTeamRulesParam(myTeamID, "mmCapacity") or 0
    if eConvertedMax <= 0 then return 0 end
    return math.floor(100 * eConverted / eConvertedMax)
end

-- Helper to get metal storage percent
local function GetMetalStoragePercent()
    local myTeamID = Spring.GetMyTeamID()
    local metal, metalStorage = Spring.GetTeamResources(myTeamID, "metal")
    if not metal or not metalStorage or metalStorage == 0 then return 0 end
    return (metal / metalStorage) * 100
end

-- Spring.Echo("Metal storage percent:", GetMetalStoragePercent())

-- Helper to get energy storage percent
local function GetEnergyStoragePercent()
    local myTeamID = Spring.GetMyTeamID()
    local energy, energyStorage = Spring.GetTeamResources(myTeamID, "energy")
    if not energy or not energyStorage or energyStorage == 0 then return 0 end
    return (energy / energyStorage) * 100
end

-- Spring.Echo("Energy storage percent:", GetEnergyStoragePercent())

--------------------------------------------------------------------------------
-- MAIN LOGIC
--------------------------------------------------------------------------------
local lastUpdateTime = 0
local updateInterval = 1
local converterFullStreak = 0
local watchedBuildTurrets = {}

local function hasEmptyBuildQueue(unitID)
    local cmds = Spring.GetUnitCommands(unitID, 2)
    if not cmds or #cmds == 0 then
        return true
    end
    if #cmds == 1 and (cmds[1].id == CMD.FIGHT or cmds[1].id == CMD.STOP) then
        return true
    end
    return false
end

local function isBuildTurret(unitID)
    local defID = Spring.GetUnitDefID(unitID)
    if TURRET_DEF_IDS[defID] then
        return true
    end
    return false
end

function widget:UnitCmdDone(unitID)
    if hasEmptyBuildQueue(unitID) and isBuildTurret(unitID) then
        watchedBuildTurrets[unitID] = true
    end
end

function widget:CommandNotify(cmdID, cmdParams, cmdOpts)
    selectedUnits = Spring.GetSelectedUnits()

    for _,orderedUnit in ipairs(selectedUnits) do
        if isBuildTurret(orderedUnit) then
            watchedBuildTurrets[orderedUnit] = nil
        end
    end
end

function widget:Initialize()
    local myTeamID = Spring.GetMyTeamID()
    for _, unitID in ipairs(Spring.GetTeamUnits(myTeamID)) do
        if isBuildTurret(unitID) and hasEmptyBuildQueue(unitID) then
            watchedBuildTurrets[unitID] = true
        end
    end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    if unitTeam == Spring.GetMyTeamID() and isBuildTurret(unitID) and hasEmptyBuildQueue(unitID) then
        watchedBuildTurrets[unitID] = true
    end
end

function widget:GameFrame(n)
    local now = Spring.GetTimer()
    if lastUpdateTime == 0 then
        lastUpdateTime = now
    end
    local elapsed = Spring.DiffTimers(now, lastUpdateTime)
    if elapsed < updateInterval then
        return
    end
    lastUpdateTime = now

    -- Get converter usage percent
    local converterUsage = GetConverterUsagePercent()

    -- Track streak of 100% usage
    if converterUsage >= 100 then
        converterFullStreak = converterFullStreak + 1
    else
        converterFullStreak = 0
    end

    -- Find all converters under construction
    local converters = {}
    local myTeamID = Spring.GetMyTeamID()
    for _, unitID in ipairs(Spring.GetTeamUnits(myTeamID)) do
        local defID = Spring.GetUnitDefID(unitID)
        if CONVERTER_DEF_IDS[defID] then
            local unitTeam = Spring.GetUnitTeam(unitID)
            if unitTeam == myTeamID then
                local x, _, z = Spring.GetUnitPosition(unitID)
                local _, _, _, _, build = Spring.GetUnitHealth(unitID)
                if build and build < 1 then
                    converters[#converters+1] = {id=unitID, x=x, z=z}
                end
            end
        end
    end

    -- Find all reactors under construction
    local reactors = {}
    for _, unitID in ipairs(Spring.GetTeamUnits(myTeamID)) do
        local defID = Spring.GetUnitDefID(unitID)
        if REACTOR_DEF_IDS[defID] then
            local unitTeam = Spring.GetUnitTeam(unitID)
            if unitTeam == myTeamID then
                local x, _, z = Spring.GetUnitPosition(unitID)
                local _, _, _, _, build = Spring.GetUnitHealth(unitID)
                if build and build < 1 then
                    reactors[#reactors+1] = {id=unitID, x=x, z=z}
                end
            end
        end
    end

    -- Find all turrets under construction
    local turrets = {}
    for _, unitID in ipairs(Spring.GetTeamUnits(myTeamID)) do
        local defID = Spring.GetUnitDefID(unitID)
        if TURRET_DEF_IDS[defID] then
            local unitTeam = Spring.GetUnitTeam(unitID)
            if unitTeam == myTeamID then
                local x, _, z = Spring.GetUnitPosition(unitID)
                local _, _, _, _, build = Spring.GetUnitHealth(unitID)
                if build and build < 1 then
                    turrets[#turrets+1] = {id=unitID, x=x, z=z}
                end
            end
        end
    end
    -- Check metal storage percent
    local metalStoragePercent = GetMetalStoragePercent()
    local energyStoragePercent = GetEnergyStoragePercent()

    -- Decide targets based on converter usage
    local CONVERTER_STABLE_TIME = 5 -- seconds of stable 100% usage to switch to converters
    local ENERGY_STORAGE_THRESHOLD = 30 -- percent energy storage to consider converters stable
    local targets = nil

    if metalStoragePercent > 10 and #turrets > 0 then
        targets = turrets
    elseif converterUsage < 100 and #reactors > 0 then
        targets = reactors
    elseif converterFullStreak * updateInterval >= CONVERTER_STABLE_TIME and energyStoragePercent >= ENERGY_STORAGE_THRESHOLD and #converters > 0 then
        targets = converters
    end

    if not targets or #targets == 0 then return end

    -- For each nano turret, check for in-range targets and force assist
    for _, unitID in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID())) do
        local defID = Spring.GetUnitDefID(unitID)
        if TURRET_DEF_IDS[defID] and watchedBuildTurrets[unitID] then
            local ux, _, uz = Spring.GetUnitPosition(unitID)
            local buildRange = UnitDefs[defID].buildDistance or 300
            -- Gather all in-range targets
            local inRangeTargets = {}
            for _, tgt in ipairs(targets) do
                local dist = distance2D(ux, uz, tgt.x, tgt.z)
                -- Exclude if being reclaimed
                local cmds = Spring.GetUnitCommands(tgt.id, 10)
                local beingReclaimed = false
                for _, cmd in ipairs(cmds) do
                    if cmd.id == CMD.RECLAIM then
                        beingReclaimed = true
                        break
                    end
                end
                if not beingReclaimed and dist <= buildRange + (UnitDefs[Spring.GetUnitDefID(tgt.id)].radius or 0) then
                    table.insert(inRangeTargets, tgt)
                end
            end

            if #inRangeTargets > 0 then
                -- Check if already assisting/building any in-range target, or reclaiming or resurrecting something
                local cmds = Spring.GetUnitCommands(unitID, 10)
                local already = false
                local reclaiming = false
                local resurrecting = false
                for _, cmd in ipairs(cmds) do
                    if cmd.id == CMD.RECLAIM then
                        reclaiming = true
                        break
                    end
                    if cmd.id == CMD.RESURRECT then
                        resurrecting = true
                        break
                    end
                    if cmd.id == CMD.REPAIR or cmd.id == CMD.GUARD or cmd.id == CMD.BUILD then
                        for _, tgt in ipairs(inRangeTargets) do
                            if cmd.params[1] == tgt.id then
                                already = true
                                break
                            end
                        end
                    end
                    if already then break end
                end

                if not already and not reclaiming and not resurrecting then
                    -- Pick the closest in-range target to assist
                    local closest = inRangeTargets[1]
                    local minDist = distance2D(ux, uz, closest.x, closest.z)
                    for i = 2, #inRangeTargets do
                        local d = distance2D(ux, uz, inRangeTargets[i].x, inRangeTargets[i].z)
                        if d < minDist then
                            closest = inRangeTargets[i]
                            minDist = d
                        end
                    end
                    Spring.GiveOrderToUnit(unitID, CMD.REPAIR, {closest.id}, {})
                end
            end
        end
    end
end