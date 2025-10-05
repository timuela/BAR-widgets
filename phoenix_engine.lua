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

-- Spring API shortcuts
local echo = Spring.Echo
local i18n = Spring.I18N
local GetSelectedUnits       = Spring.GetSelectedUnits
local GetUnitDefID           = Spring.GetUnitDefID
local GetUnitPosition        = Spring.GetUnitPosition
local GetUnitsInCylinder     = Spring.GetUnitsInCylinder
local GiveOrderToUnitArray   = Spring.GiveOrderToUnitArray
local GetUnitTeam            = Spring.GetUnitTeam
local GetMyTeamID            = Spring.GetMyTeamID
local GetUnitSeparation      = Spring.GetUnitSeparation
local GetUnitHealth          = Spring.GetUnitHealth
local GetUnitsInRectangle    = Spring.GetUnitsInRectangle
local GetUnitIsBeingBuilt    = Spring.GetUnitIsBeingBuilt

local UnitDefs               = UnitDefs
local CMD_RECLAIM            = CMD.RECLAIM

-- Command definitions for Auto Replace toggle
local CMD_AUTO_REPLACE = 28341
local CMDTYPE = CMDTYPE or { ICON_MODE = 5 }

local CMD_AUTO_REPLACE_DESCRIPTION = {
    id = CMD_AUTO_REPLACE,
    type = CMDTYPE.ICON_MODE,
    name = "Auto Replace",
    cursor = nil,
    action = "auto_replace",
    params = { 1, "auto_replace_off", "auto_replace_on" }
}

i18n.set("en.ui.orderMenu." .. CMD_AUTO_REPLACE_DESCRIPTION.params[2], "Auto Replace Off")
i18n.set("en.ui.orderMenu." .. CMD_AUTO_REPLACE_DESCRIPTION.params[3], "Auto Replace On")
i18n.set("en.ui.orderMenu." .. CMD_AUTO_REPLACE_DESCRIPTION.action .. "_tooltip", "Automatically reclaim blocking units when placing buildings")

-- Target units that can be reclaimed (add more as needed)
local TARGET_UNITDEF_NAMES = {
    "armnanotc", "armnanotcplat", "armnanotct2", "armnanotc2plat", "armnanotct3",
    "cornanotc", "cornanotcplat", "cornanotct2", "cornanotc2plat", "cornanotct3",
    "legnanotc", "legnanotcplat", "legnanotct2", "legnanotct2plat", "legnanotct3",
}

-- Convert unit names to unit def IDs for faster lookup
local TARGET_UNITDEF_IDS = {}
for _, name in ipairs(TARGET_UNITDEF_NAMES) do
    local def = UnitDefNames and UnitDefNames[name]
    if def then
        TARGET_UNITDEF_IDS[def.id] = true
    end
end

-- Builder unit definitions (units that can build)
local builderDefs = {}
for uDefID, uDef in pairs(UnitDefs) do
    if uDef.isBuilder then
        builderDefs[uDefID] = true
    end
end

-- Track which builders have Auto Replace enabled
local AUTO_REPLACE_ENABLED = {}

-- Configuration
local BLOCKER_SEARCH_RADIUS = 100
local PIPELINE_SIZE = 3
local NANO_CACHE_UPDATE_INTERVAL = 90
local RECLAIM_RETRY_DELAY = 60
local MAX_RECLAIM_RETRIES = 50

local builderPipelines = {}
local buildOrderCounter = 0

-- Nano turret caching system
local nanoCache = {
    turrets = {},
    lastUpdate = 0,
    needsUpdate = true
}

-- Helper function to get or create pipeline for a builder
local function getBuilderPipeline(builderID)
    if not builderPipelines[builderID] then
        builderPipelines[builderID] = {
            pendingBuilds = {},
            currentlyProcessing = {},
            buildingsUnderConstruction = {},
            reclaimStarted = {},
            reclaimRetries = {},
            lastReclaimAttempt = {}
        }
    end
    return builderPipelines[builderID]
end

-- Helper function to clean up pipeline for a builder
local function cleanupBuilderPipeline(builderID)
    builderPipelines[builderID] = nil
end

local NANO_DEFS = {}
-- Update nano turret cache
local function updateNanoCache()
    local myTeam = GetMyTeamID()
    nanoCache.turrets = {}

    -- Get all our units and filter for nano turrets
    local allUnits = Spring.GetTeamUnits(myTeam)
    for _, uid in ipairs(allUnits) do
        local udid = GetUnitDefID(uid)
        local buildDist = NANO_DEFS[udid]
        if buildDist then
            local x, _, z = GetUnitPosition(uid)
            if x then
                nanoCache.turrets[uid] = {
                    x = x,
                    z = z,
                    buildDist = buildDist,
                    team = myTeam
                }
            end
        end
    end

    nanoCache.lastUpdate = Spring.GetGameFrame()
    nanoCache.needsUpdate = false
