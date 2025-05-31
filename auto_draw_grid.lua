function widget:GetInfo()
    return {
        name      = "Auto Draw Grid",
        desc      = "Draws grid for 12 players in NuttyB Raptor",
        author    = "timuela",
        date      = "2025",
        layer     = 1,
        enabled   = true
    }
end

-- Configuration
local lineLength = 2975              -- Length of cardinal direction lines
local startOffset = 3650             -- Offset from center for cardinal lines
local msx = Game.mapSizeX
local msz = Game.mapSizeZ
local centerX = msx / 2
local centerZ = msz / 2
local quarterX = msx / 4           
local quarterZ = msz / 4          
local threeQuarterX = msx * 3/4    
local threeQuarterZ = msz * 3/4    
local square = 192

-- Progressive draw state
local gridLines = {}
local currentLine = 1
local drawingGrid = false

local function AddLine(x1, y1, z1, x2, y2, z2)
    table.insert(gridLines, {x1, y1, z1, x2, y2, z2})
end

local function CollectGridLines()
    gridLines = {}

    -- Cardinal lines
    AddLine(centerX + startOffset, 0, centerZ, math.max(0, math.min(msx, centerX + startOffset + lineLength)), 0, centerZ)
    AddLine(centerX - startOffset, 0, centerZ, math.max(0, math.min(msx, centerX - startOffset - lineLength)), 0, centerZ)
    AddLine(centerX, 0, centerZ + startOffset, centerX, 0, math.max(0, math.min(msz, centerZ + startOffset + lineLength)))
    AddLine(centerX, 0, centerZ - startOffset, centerX, 0, math.max(0, math.min(msz, centerZ - startOffset - lineLength)))

    -- Horizontal lines
    AddLine(square*14, 0, quarterZ-576, square*16, 0, quarterZ-576)
    AddLine(square*16, 0, quarterZ-576, square*23, 0, quarterZ-576)
    AddLine(square*25, 0, quarterZ-576, square*32, 0, quarterZ-576)
    AddLine(square*32, 0, quarterZ-576, square*39, 0, quarterZ-576)
    AddLine(square*41, 0, quarterZ-576, square*48, 0, quarterZ-576)
    AddLine(square*48, 0, quarterZ-576, square*50, 0, quarterZ-576)

    AddLine(square*14, 0, threeQuarterZ+576, square*16, 0, threeQuarterZ+576)
    AddLine(square*16, 0, threeQuarterZ+576, square*23, 0, threeQuarterZ+576)
    AddLine(square*25, 0, threeQuarterZ+576, square*32, 0, threeQuarterZ+576)
    AddLine(square*32, 0, threeQuarterZ+576, square*39, 0, threeQuarterZ+576)
    AddLine(square*41, 0, threeQuarterZ+576, square*48, 0, threeQuarterZ+576)
    AddLine(square*48, 0, threeQuarterZ+576, square*50, 0, threeQuarterZ+576)

    AddLine(0, 0, quarterZ, square*13, 0, quarterZ)
    AddLine(square*51, 0, quarterZ, msx, 0, quarterZ)
    AddLine(0, 0, threeQuarterZ, square*13, 0, threeQuarterZ)
    AddLine(square*51, 0, threeQuarterZ, msx, 0, threeQuarterZ)

    -- Vertical lines
    AddLine(quarterX-575, 0, square*14, quarterX-575, 0, square*16)
    AddLine(quarterX-575, 0, square*16, quarterX-575, 0, square*23)
    AddLine(quarterX-575, 0, square*25, quarterX-575, 0, square*32)
    AddLine(quarterX-575, 0, square*32, quarterX-575, 0, square*39)
    AddLine(quarterX-575, 0, square*41, quarterX-575, 0, square*48)
    AddLine(quarterX-575, 0, square*48, quarterX-575, 0, square*50)
    AddLine(quarterX, 0, 0, quarterX, 0, square*13)
    AddLine(quarterX, 0, square*51, quarterX, 0, msz)
    AddLine(threeQuarterX, 0, 0, threeQuarterX, 0, square*13)
    AddLine(threeQuarterX, 0, square*51, threeQuarterX, 0, msz)
    AddLine(threeQuarterX+575, 0, square*14, threeQuarterX+575, 0, square*16)
    AddLine(threeQuarterX+575, 0, square*16, threeQuarterX+575, 0, square*23)
    AddLine(threeQuarterX+575, 0, square*25, threeQuarterX+575, 0, square*32)
    AddLine(threeQuarterX+575, 0, square*32, threeQuarterX+575, 0, square*39)
    AddLine(threeQuarterX+575, 0, square*41, threeQuarterX+575, 0, square*48)
    AddLine(threeQuarterX+575, 0, square*48, threeQuarterX+575, 0, square*50)
end

function widget:Initialize()
    local mapNameLower = string.lower(Game.mapName or "")
    if string.find(mapNameLower, "full metal plate") then
        Spring.Echo("Running on Full Metal Plate")
        Spring.MarkerErasePosition(0, 0, 0)
        CollectGridLines()
        currentLine = 1
        drawingGrid = true
    else
        Spring.Echo("Not Full Metal Plate, disabling.")
        widgetHandler:RemoveWidget(self)
    end
end

local lastDrawTime = 0
local drawInterval = 0.16 -- seconds between lines (e.g. 0.16s ≈ 10 frames at 60fps)

function widget:DrawScreen()
    if drawingGrid and currentLine <= #gridLines then
        local now = Spring.GetTimer()
        if lastDrawTime == 0 then
            lastDrawTime = now
        end
        local elapsed = Spring.DiffTimers(now, lastDrawTime)
        if elapsed >= drawInterval then
            lastDrawTime = now
            local l = gridLines[currentLine]
            Spring.MarkerAddLine(l[1], l[2], l[3], l[4], l[5], l[6])
            currentLine = currentLine + 1
            if currentLine > #gridLines then
                drawingGrid = false
            end
        end
    end
end