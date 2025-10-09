function widget:GetInfo()
	return {
		name = "Phoenix Engine",
		desc = "Automatically reclaims blocking units when placing buildings over them.",
		author = "timuela",
		date = "2025-10-02",
		layer = 0,
		enabled = true,
		handler = true,
	}
end

local GetSelectedUnits = Spring.GetSelectedUnits
local GetUnitDefID = Spring.GetUnitDefID
local GetUnitPosition = Spring.GetUnitPosition
local GetUnitsInCylinder = Spring.GetUnitsInCylinder
local GiveOrderToUnitArray = Spring.GiveOrderToUnitArray
local GetUnitTeam = Spring.GetUnitTeam
local GetMyTeamID = Spring.GetMyTeamID
local GetUnitSeparation = Spring.GetUnitSeparation
local GetUnitHealth = Spring.GetUnitHealth
local GetUnitsInRectangle = Spring.GetUnitsInRectangle
local GetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local UnitDefs = UnitDefs
local CMD_RECLAIM = CMD.RECLAIM
local CMD_INSERT = CMD.INSERT
local CMD_OPT_SHIFT = CMD.OPT_SHIFT

-- Command definitions
local CMD_AUTO_REPLACE = 28341
local CMD_AUTO_REPLACE_DESCRIPTION = {
	id = CMD_AUTO_REPLACE,
	type = (CMDTYPE or { ICON_MODE = 5 }).ICON_MODE,
	name = "Auto Replace",
	cursor = nil,
	action = "auto_replace",
	params = { 1, "auto_replace_off", "auto_replace_on" },
}

Spring.I18N.set("en.ui.orderMenu.auto_replace_off", "Auto Replace Off")
Spring.I18N.set("en.ui.orderMenu.auto_replace_on", "Auto Replace On")
Spring.I18N.set("en.ui.orderMenu.auto_replace_tooltip", "Automatically reclaim blocking units when placing buildings")

-- Target definitions
local factions = { "arm", "cor", "leg" }

local reclaimableTargets = {
	"nanotc",
	"nanotcplat",
	"nanotct2",
	"nanotc2plat",
	"nanotct3",
	"wint2",
	"afus",
}
local buildableTypes = {
	"afust3",
	"mmkrt3",
	"adveconvt3",
	"flak",
}

local TARGET_UNITDEF_NAMES = {}
local BUILDABLE_UNITDEF_NAMES = {}

for _, faction in ipairs(factions) do
	for _, reclaimableTarget in ipairs(reclaimableTargets) do
		table.insert(TARGET_UNITDEF_NAMES, faction .. reclaimableTarget)
	end
end
for _, faction in ipairs({ "arm", "cor", "leg" }) do
	for _, buildableType in ipairs(buildableTypes) do
		table.insert(BUILDABLE_UNITDEF_NAMES, faction .. buildableType)
	end
end

local TARGET_UNITDEF_IDS, builderDefs, NANO_DEFS, BUILDABLE_UNITDEF_IDS = {}, {}, {}, {}
for _, name in ipairs(TARGET_UNITDEF_NAMES) do
	local def = UnitDefNames and UnitDefNames[name]
	if def then
		TARGET_UNITDEF_IDS[def.id] = true
	end
end

for _, name in ipairs(BUILDABLE_UNITDEF_NAMES) do
	local def = UnitDefNames and UnitDefNames[name]
	if def then
		BUILDABLE_UNITDEF_IDS[def.id] = true
	end
end

for uDefID, uDef in pairs(UnitDefs) do
	if uDef.isBuilder then
		builderDefs[uDefID] = true
	end
	if uDef.isBuilder and not uDef.canMove and not uDef.isFactory then
		NANO_DEFS[uDefID] = uDef.buildDistance or 0
	end
end

-- Configuration
local RESTRICT_BUILDABLE = true
local DEFAULT_PIPELINE_SIZE = 3
local MEDIUM_PIPELINE_SIZE = 6
local SMALL_PIPELINE_SIZE = 20
local NANO_CACHE_UPDATE_INTERVAL = 90
local RECLAIM_RETRY_DELAY = 150
local MAX_RECLAIM_RETRIES = 200

-- States
local AUTO_REPLACE_ENABLED, builderPipelines, buildOrderCounter = {}, {}, 0
local nanoCache = { turrets = {}, lastUpdate = 0, needsUpdate = true }
local visualIndicators = {}
local ALT = { "alt" }
local CMD_CACHE = { 0, CMD_RECLAIM, CMD_OPT_SHIFT, 0 }