end

-- Get nano turrets from cache that can reach a target position
local function getCachedNanosNearPosition(x, z)
    local nanoIDs = {}
    for nanoID, nanoData in pairs(nanoCache.turrets) do
        local dx = nanoData.x - x
        local dz = nanoData.z - z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= nanoData.buildDist then
            table.insert(nanoIDs, nanoID)
        end
    end
    return nanoIDs
end

-- Check if any selected units are builders and update their auto replace state
local function checkUnits(update)
    local ids = GetSelectedUnits()
    local found = false
    for i = 1, #ids do
        local id = ids[i]
        if builderDefs[GetUnitDefID(id)] then
            found = true
            if update then
                local mode = CMD_AUTO_REPLACE_DESCRIPTION.params[1]
                if mode == 0 then
                    AUTO_REPLACE_ENABLED[id] = nil
                else
                    AUTO_REPLACE_ENABLED[id] = true
                end
            end
        end
    end
    return found
end

-- Handle auto replace toggle
local function handleAutoReplace()
    checkUnits(true)
end

-- Check if auto replace is enabled for any of the selected builders
local function isAutoReplaceEnabledForSelection()
    local ids = GetSelectedUnits()
    for i = 1, #ids do
        local id = ids[i]
        if builderDefs[GetUnitDefID(id)] and AUTO_REPLACE_ENABLED[id] then
            return true
        end
    end
    return false
end

-- Precompute nano-type units (non-moving builders, non-factories) & their buildDistance
local MAX_NANO_DISTANCE = 0
for udid, ud in pairs(UnitDefs) do
    if ud.isBuilder and (not ud.canMove) and (not ud.isFactory) then
        local bd = ud.buildDistance or 0
        NANO_DEFS[udid] = bd
        if bd > MAX_NANO_DISTANCE then
            MAX_NANO_DISTANCE = bd
        end
    end
end

-- small helper: find nearby nano turrets
local function nanosNearUnit(targetUnitID)
    local x, y, z = GetUnitPosition(targetUnitID)
    if not x then return {} end

    -- Use cached nano positions for better performance
    local nanoIDs = getCachedNanosNearPosition(x, z)

    -- Filter out the target unit itself and verify separation
    local validNanos = {}
    for _, uid in ipairs(nanoIDs) do
        if uid ~= targetUnitID then
            local sep = GetUnitSeparation(targetUnitID, uid, true)
            if sep and (sep <= nanoCache.turrets[uid].buildDist) then
                table.insert(validNanos, uid)
            end
        end
    end
    return validNanos
end

-- find any target units overlapping the requested placement position.
local function findBlockersAtPosition(x, z, halfX, halfZ, facing)
    local blockers = {}
    local doRectCheck = (halfX > 0 and halfZ > 0)
    local searchRadius
    local maybe

    if doRectCheck then
        local halfDiag = math.sqrt(halfX * halfX + halfZ * halfZ)
        searchRadius = halfDiag
        local angle = math.fmod((facing or 0), 4) * (math.pi / 2)
        local cosA = math.cos(-angle)
        local sinA = math.sin(-angle)
        local myTeam = GetMyTeamID()
        maybe = GetUnitsInCylinder(x, z, searchRadius, myTeam)
        for _, uid in ipairs(maybe) do
            local ux, _, uz = GetUnitPosition(uid)
            if ux then
                local dx = ux - x
                local dz = uz - z
                local rx = cosA * dx - sinA * dz
                local rz = sinA * dx + cosA * dz
                if math.abs(rx) <= halfX and math.abs(rz) <= halfZ then
                    local udid = GetUnitDefID(uid)
                    if TARGET_UNITDEF_IDS[udid] then
                        table.insert(blockers, uid)
                    end
                end
            end
        end
    else
        searchRadius = BLOCKER_SEARCH_RADIUS
        local myTeam = GetMyTeamID()
        maybe = GetUnitsInCylinder(x, z, searchRadius, myTeam)
        for _, uid in ipairs(maybe) do
            local ux, _, uz = GetUnitPosition(uid)
            if ux then
                local udid = GetUnitDefID(uid)
                if TARGET_UNITDEF_IDS[udid] then
                    table.insert(blockers, uid)
                end
            end
        end
    end
    return blockers
