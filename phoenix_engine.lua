function widget:GetInfo()
    return {
        name    = "Phoenix Engine",
        desc    = "Automatically reclaims blocking units when placing buildings over them, then reissues builds sequentially after reclaim completes.",
        author  = "timuela",
        date    = "2025-10-02",
        layer   = 0,
        enabled = true,
        handler = true,
    }
end

local GetSelectedUnits      = Spring.GetSelectedUnits
local GetUnitDefID          = Spring.GetUnitDefID
local GetUnitPosition       = Spring.GetUnitPosition
local GetUnitsInCylinder    = Spring.GetUnitsInCylinder
local GiveOrderToUnitArray  = Spring.GiveOrderToUnitArray
local GetUnitTeam           = Spring.GetUnitTeam
local GetMyTeamID           = Spring.GetMyTeamID
local GetUnitSeparation     = Spring.GetUnitSeparation
local GetUnitHealth         = Spring.GetUnitHealth
local GetUnitsInRectangle   = Spring.GetUnitsInRectangle
local GetUnitIsBeingBuilt   = Spring.GetUnitIsBeingBuilt
local UnitDefs              = UnitDefs
local CMD_RECLAIM           = CMD.RECLAIM

-- Command definitions
local CMD_AUTO_REPLACE = 28341
local CMD_AUTO_REPLACE_DESCRIPTION = {
    id = CMD_AUTO_REPLACE, type = (CMDTYPE or { ICON_MODE = 5 }).ICON_MODE, name = "Auto Replace", cursor = nil, action = "auto_replace",
    params = { 1, "auto_replace_off", "auto_replace_on" }
}

Spring.I18N.set("en.ui.orderMenu.auto_replace_off", "Auto Replace Off")
Spring.I18N.set("en.ui.orderMenu.auto_replace_on", "Auto Replace On")
Spring.I18N.set("en.ui.orderMenu.auto_replace_tooltip", "Automatically reclaim blocking units when placing buildings")

-- Target definitions
local TARGET_UNITDEF_NAMES = {
    "armnanotc", "armnanotcplat", "armnanotct2", "armnanotc2plat", "armnanotct3",
    "cornanotc", "cornanotcplat", "cornanotct2", "cornanotc2plat", "cornanotct3",
    "legnanotc", "legnanotcplat", "legnanotct2", "legnanotct2plat", "legnanotct3",
}

local TARGET_UNITDEF_IDS, builderDefs, NANO_DEFS = {}, {}, {}
for _, name in ipairs(TARGET_UNITDEF_NAMES) do
    local def = UnitDefNames and UnitDefNames[name]
    if def then TARGET_UNITDEF_IDS[def.id] = true end
end

for uDefID, uDef in pairs(UnitDefs) do
    if uDef.isBuilder then builderDefs[uDefID] = true end
    if uDef.isBuilder and not uDef.canMove and not uDef.isFactory then
        NANO_DEFS[uDefID] = uDef.buildDistance or 0
    end
end

-- Configuration
local BLOCKER_SEARCH_RADIUS = 100
local PIPELINE_SIZE = 3
local NANO_CACHE_UPDATE_INTERVAL = 90
local RECLAIM_RETRY_DELAY = 60
local MAX_RECLAIM_RETRIES = 50

-- States
local AUTO_REPLACE_ENABLED, builderPipelines, buildOrderCounter = {}, {}, 0
local nanoCache = { turrets = {}, lastUpdate = 0, needsUpdate = true }

-- Helper functions
local function getBuilderPipeline(builderID)
    if not builderPipelines[builderID] then
        builderPipelines[builderID] = { pendingBuilds = {}, currentlyProcessing = {}, buildingsUnderConstruction = {}, reclaimStarted = {}, reclaimRetries = {}, lastReclaimAttempt = {} }
    end
    return builderPipelines[builderID]
end

local function updateNanoCache()
    local myTeam = GetMyTeamID()
    nanoCache.turrets = {}
    for _, uid in ipairs(Spring.GetTeamUnits(myTeam)) do
        local buildDist = NANO_DEFS[GetUnitDefID(uid)]
        if buildDist then
            local x, _, z = GetUnitPosition(uid)
            if x then nanoCache.turrets[uid] = { x = x, z = z, buildDist = buildDist, team = myTeam } end
        end
    end
    nanoCache.lastUpdate, nanoCache.needsUpdate = Spring.GetGameFrame(), false