local function getPipelineSize(unitDefID)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then
		return DEFAULT_PIPELINE_SIZE
	end

	local footprintArea = (unitDef.xsize or 4) * (unitDef.zsize or 4)

	-- EFUS-sized buildings (16x16 = 256) get pipeline size 3
	-- Smaller buildings get larger pipelines
	if footprintArea >= 256 then
		return DEFAULT_PIPELINE_SIZE
	elseif footprintArea >= 64 then -- 8x8 buildings
		return MEDIUM_PIPELINE_SIZE
	else -- Smaller buildings
		return SMALL_PIPELINE_SIZE
	end
end

local function getBuilderPipeline(builderID)
	if not builderPipelines[builderID] then
		builderPipelines[builderID] = {
			pendingBuilds = {},
			currentlyProcessing = {},
			buildingsUnderConstruction = {},
			reclaimStarted = {},
			reclaimRetries = {},
			lastReclaimAttempt = {},
		}
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
			if x then
				nanoCache.turrets[uid] = { x = x, z = z, buildDist = buildDist }
			end
		end
	end
	nanoCache.lastUpdate, nanoCache.needsUpdate = Spring.GetGameFrame(), false
end

local function nanosNearUnit(targetUnitID)
	local tx, _, tz = GetUnitPosition(targetUnitID)
	if not tx then
		return {}
	end
	local unitIDs = {}
	for uid, turret in pairs(nanoCache.turrets) do
		if uid ~= targetUnitID then
			local dx, dz = tx - turret.x, tz - turret.z
			local distance = math.sqrt(dx * dx + dz * dz)
			if turret.buildDist > distance then
				unitIDs[#unitIDs + 1] = uid
			end
		end
	end
	return unitIDs
end

-- Visual indicator functions
local function addVisualIndicator(builderID, x, z, areaX, areaZ)
	visualIndicators[builderID] = visualIndicators[builderID] or {}
	table.insert(visualIndicators[builderID], { x, z, areaX, areaZ })
end

local function removeVisualIndicator(builderID, x, z)
	local indicators = visualIndicators[builderID]
	if not indicators then
		return
	end
	for i = #indicators, 1, -1 do
		local ind = indicators[i]
		if math.abs(ind[1] - x) < 1 and math.abs(ind[2] - z) < 1 then
			table.remove(indicators, i)
		end
	end
	if #indicators == 0 then
		visualIndicators[builderID] = nil
	end
end

local function clearAllVisualIndicators(builderID)
	visualIndicators[builderID] = nil
end

local function findBlockersAtPosition(x, z, xsize, zsize, facing)
	local blockers = {}
	local areaX, areaZ =
		(facing == 1 or facing == 3) and zsize * 4 or xsize * 4, (facing == 1 or facing == 3) and xsize * 4 or zsize * 4

	for _, uid in ipairs(GetUnitsInRectangle(x - areaX, z - areaZ, x + areaX, z + areaZ)) do
		if TARGET_UNITDEF_IDS[GetUnitDefID(uid)] and GetUnitTeam(uid) == GetMyTeamID() then
			local ux, _, uz = GetUnitPosition(uid)
			if ux and math.abs(ux - x) <= areaX and math.abs(uz - z) <= areaZ then
				blockers[#blockers + 1] = uid
			end
		end
	end
	return blockers, areaX, areaZ
end

local function giveReclaimOrdersFromNanos(targetUnitIDs)
	for _, targetUnitID in ipairs(targetUnitIDs) do
		local unitIDs = nanosNearUnit(targetUnitID)
		CMD_CACHE[4] = targetUnitID
		GiveOrderToUnitArray(unitIDs, CMD_INSERT, CMD_CACHE, ALT)
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
				local wasEnabled = AUTO_REPLACE_ENABLED[id]
				AUTO_REPLACE_ENABLED[id] = (mode ~= 0) and true or nil

				-- Clear visual indicators when toggling off
				if wasEnabled and not AUTO_REPLACE_ENABLED[id] then
					clearAllVisualIndicators(id)
				end
			end
		end
	end
	return found
end

local function isAutoReplaceEnabledForSelection()
	for _, id in ipairs(GetSelectedUnits()) do
		if builderDefs[GetUnitDefID(id)] and AUTO_REPLACE_ENABLED[id] then
			return true
		end
	end
	return false
end

-- Helper functions for pipeline processing
local function shouldRetryReclaim(pipeline, order, currentFrame)
	local lastAttempt = pipeline.lastReclaimAttempt[order] or 0
	local retries = pipeline.reclaimRetries[order] or 0
	return (currentFrame - lastAttempt) >= RECLAIM_RETRY_DELAY and retries < MAX_RECLAIM_RETRIES
end

local function isBuildComplete(constructionInfo)
	local wx, wz = constructionInfo.position[1], constructionInfo.position[2]
	local hx, hz = constructionInfo.footprint[1], constructionInfo.footprint[2]
	for _, uid in ipairs(GetUnitsInRectangle(wx - hx, wz - hz, wx + hx, wz + hz)) do
		if
			GetUnitDefID(uid) == constructionInfo.unitDefID
			and GetUnitTeam(uid) == GetMyTeamID()
			and not GetUnitIsBeingBuilt(uid)
		then
			return true
		end
	end
	return false
end

local function getAliveBuilders(builders)
	local alive = {}
	for _, uid in ipairs(builders) do
		local health = GetUnitHealth(uid)
		if health and health > 0 then
			alive[#alive + 1] = uid
		end
	end
	return alive
end

local function clearPipelineOrder(pipeline, order)
	pipeline.reclaimStarted[order] = nil
	pipeline.reclaimRetries[order] = nil
	pipeline.lastReclaimAttempt[order] = nil
end

-- Main game frame processing
function widget:GameFrame(n)
	if nanoCache.needsUpdate or (n - nanoCache.lastUpdate) >= NANO_CACHE_UPDATE_INTERVAL then
		updateNanoCache()
	end
	if n % 30 ~= 0 then
		return
	end

	local currentFrame = Spring.GetGameFrame()
	for builderID, pipeline in pairs(builderPipelines) do
		if not AUTO_REPLACE_ENABLED[builderID] or (#pipeline.pendingBuilds + #pipeline.currentlyProcessing == 0) then
			builderPipelines[builderID] = nil
		else
			table.sort(pipeline.pendingBuilds, function(a, b)
				return a.order < b.order
			end)

			-- Get pipeline size for the first pending build
			local currentPipelineSize = DEFAULT_PIPELINE_SIZE
			if #pipeline.pendingBuilds > 0 then
				currentPipelineSize = getPipelineSize(-pipeline.pendingBuilds[1].cmdID)
			elseif #pipeline.currentlyProcessing > 0 then
				currentPipelineSize = getPipelineSize(-pipeline.currentlyProcessing[1].cmdID)
			end

			while #pipeline.currentlyProcessing < currentPipelineSize and #pipeline.pendingBuilds > 0 do
				pipeline.currentlyProcessing[#pipeline.currentlyProcessing + 1] =
					table.remove(pipeline.pendingBuilds, 1)
			end
			local i = 1
			while i <= #pipeline.currentlyProcessing do
				local p = pipeline.currentlyProcessing[i]
				local bx, bz = p.params[1], p.params[3]
				local shouldStart = not pipeline.reclaimStarted[p.order]
				local shouldRetry = pipeline.reclaimStarted[p.order]
					and shouldRetryReclaim(pipeline, p.order, currentFrame)

				-- Handle reclaim retry logic
				if shouldRetry then
					local blockers = findBlockersAtPosition(bx, bz, p.xsize, p.zsize, p.facing)
					if #blockers > 0 then
						pipeline.reclaimRetries[p.order] = (pipeline.reclaimRetries[p.order] or 0) + 1
						giveReclaimOrdersFromNanos(blockers)
						pipeline.lastReclaimAttempt[p.order] = currentFrame
					end
				elseif shouldStart then
					giveReclaimOrdersFromNanos(p.blockers)
					pipeline.reclaimStarted[p.order] = true
					pipeline.lastReclaimAttempt[p.order] = currentFrame
				end

				-- Check if building is under construction
				local constructionInfo = pipeline.buildingsUnderConstruction[p.order]
				if constructionInfo then
					if isBuildComplete(constructionInfo) then
						pipeline.buildingsUnderConstruction[p.order] = nil
						clearPipelineOrder(pipeline, p.order)
						removeVisualIndicator(builderID, bx, bz)
						table.remove(pipeline.currentlyProcessing, i)
					else
						i = i + 1
					end
				else
					-- Check if ready to build
					local blockers = findBlockersAtPosition(bx, bz, p.xsize, p.zsize, p.facing)
					if #blockers == 0 then
						local aliveBuilders = getAliveBuilders(p.builders)
						if #aliveBuilders > 0 then
							GiveOrderToUnitArray(aliveBuilders, p.cmdID, p.params, { "shift" })
							pipeline.buildingsUnderConstruction[p.order] = {
								position = { bx, bz },
								footprint = { p.xsize / 2, p.zsize / 2 },
								unitDefID = -p.cmdID,
							}
						else
							clearPipelineOrder(pipeline, p.order)
							removeVisualIndicator(builderID, bx, bz)
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

-- Command handling
function widget:CommandsChanged()
	local found_mode = 0
	for _, id in ipairs(GetSelectedUnits()) do
		if AUTO_REPLACE_ENABLED[id] then
			found_mode = 1
			break
		end
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
	if type(cmdID) ~= "number" or cmdID >= 0 or not isAutoReplaceEnabledForSelection() then
		return false
	end

	local buildingDefID = -cmdID
	if RESTRICT_BUILDABLE and not BUILDABLE_UNITDEF_IDS[buildingDefID] then
		return false
	end
	local bx, by, bz = tonumber(cmdParams[1]), tonumber(cmdParams[2]), tonumber(cmdParams[3])
	if not (bx and by and bz) then
		return false
	end

	local buildingDef = UnitDefs[buildingDefID]
	if not buildingDef or not buildingDef.xsize or not buildingDef.zsize then
		return false
	end
	local xsize, zsize = buildingDef.xsize, buildingDef.zsize
	local facing = cmdParams[4] or 0
	local blockers, buildingAreaX, buildingAreaZ = findBlockersAtPosition(bx, bz, xsize, zsize, facing)
	if #blockers == 0 then
		return false
	end
	local assignedBuilderID = nil
	for _, builderID in ipairs(GetSelectedUnits()) do
		if AUTO_REPLACE_ENABLED[builderID] then
			assignedBuilderID = builderID
			break
		end
	end
	if not assignedBuilderID then
		return false
	end
	buildOrderCounter = buildOrderCounter + 1
	local pipeline = getBuilderPipeline(assignedBuilderID)
	pipeline.pendingBuilds[#pipeline.pendingBuilds + 1] = {
		builders = GetSelectedUnits(),
		cmdID = cmdID,
		params = cmdParams,
		xsize = xsize,
		zsize = zsize,
		facing = facing,
		order = buildOrderCounter,
		blockers = blockers,
	}
	addVisualIndicator(assignedBuilderID, bx, bz, buildingAreaX, buildingAreaZ)
	return true
end

-- Event handlers
widget.UnitDestroyed = function(_, unitID)
	AUTO_REPLACE_ENABLED[unitID] = nil
	if builderPipelines[unitID] then
		clearAllVisualIndicators(unitID)
		builderPipelines[unitID] = nil
	end
	if nanoCache.turrets[unitID] then
		nanoCache.needsUpdate = true
	end
end
widget.UnitTaken = widget.UnitDestroyed

widget.UnitFinished = function(_, unitID, unitDefID)
	if NANO_DEFS[unitDefID] then
		nanoCache.needsUpdate = true
	end
end

widget.UnitGiven = function(_, unitID, unitDefID)
	if NANO_DEFS[unitDefID] then
		nanoCache.needsUpdate = true
	end
end

function widget:Initialize()
	widgetHandler.actionHandler:AddAction(self, "auto_replace", function()
		checkUnits(true)
	end, nil, "p")
	nanoCache.needsUpdate = true
end

function widget:Shutdown()
	widgetHandler.actionHandler:RemoveAction(self, "auto_replace", "p")
	builderPipelines, buildOrderCounter, AUTO_REPLACE_ENABLED = {}, 0, {}
	visualIndicators = {}
end

-- Visual rendering
function widget:DrawWorld()
	if not next(visualIndicators) then
		return
	end

	local gl = gl
	gl.PushAttrib(GL.ALL_ATTRIB_BITS)
	gl.Color(1, 0.5, 0, 0.8) -- Orange
	gl.DepthTest(true)
	gl.LineWidth(2)

	local HEIGHT_OFFSET = 15
	local CORNER_SIZE = 8

	for builderID, indicators in pairs(visualIndicators) do
		for _, ind in ipairs(indicators) do
			local x, z, areaX, areaZ = ind[1], ind[2], ind[3], ind[4]
			local x1, z1, x2, z2 = x - areaX, z - areaZ, x + areaX, z + areaZ
			local y = Spring.GetGroundHeight(x, z) + HEIGHT_OFFSET
			gl.BeginEnd(GL.LINE_LOOP, function()
				gl.Vertex(x1, y, z1)
				gl.Vertex(x2, y, z1)
				gl.Vertex(x2, y, z2)
				gl.Vertex(x1, y, z2)
			end)
			gl.BeginEnd(GL.LINES, function()
				gl.Vertex(x1, y, z1)
				gl.Vertex(x1 + CORNER_SIZE, y, z1)
				gl.Vertex(x1, y, z1)
				gl.Vertex(x1, y, z1 + CORNER_SIZE)
				gl.Vertex(x2, y, z1)
				gl.Vertex(x2 - CORNER_SIZE, y, z1)
				gl.Vertex(x2, y, z1)
				gl.Vertex(x2, y, z1 + CORNER_SIZE)
				gl.Vertex(x2, y, z2)
				gl.Vertex(x2 - CORNER_SIZE, y, z2)
				gl.Vertex(x2, y, z2)
				gl.Vertex(x2, y, z2 - CORNER_SIZE)
				gl.Vertex(x1, y, z2)
				gl.Vertex(x1 + CORNER_SIZE, y, z2)
				gl.Vertex(x1, y, z2)
				gl.Vertex(x1, y, z2 - CORNER_SIZE)
			end)
		end
	end

	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
	gl.PopAttrib()
end