end

-- Utility to send reclaim orders
local function giveReclaimOrdersFromNanos(nanoIDs, targetUnitIDs)
    if #nanoIDs == 0 or #targetUnitIDs == 0 then
        return
    end

    -- Shuffle mode: distribute targets among nanos to balance load
    local shuffledNanos = {}
    for i = 1, #nanoIDs do
        shuffledNanos[i] = nanoIDs[i]
    end

    -- Shuffle the nano array
    for i = #shuffledNanos, 2, -1 do
        local j = math.random(1, i)
        shuffledNanos[i], shuffledNanos[j] = shuffledNanos[j], shuffledNanos[i]
    end

    local options = {"shift"}
    local nanoIndex = 1

    -- Distribute targets among shuffled nanos
    for _, tgt in ipairs(targetUnitIDs) do
        local nano = shuffledNanos[nanoIndex]
        GiveOrderToUnitArray({nano}, CMD_RECLAIM, {tgt}, options)
        nanoIndex = (nanoIndex % #shuffledNanos) + 1
    end
end

-- Keep a simple coroutine-driven queue if we need to spread heavy work over frames
local tasksCoroutine = nil
local function startTasksCoroutine(fn)
    tasksCoroutine = coroutine.wrap(fn)
    -- run once immediately (and then GameFrame will continue it)
    local ok, err = pcall(tasksCoroutine)
    if not ok then
        Spring.Echo("Phoenix Engine: task error: "..tostring(err))
        tasksCoroutine = nil
    end
end

function widget:GameFrame(n)
    if tasksCoroutine and n % 3 == 0 then
        local ok, err = pcall(tasksCoroutine)
        if not ok or err == "cannot resume dead coroutine" then
            Spring.Echo("Phoenix Engine: task error: "..tostring(err))
            tasksCoroutine = nil
        end
    end

    -- Update nano cache periodically or when needed
    if nanoCache.needsUpdate or (n - nanoCache.lastUpdate) >= NANO_CACHE_UPDATE_INTERVAL then
        updateNanoCache()
    end

    -- Check pending builds every 30 frames
    if n % 30 == 0 then
        local totalPending = 0
        local totalProcessing = 0

        -- Process each builder's pipeline independently
        for builderID, pipeline in pairs(builderPipelines) do
            totalPending = totalPending + #pipeline.pendingBuilds
            totalProcessing = totalProcessing + #pipeline.currentlyProcessing

            -- Skip if this builder has no pending or processing builds
            if #pipeline.pendingBuilds > 0 or #pipeline.currentlyProcessing > 0 then
                -- Check if this builder still has Auto Replace enabled
                if not AUTO_REPLACE_ENABLED[builderID] then
                    cleanupBuilderPipeline(builderID)
                else
                    -- Sort pending builds by order to ensure sequential processing
                    table.sort(pipeline.pendingBuilds, function(a, b) return a.order < b.order end)
                    
                    -- Fill the pipeline up to PIPELINE_SIZE builds for this builder
                    while #pipeline.currentlyProcessing < PIPELINE_SIZE and #pipeline.pendingBuilds > 0 do
                        local nextBuild = pipeline.pendingBuilds[1]
                        table.insert(pipeline.currentlyProcessing, nextBuild)
                        table.remove(pipeline.pendingBuilds, 1)
                    end
                    
                    -- Process all builds in this builder's pipeline
                    local i = 1
                    while i <= #pipeline.currentlyProcessing do
                        local p = pipeline.currentlyProcessing[i]
                        local bx = p.params[1]
                        local bz = p.params[3]
                        
                        -- Start or retry reclaim if not started yet or if retry is needed
                        local currentFrame = Spring.GetGameFrame()
                        local shouldStartReclaim = not pipeline.reclaimStarted[p.order]
                        local shouldRetryReclaim = false
                        
                        -- Check if we should retry reclaim (if blockers still exist after delay)
                        if pipeline.reclaimStarted[p.order] and not shouldStartReclaim then
                            local lastAttempt = pipeline.lastReclaimAttempt[p.order] or 0
                            local retries = pipeline.reclaimRetries[p.order] or 0
                            
                            if (currentFrame - lastAttempt) >= RECLAIM_RETRY_DELAY and retries < MAX_RECLAIM_RETRIES then
                                -- Check if blockers still exist
                                local remainingBlockers = findBlockersAtPosition(bx, bz, p.halfX, p.halfZ, p.facing)
                                if #remainingBlockers > 0 then
                                    shouldRetryReclaim = true
                                    pipeline.reclaimRetries[p.order] = retries + 1
                                end
                            end
                        end
                        
                        if shouldStartReclaim or shouldRetryReclaim then
                            if #p.nanos > 0 then
                                if shouldRetryReclaim then
                                    -- On retry, refresh nano list and use updated blockers for better coverage
                                    local currentBlockers = findBlockersAtPosition(bx, bz, p.halfX, p.halfZ, p.facing)
                                    if #currentBlockers > 0 then
                                        -- Get fresh nano list for current blockers
                                        local retryNanos = {}
                                        local retryNanosSet = {}
                                        for _, blk in ipairs(currentBlockers) do
                                            local nanos = nanosNearUnit(blk)
                                            for _, n in ipairs(nanos) do
                                                if not retryNanosSet[n] then
                                                    retryNanosSet[n] = true
                                                    table.insert(retryNanos, n)
                                                end
                                            end
                                        end
                                        -- Use shuffle mode with current blockers and fresh nano list
                                        giveReclaimOrdersFromNanos(retryNanos, currentBlockers)
                                    end
                                else
                                    -- First attempt, use captured nano/blocker lists
                                    giveReclaimOrdersFromNanos(p.nanos, p.blockers)
                                end
                            end
                            pipeline.reclaimStarted[p.order] = true
                            pipeline.lastReclaimAttempt[p.order] = currentFrame
                        end
                        
                        -- Check if this build is under construction
                        if pipeline.buildingsUnderConstruction[p.order] then
                            -- Building is being built, check if it's complete
                            local buildCompleted = false
                            local constructionInfo = pipeline.buildingsUnderConstruction[p.order]
                            local wx, wz = constructionInfo.position[1], constructionInfo.position[2]
                            local hx, hz = constructionInfo.footprint[1], constructionInfo.footprint[2]
                            
                            -- Find units in the build area
                            local unitsInArea = GetUnitsInRectangle(wx - hx, wz - hz, wx + hx, wz + hz)
                            for _, uid in ipairs(unitsInArea) do
                                local udid = GetUnitDefID(uid)
                                if udid == constructionInfo.unitDefID and GetUnitTeam(uid) == GetMyTeamID() then
                                    local isBeingBuilt = GetUnitIsBeingBuilt(uid)
                                    if not isBeingBuilt then
                                        buildCompleted = true
                                        break
                                    else
                                    end
                                end
                            end
                            
                            if buildCompleted then
                                -- Building is complete, remove from processing and construction tracking
                                pipeline.buildingsUnderConstruction[p.order] = nil
                                pipeline.reclaimStarted[p.order] = nil
                                pipeline.reclaimRetries[p.order] = nil
                                pipeline.lastReclaimAttempt[p.order] = nil
                                table.remove(pipeline.currentlyProcessing, i)
                                -- Don't increment i since we removed an element
                            else
                                i = i + 1
                            end
                        else
                            -- Building not yet started, check if area is clear
                            local blockers = findBlockersAtPosition(bx, bz, p.halfX, p.halfZ, p.facing)
                            
                            if #blockers == 0 then
                                -- Area is clear, issue build command
                                local aliveBuilders = {}
                                for _, uid in ipairs(p.builders) do
                                    local health, _ = GetUnitHealth(uid)
                                    if health and health > 0 then
                                        table.insert(aliveBuilders, uid)
                                    end
                                end
                                local numAlive = #aliveBuilders

                                if numAlive > 0 then
                                    GiveOrderToUnitArray(aliveBuilders, p.cmdID, p.params, {"shift"})
                                    pipeline.buildingsUnderConstruction[p.order] = {
                                        position = {bx, bz},
                                        footprint = {p.halfX, p.halfZ},
                                        unitDefID = -p.cmdID
                                    }
                                else
                                    pipeline.reclaimStarted[p.order] = nil
                                    pipeline.reclaimRetries[p.order] = nil
                                    pipeline.lastReclaimAttempt[p.order] = nil
                                    table.remove(pipeline.currentlyProcessing, i)
                                    -- Don't increment i since we removed an element
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

function widget:CommandsChanged()
    local ids = GetSelectedUnits()
    local found_mode = 0
    for i = 1, #ids do
        if AUTO_REPLACE_ENABLED[ids[i]] then
            found_mode = 1
            break
        end
    end
    CMD_AUTO_REPLACE_DESCRIPTION.params[1] = found_mode
    if checkUnits(false) then
        local cmds = widgetHandler.customCommands
        cmds[#cmds + 1] = CMD_AUTO_REPLACE_DESCRIPTION
    end
end

function widget:CommandNotify(cmdID, cmdParams, cmdOptions)
    if cmdID == CMD_AUTO_REPLACE then
        local mode = CMD_AUTO_REPLACE_DESCRIPTION.params[1]
        mode = (mode + 1) % 2
        CMD_AUTO_REPLACE_DESCRIPTION.params[1] = mode
        checkUnits(true)
        return true
    end
    
    -- only react to build commands (negative numbers) if auto replace is enabled
    if (type(cmdID) ~= "number") or cmdID >= 0 then
        return false
    end
    
    -- Check if auto replace is enabled for any selected builders
    if not isAutoReplaceEnabledForSelection() then
        return false
    end

    -- extract build placement coordinates
    local bx = tonumber(cmdParams[1])
    local by = tonumber(cmdParams[2])
    local bz = tonumber(cmdParams[3])
    if not (bx and by and bz) then
        return false
    end

    -- get building def for footprint
    local udid = -cmdID
    local buildingDef = UnitDefs[udid]
    if not buildingDef then
        return false
    end
    local footX = buildingDef.footprintX or 0
    local footZ = buildingDef.footprintZ or 0
    local halfX = footX / 2
    local halfZ = footZ / 2
    local facing = cmdParams[4]

    -- find blocking target units near placement
    local blockers = findBlockersAtPosition(bx, bz, halfX, halfZ, facing)
    if #blockers == 0 then
        return false
    end


    -- Capture build details
    local capturedBuilders = GetSelectedUnits()
    if not capturedBuilders or #capturedBuilders == 0 then
        return false
    end

    -- find all nano turrets that can reach those blockers
    local allNanos = {}
    local nanosSet = {}
    for _, blk in ipairs(blockers) do
        local nanos = nanosNearUnit(blk)
        for _, n in ipairs(nanos) do
            if not nanosSet[n] then
                nanosSet[n] = true
                table.insert(allNanos, n)
            end
        end
    end


    local capturedCmdID = cmdID
    local capturedParams = {}
    for i = 1, #cmdParams do
        capturedParams[i] = cmdParams[i]
    end

    -- Increment build order counter
    buildOrderCounter = buildOrderCounter + 1
    local thisOrder = buildOrderCounter

    -- Determine which builder to assign this build to (use the first selected builder with AutoReplace enabled)
    local assignedBuilderID = nil
    for _, builderID in ipairs(capturedBuilders) do
        if AUTO_REPLACE_ENABLED[builderID] then
            assignedBuilderID = builderID
            break
        end
    end
    
    if not assignedBuilderID then
        return false
    end
    
    local pipeline = getBuilderPipeline(assignedBuilderID)

    -- Add to pending queue for this builder
    local pending = {
        builders = capturedBuilders,
        cmdID = capturedCmdID,
        params = capturedParams,
        halfX = halfX,
        halfZ = halfZ,
        facing = facing,
        order = thisOrder,
        blockers = blockers,
        nanos = allNanos,
        reclaimStarted = false
    }
    table.insert(pipeline.pendingBuilds, pending)
    return true
end

-- Clean up when units are destroyed or taken
widget.UnitDestroyed = function(_, unitID)
    AUTO_REPLACE_ENABLED[unitID] = nil
    -- Clean up the builder's pipeline when it's destroyed
    cleanupBuilderPipeline(unitID)
    -- Invalidate nano cache if a nano was destroyed
    if nanoCache.turrets[unitID] then
        nanoCache.needsUpdate = true
    end
end
widget.UnitTaken = widget.UnitDestroyed

-- Handle new units (potential nanos)
widget.UnitFinished = function(_, unitID, unitDefID)
    if NANO_DEFS[unitDefID] then
        nanoCache.needsUpdate = true
    end
end

-- Handle units given to us
widget.UnitGiven = function(_, unitID, unitDefID)
    if NANO_DEFS[unitDefID] then
        nanoCache.needsUpdate = true
    end
end

function widget:Initialize()
    widgetHandler.actionHandler:AddAction(self, "auto_replace", handleAutoReplace, nil, "p")
    -- Force initial nano cache update
    nanoCache.needsUpdate = true
end

-- cleanup (no special actions needed currently)
function widget:Shutdown()
    widgetHandler.actionHandler:RemoveAction(self, "auto_replace", "p")
    tasksCoroutine = nil
    builderPipelines = {}
    buildOrderCounter = 0
    AUTO_REPLACE_ENABLED = {}
end