end

local function getCachedNanosNearPosition(x, z)
    local nanoIDs = {}
    for nanoID, nanoData in pairs(nanoCache.turrets) do
        local dx, dz = nanoData.x - x, nanoData.z - z
        if math.sqrt(dx * dx + dz * dz) <= nanoData.buildDist then table.insert(nanoIDs, nanoID) end
    end
    return nanoIDs
end

local function nanosNearUnit(targetUnitID)
    local x, y, z = GetUnitPosition(targetUnitID)
    if not x then return {} end
    local nanoIDs = getCachedNanosNearPosition(x, z)
    local validNanos = {}
    for _, uid in ipairs(nanoIDs) do
        if uid ~= targetUnitID then
            local sep = GetUnitSeparation(targetUnitID, uid, true)
            if sep and (sep <= nanoCache.turrets[uid].buildDist) then table.insert(validNanos, uid) end
        end
    end
    return validNanos
end

local function findBlockersAtPosition(x, z, halfX, halfZ, facing)
    local blockers, searchRadius = {}, (halfX > 0 and halfZ > 0) and math.sqrt(halfX * halfX + halfZ * halfZ) or BLOCKER_SEARCH_RADIUS
    local maybe = GetUnitsInCylinder(x, z, searchRadius, GetMyTeamID())

    if halfX > 0 and halfZ > 0 then
        local angle = math.fmod((facing or 0), 4) * (math.pi / 2)
        local cosA, sinA = math.cos(-angle), math.sin(-angle)
        for _, uid in ipairs(maybe) do
            local ux, _, uz = GetUnitPosition(uid)
            if ux then
                local dx, dz = ux - x, uz - z
                local rx, rz = cosA * dx - sinA * dz, sinA * dx + cosA * dz
                if math.abs(rx) <= halfX and math.abs(rz) <= halfZ and TARGET_UNITDEF_IDS[GetUnitDefID(uid)] then
                    table.insert(blockers, uid)
                end
            end
        end
    else
        for _, uid in ipairs(maybe) do
            if TARGET_UNITDEF_IDS[GetUnitDefID(uid)] then table.insert(blockers, uid) end
        end
    end
    return blockers
end

