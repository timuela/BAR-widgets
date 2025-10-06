function widget:GetInfo()
	return {
		name = "Phoenix Engine",
		desc = "Automatically reclaims blocking units when placing buildings over them",
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
local TARGET_UNITDEF_NAMES = {
	"armnanotc",
	"armnanotcplat",
	"armnanotct2",
	"armnanotc2plat",
	"armnanotct3",
	"cornanotc",
	"cornanotcplat",
	"cornanotct2",
	"cornanotc2plat",
	"cornanotct3",
	"legnanotc",
	"legnanotcplat",
	"legnanotct2",
	"legnanotct2plat",
	"legnanotct3",
}

local BUILDABLE_UNITDEF_NAMES = {
	"armafust3",
	"corafust3",
	"legafust3",
}

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
local PIPELINE_SIZE = 3
local NANO_CACHE_UPDATE_INTERVAL = 90
local RECLAIM_RETRY_DELAY = 10
local MAX_RECLAIM_RETRIES = 200

-- States
local AUTO_REPLACE_ENABLED, builderPipelines, buildOrderCounter = {}, {}, 0
local nanoCache = { turrets = {}, lastUpdate = 0, needsUpdate = true }
local visualIndicators = {}
local ALT = { "alt" }
local CMD_CACHE = { 0, CMD_RECLAIM, CMD_OPT_SHIFT, 0 }

-- Helper functions
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
				nanoCache.turrets[uid] = { x = x, z = z, buildDist = buildDist, team = myTeam }
			end
		end
	end
	nanoCache.lastUpdate, nanoCache.needsUpdate = Spring.GetGameFrame(), false
end

local function nanosNearUnit(targetUnitID)
	local pos = { GetUnitPosition(targetUnitID) }
	if not pos[1] then
		return {}
	end

	local unitsNear = GetUnitsInCylinder(pos[1], pos[3], 1000, -2)
	local unitIDs = {}
	for _, id in ipairs(unitsNear) do
		local dist = NANO_DEFS[GetUnitDefID(id)]
		if dist ~= nil and targetUnitID ~= id then
			if dist > GetUnitSeparation(targetUnitID, id, true) then
				unitIDs[#unitIDs + 1] = id
			end
		end
	end
	return unitIDs
end

-- Visual indicator functions
local function addVisualIndicator(builderID, x, z, buildingAreaX, buildingAreaZ)
	if not visualIndicators[builderID] then
		visualIndicators[builderID] = {}
	end

	local indicator = {
		x = x,
		z = z,
		areaX = buildingAreaX,
		areaZ = buildingAreaZ,
		startTime = Spring.GetGameFrame(),
	}

	table.insert(visualIndicators[builderID], indicator)
end

local function removeVisualIndicator(builderID, x, z)
	if not visualIndicators[builderID] then
		return
	end

	for i = #visualIndicators[builderID], 1, -1 do
		local indicator = visualIndicators[builderID][i]
		if math.abs(indicator.x - x) < 1 and math.abs(indicator.z - z) < 1 then
			table.remove(visualIndicators[builderID], i)
		end
	end

	-- Clean up empty tables
	if #visualIndicators[builderID] == 0 then
		visualIndicators[builderID] = nil
	end
end

local function clearAllVisualIndicators(builderID)
	visualIndicators[builderID] = nil
end

local function findBlockersAtPosition(x, z, xsize, zsize, facing)
	local blockers = {}
	local areaX, areaZ = xsize * 4 + 8, zsize * 4 + 8

	for _, uid in ipairs(GetUnitsInRectangle(x - areaX, z - areaZ, x + areaX, z + areaZ)) do
		if TARGET_UNITDEF_IDS[GetUnitDefID(uid)] and GetUnitTeam(uid) == GetMyTeamID() then
			local ux, _, uz = GetUnitPosition(uid)
			if ux and math.abs(ux - x) <= areaX and math.abs(uz - z) <= areaZ then
				table.insert(blockers, uid)
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

-- Main game frame processing
function widget:GameFrame(n)
	if nanoCache.needsUpdate or (n - nanoCache.lastUpdate) >= NANO_CACHE_UPDATE_INTERVAL then
		updateNanoCache()
	end
	if n % 30 == 0 then
		for builderID, pipeline in pairs(builderPipelines) do
			if #pipeline.pendingBuilds > 0 or #pipeline.currentlyProcessing > 0 then
				if not AUTO_REPLACE_ENABLED[builderID] then
					builderPipelines[builderID] = nil
				else
					table.sort(pipeline.pendingBuilds, function(a, b)
						return a.order < b.order
					end)
					while #pipeline.currentlyProcessing < PIPELINE_SIZE and #pipeline.pendingBuilds > 0 do
						table.insert(pipeline.currentlyProcessing, table.remove(pipeline.pendingBuilds, 1))
					end
					local i = 1
					while i <= #pipeline.currentlyProcessing do
						local p = pipeline.currentlyProcessing[i]
						local bx, bz = p.params[1], p.params[3]
						local currentFrame = Spring.GetGameFrame()
						local shouldStartReclaim = not pipeline.reclaimStarted[p.order]
						local shouldRetryReclaim = false
						-- Check retry conditions
						if pipeline.reclaimStarted[p.order] then
							local lastAttempt, retries =
								pipeline.lastReclaimAttempt[p.order] or 0, pipeline.reclaimRetries[p.order] or 0
							if
								(currentFrame - lastAttempt) >= RECLAIM_RETRY_DELAY
								and retries < MAX_RECLAIM_RETRIES
							then
								local remainingBlockers = findBlockersAtPosition(bx, bz, p.xsize, p.zsize, p.facing)
								if #remainingBlockers > 0 then
									shouldRetryReclaim = true
									pipeline.reclaimRetries[p.order] = retries + 1
								end
							end
						end
						-- Execute reclaim
						if shouldStartReclaim or shouldRetryReclaim then
							if shouldRetryReclaim then
								local currentBlockers = findBlockersAtPosition(bx, bz, p.xsize, p.zsize, p.facing)
								if #currentBlockers > 0 then
									giveReclaimOrdersFromNanos(currentBlockers)
								end
							else
								giveReclaimOrdersFromNanos(p.blockers)
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
								if
									GetUnitDefID(uid) == constructionInfo.unitDefID
									and GetUnitTeam(uid) == GetMyTeamID()
									and not GetUnitIsBeingBuilt(uid)
								then
									buildCompleted = true
									break
								end
							end
							if buildCompleted then
								pipeline.buildingsUnderConstruction[p.order] = nil
								pipeline.reclaimStarted[p.order] = nil
								pipeline.reclaimRetries[p.order] = nil
								pipeline.lastReclaimAttempt[p.order] = nil
								removeVisualIndicator(builderID, bx, bz)
								table.remove(pipeline.currentlyProcessing, i)
							else
								i = i + 1
							end
						else
							local blockers = findBlockersAtPosition(bx, bz, p.xsize, p.zsize, p.facing)
							if #blockers == 0 then
								local aliveBuilders = {}
								for _, uid in ipairs(p.builders) do
									local health = GetUnitHealth(uid)
									if health and health > 0 then
										table.insert(aliveBuilders, uid)
									end
								end
								if #aliveBuilders > 0 then
									GiveOrderToUnitArray(aliveBuilders, p.cmdID, p.params, { "shift" })
									pipeline.buildingsUnderConstruction[p.order] = {
										position = { bx, bz },
										footprint = { p.xsize / 2, p.zsize / 2 },
										unitDefID = -p.cmdID,
									}
								else
									pipeline.reclaimStarted[p.order] = nil
									pipeline.reclaimRetries[p.order] = nil
									pipeline.lastReclaimAttempt[p.order] = nil
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
	if not BUILDABLE_UNITDEF_IDS[buildingDefID] then
		return false
	end

	local bx, by, bz = tonumber(cmdParams[1]), tonumber(cmdParams[2]), tonumber(cmdParams[3])
	if not (bx and by and bz) then
		return false
	end

	local buildingDef = UnitDefs[buildingDefID]
	if not buildingDef then
		Spring.Echo("  ERROR: buildingDef is nil!")
		return false
	end

	-- Get building size directly
	local xsize, zsize = 0, 0
	if buildingDef.xsize and buildingDef.zsize then
		xsize, zsize = buildingDef.xsize, buildingDef.zsize
		Spring.Echo(" (xsize/zsize): " .. buildingDef.xsize .. "x" .. buildingDef.zsize)
	end

	local blockers, buildingAreaX, buildingAreaZ = findBlockersAtPosition(bx, bz, xsize, zsize, cmdParams[4])
	if #blockers == 0 then
		return false
	end

	local capturedBuilders = GetSelectedUnits()
	if not capturedBuilders or #capturedBuilders == 0 then
		return false
	end

	buildOrderCounter = buildOrderCounter + 1
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
	table.insert(pipeline.pendingBuilds, {
		builders = capturedBuilders,
		cmdID = cmdID,
		params = cmdParams,
		xsize = xsize,
		zsize = zsize,
		facing = cmdParams[4],
		order = buildOrderCounter,
		blockers = blockers,
	})
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

	local HEIGHT_OFFSET = 5

	for builderID, indicators in pairs(visualIndicators) do
		for _, indicator in ipairs(indicators) do
			local x, z = indicator.x, indicator.z
			local areaX, areaZ = indicator.areaX, indicator.areaZ

			-- Calculate rectangle corners
			local x1 = x - areaX
			local z1 = z - areaZ
			local x2 = x + areaX
			local z2 = z + areaZ

			local y1 = Spring.GetGroundHeight(x1, z1) + HEIGHT_OFFSET
			local y2 = Spring.GetGroundHeight(x2, z1) + HEIGHT_OFFSET
			local y3 = Spring.GetGroundHeight(x2, z2) + HEIGHT_OFFSET
			local y4 = Spring.GetGroundHeight(x1, z2) + HEIGHT_OFFSET

			gl.BeginEnd(GL.LINE_LOOP, function()
				gl.Vertex(x1, y1, z1)
				gl.Vertex(x2, y2, z1)
				gl.Vertex(x2, y3, z2)
				gl.Vertex(x1, y4, z2)
			end)

			local cornerSize = 8
			gl.BeginEnd(GL.LINES, function()
				-- Bottom-left corner
				gl.Vertex(x1, y1, z1)
				gl.Vertex(x1 + cornerSize, y1, z1)
				gl.Vertex(x1, y1, z1)
				gl.Vertex(x1, y1, z1 + cornerSize)

				-- Bottom-right corner
				gl.Vertex(x2, y2, z1)
				gl.Vertex(x2 - cornerSize, y2, z1)
				gl.Vertex(x2, y2, z1)
				gl.Vertex(x2, y2, z1 + cornerSize)

				-- Top-right corner
				gl.Vertex(x2, y3, z2)
				gl.Vertex(x2 - cornerSize, y3, z2)
				gl.Vertex(x2, y3, z2)
				gl.Vertex(x2, y3, z2 - cornerSize)

				-- Top-left corner
				gl.Vertex(x1, y4, z2)
				gl.Vertex(x1 + cornerSize, y4, z2)
				gl.Vertex(x1, y4, z2)
				gl.Vertex(x1, y4, z2 - cornerSize)
			end)
		end
	end

	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
	gl.DepthTest(true)
	gl.PopAttrib()
end