local function giveReclaimOrdersFromNanos(nanoIDs, targetUnitIDs)
    if #nanoIDs == 0 or #targetUnitIDs == 0 then return end
    local shuffledNanos = {}
    for i = 1, #nanoIDs do shuffledNanos[i] = nanoIDs[i] end
    for i = #shuffledNanos, 2, -1 do
        local j = math.random(1, i)
        shuffledNanos[i], shuffledNanos[j] = shuffledNanos[j], shuffledNanos[i]
    end
    local nanoIndex = 1
    for _, tgt in ipairs(targetUnitIDs) do
        GiveOrderToUnitArray({shuffledNanos[nanoIndex]}, CMD_RECLAIM, {tgt}, {"shift"})
        nanoIndex = (nanoIndex % #shuffledNanos) + 1
    end
end

local function checkUnits(update)
    local ids, found = GetSelectedUnits(), false
    for i = 1, #ids do
        local id = ids[i]
        if builderDefs[GetUnitDefID(id)] then
            found = true
            if update then
                local mode = CMD_AUTO_REPLACE_DESCRIPTION.params[1]
                AUTO_REPLACE_ENABLED[id] = (mode ~= 0) and true or nil
            end
        end
    end
    return found
end

local function isAutoReplaceEnabledForSelection()
    for _, id in ipairs(GetSelectedUnits()) do
        if builderDefs[GetUnitDefID(id)] and AUTO_REPLACE_ENABLED[id] then return true end
    end
    return false
end

-- Main game frame processing
function widget:GameFrame(n)
    -- Update nano cache periodically
    if nanoCache.needsUpdate or (n - nanoCache.lastUpdate) >= NANO_CACHE_UPDATE_INTERVAL then updateNanoCache() end

    -- Process builds every 30 frames
    if n % 30 == 0 then
        for builderID, pipeline in pairs(builderPipelines) do
            if #pipeline.pendingBuilds > 0 or #pipeline.currentlyProcessing > 0 then
                if not AUTO_REPLACE_ENABLED[builderID] then
                    builderPipelines[builderID] = nil
                else
                    table.sort(pipeline.pendingBuilds, function(a, b) return a.order < b.order end)
                    -- Fill pipeline
                    while #pipeline.currentlyProcessing < PIPELINE_SIZE and #pipeline.pendingBuilds > 0 do
                        table.insert(pipeline.currentlyProcessing, table.remove(pipeline.pendingBuilds, 1))
                    end
                    -- Process builds
                    local i = 1
                    while i <= #pipeline.currentlyProcessing do
                        local p = pipeline.currentlyProcessing[i]
                        local bx, bz = p.params[1], p.params[3]
                        local currentFrame = Spring.GetGameFrame()
                        local shouldStartReclaim = not pipeline.reclaimStarted[p.order]
                        local shouldRetryReclaim = false
                        -- Check retry conditions
                        if pipeline.reclaimStarted[p.order] then
                            local lastAttempt, retries = pipeline.lastReclaimAttempt[p.order] or 0, pipeline.reclaimRetries[p.order] or 0
                            if (currentFrame - lastAttempt) >= RECLAIM_RETRY_DELAY and retries < MAX_RECLAIM_RETRIES then
                                local remainingBlockers = findBlockersAtPosition(bx, bz, p.halfX, p.halfZ, p.facing)
                                if #remainingBlockers > 0 then
                                    shouldRetryReclaim = true
                                    pipeline.reclaimRetries[p.order] = retries + 1
                                end
                            end
                        end
                        -- Execute reclaim
                        if shouldStartReclaim or shouldRetryReclaim then
                            if #p.nanos > 0 then
                                if shouldRetryReclaim then
                                    local currentBlockers = findBlockersAtPosition(bx, bz, p.halfX, p.halfZ, p.facing)
                                    if #currentBlockers > 0 then
                                        local retryNanos, retryNanosSet = {}, {}
                                        for _, blk in ipairs(currentBlockers) do
                                            for _, n in ipairs(nanosNearUnit(blk)) do
                                                if not retryNanosSet[n] then
                                                    retryNanosSet[n] = true
                                                    table.insert(retryNanos, n)
                                                end
                                            end
                                        end
                                        giveReclaimOrdersFromNanos(retryNanos, currentBlockers)
                                    end
                                else
                                    giveReclaimOrdersFromNanos(p.nanos, p.blockers)
                                end
                            end
                            pipeline.reclaimStarted[p.order], pipeline.lastReclaimAttempt[p.order] = true, currentFrame
                        end
                        -- Check build status
                        if pipeline.buildingsUnderConstruction[p.order] then
                            local constructionInfo = pipeline.buildingsUnderConstruction[p.order]
                            local wx, wz = constructionInfo.position[1], constructionInfo.position[2]
                            local hx, hz = constructionInfo.footprint[1], constructionInfo.footprint[2]
                            local buildCompleted = false
                            for _, uid in ipairs(GetUnitsInRectangle(wx - hx, wz - hz, wx + hx, wz + hz)) do
                                if GetUnitDefID(uid) == constructionInfo.unitDefID and GetUnitTeam(uid) == GetMyTeamID() and not GetUnitIsBeingBuilt(uid) then
                                    buildCompleted = true
                                    break
                                end
                            end
                            if buildCompleted then
                                pipeline.buildingsUnderConstruction[p.order] = nil
                                pipeline.reclaimStarted[p.order] = nil
                                pipeline.reclaimRetries[p.order] = nil
                                pipeline.lastReclaimAttempt[p.order] = nil
                                table.remove(pipeline.currentlyProcessing, i)
                            else
                                i = i + 1
                            end
                        else
                            local blockers = findBlockersAtPosition(bx, bz, p.halfX, p.halfZ, p.facing)
                            if #blockers == 0 then
                                local aliveBuilders = {}
                                for _, uid in ipairs(p.builders) do
                                    local health = GetUnitHealth(uid)
                                    if health and health > 0 then table.insert(aliveBuilders, uid) end
                                end
                                if #aliveBuilders > 0 then
                                    GiveOrderToUnitArray(aliveBuilders, p.cmdID, p.params, {"shift"})
                                    pipeline.buildingsUnderConstruction[p.order] = { position = {bx, bz}, footprint = {p.halfX, p.halfZ}, unitDefID = -p.cmdID }
                                else
                                    pipeline.reclaimStarted[p.order] = nil
                                    pipeline.reclaimRetries[p.order] = nil
                                    pipeline.lastReclaimAttempt[p.order] = nil
                                    table.remove(pipeline.currentlyProcessing, i)
                                end
                            else
                                i = i + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Command handling
function widget:CommandsChanged()
    local found_mode = 0
    for _, id in ipairs(GetSelectedUnits()) do
        if AUTO_REPLACE_ENABLED[id] then found_mode = 1; break end
    end
    CMD_AUTO_REPLACE_DESCRIPTION.params[1] = found_mode
    if checkUnits(false) then
        widgetHandler.customCommands[#widgetHandler.customCommands + 1] = CMD_AUTO_REPLACE_DESCRIPTION
    end
end

function widget:CommandNotify(cmdID, cmdParams, cmdOptions)
    if cmdID == CMD_AUTO_REPLACE then
        local mode = CMD_AUTO_REPLACE_DESCRIPTION.params[1]
        CMD_AUTO_REPLACE_DESCRIPTION.params[1] = (mode + 1) % 2
        checkUnits(true)
        return true
    end
    if type(cmdID) ~= "number" or cmdID >= 0 or not isAutoReplaceEnabledForSelection() then return false end
    local bx, by, bz = tonumber(cmdParams[1]), tonumber(cmdParams[2]), tonumber(cmdParams[3])
    if not (bx and by and bz) then return false end
    local buildingDef = UnitDefs[-cmdID]
    if not buildingDef then return false end
    local halfX, halfZ = (buildingDef.footprintX or 0) / 2, (buildingDef.footprintZ or 0) / 2
    local blockers = findBlockersAtPosition(bx, bz, halfX, halfZ, cmdParams[4])
    if #blockers == 0 then return false end
    local capturedBuilders = GetSelectedUnits()
    if not capturedBuilders or #capturedBuilders == 0 then return false end
    local allNanos, nanosSet = {}, {}
    for _, blk in ipairs(blockers) do
        for _, n in ipairs(nanosNearUnit(blk)) do
            if not nanosSet[n] then
                nanosSet[n] = true
                table.insert(allNanos, n)
            end
        end
    end
    buildOrderCounter = buildOrderCounter + 1
    local assignedBuilderID = nil
    for _, builderID in ipairs(capturedBuilders) do
        if AUTO_REPLACE_ENABLED[builderID] then assignedBuilderID = builderID; break end
    end
    if not assignedBuilderID then return false end
    local pipeline = getBuilderPipeline(assignedBuilderID)
    table.insert(pipeline.pendingBuilds, {
        builders = capturedBuilders, cmdID = cmdID, params = cmdParams, halfX = halfX, halfZ = halfZ,
        facing = cmdParams[4], order = buildOrderCounter, blockers = blockers, nanos = allNanos
    })
    return true
end

-- Event handlers
widget.UnitDestroyed = function(_, unitID)
    AUTO_REPLACE_ENABLED[unitID] = nil
    builderPipelines[unitID] = nil
    if nanoCache.turrets[unitID] then nanoCache.needsUpdate = true end
end
widget.UnitTaken = widget.UnitDestroyed

widget.UnitFinished = function(_, unitID, unitDefID)
    if NANO_DEFS[unitDefID] then nanoCache.needsUpdate = true end
end

widget.UnitGiven = function(_, unitID, unitDefID)
    if NANO_DEFS[unitDefID] then nanoCache.needsUpdate = true end
end

function widget:Initialize()
    widgetHandler.actionHandler:AddAction(self, "auto_replace", function() checkUnits(true) end, nil, "p")
    nanoCache.needsUpdate = true
end

function widget:Shutdown()
    widgetHandler.actionHandler:RemoveAction(self, "auto_replace", "p")
    builderPipelines, buildOrderCounter, AUTO_REPLACE_ENABLED = {}, 0, {}
end