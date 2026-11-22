-- VehicleAudioUI.client.lua
-- Studio test-bench UI for VehicleAudioTest.client.lua.
-- Put this LocalScript beside VehicleAudioTest.client.lua in StarterPlayerScripts.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerScripts = player:WaitForChild("PlayerScripts")
local bridge = playerScripts:WaitForChild("VehicleAudioLabBridge", 30)
if not bridge then
	warn("[VehicleAudioUI] VehicleAudioLabBridge was not found. Make sure VehicleAudioTest.client.lua is running.")
	return
end

local commandEvent = bridge:WaitForChild("Command")
local snapshotEvent = bridge:WaitForChild("Snapshot")
local getSnapshot = bridge:WaitForChild("GetSnapshot")

local latestSnapshot = nil

local oldGui = player:WaitForChild("PlayerGui"):FindFirstChild("VehicleAudioLabGui")
if oldGui then
	oldGui:Destroy()
end

local COLORS = {
	panel = Color3.fromRGB(11, 17, 27),
	panel2 = Color3.fromRGB(17, 26, 39),
	panel3 = Color3.fromRGB(24, 36, 51),
	stroke = Color3.fromRGB(43, 75, 91),
	accent = Color3.fromRGB(55, 219, 197),
	accentDim = Color3.fromRGB(31, 112, 111),
	text = Color3.fromRGB(233, 242, 246),
	muted = Color3.fromRGB(137, 158, 174),	
	green = Color3.fromRGB(69, 213, 157),
	yellow = Color3.fromRGB(246, 194, 82),
	orange = Color3.fromRGB(244, 130, 76),
	red = Color3.fromRGB(245, 79, 86),
	inactive = Color3.fromRGB(32, 46, 61),
}

local function corner(parent, radius)
	local item = Instance.new("UICorner")
	item.CornerRadius = UDim.new(0, radius or 10)
	item.Parent = parent
	return item
end

local function stroke(parent, color, thickness, transparency)
	local item = Instance.new("UIStroke")
	item.Color = color or COLORS.stroke
	item.Thickness = thickness or 1
	item.Transparency = transparency or 0
	item.Parent = parent
	return item
end

local function makeLabel(parent, text, size, position, font, color)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text or ""
	label.TextSize = size or 14
	label.Font = font or Enum.Font.Gotham
	label.TextColor3 = color or COLORS.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Position = position or UDim2.fromOffset(0, 0)
	label.Parent = parent
	return label
end

local function makeButton(parent, text, size, position)
	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.Text = text or ""
	button.TextSize = 12
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = COLORS.text
	button.BackgroundColor3 = COLORS.panel3
	button.Size = size
	button.Position = position
	button.Parent = parent
	corner(button, 8)
	stroke(button, COLORS.stroke, 1, 0.1)
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(34, 53, 70) }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = COLORS.panel3 }):Play()
	end)
	return button
end

local gui = Instance.new("ScreenGui")
gui.Name = "VehicleAudioLabGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 30
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

-- Main HUD panel.
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -18)
panel.Size = UDim2.new(0.94, 0, 0, 244)
panel.BackgroundColor3 = COLORS.panel
panel.Parent = gui
corner(panel, 15)
stroke(panel, COLORS.stroke, 1.2, 0)
local panelConstraint = Instance.new("UISizeConstraint")
panelConstraint.MinSize = Vector2.new(520, 244)
panelConstraint.MaxSize = Vector2.new(640, 244)
panelConstraint.Parent = panel

local panelGradient = Instance.new("UIGradient")
panelGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(14, 23, 35)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 13, 22)),
})
panelGradient.Rotation = 90
panelGradient.Parent = panel

local topAccent = Instance.new("Frame")
topAccent.BorderSizePixel = 0
topAccent.BackgroundColor3 = COLORS.accent
topAccent.Size = UDim2.new(1, -34, 0, 2)
topAccent.Position = UDim2.fromOffset(17, 0)
topAccent.Parent = panel
corner(topAccent, 2)

local title = makeLabel(panel, "VEHICLE AUDIO LAB", 12, UDim2.fromOffset(18, 12), Enum.Font.GothamBold, COLORS.accent)
title.Size = UDim2.fromOffset(190, 18)
local subtitle = makeLabel(panel, "PROCEDURAL ENGINE TEST BENCH", 9, UDim2.fromOffset(18, 29), Enum.Font.GothamMedium, COLORS.muted)
subtitle.Size = UDim2.fromOffset(220, 14)

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.fromOffset(7, 7)
statusDot.Position = UDim2.new(1, -92, 0, 18)
statusDot.BackgroundColor3 = COLORS.green
statusDot.Parent = panel
corner(statusDot, 8)
local statusText = makeLabel(panel, "LOCAL STUDIO", 9, UDim2.new(1, -79, 0, 12), Enum.Font.GothamBold, COLORS.muted)
statusText.Size = UDim2.fromOffset(68, 18)

-- Engine selection row.
local previousButton = makeButton(panel, "‹", UDim2.fromOffset(32, 30), UDim2.fromOffset(18, 52))
previousButton.TextSize = 22
local engineButton = makeButton(panel, "SELECT ENGINE  ▾", UDim2.new(1, -140, 0, 30), UDim2.fromOffset(58, 52))
engineButton.TextSize = 11
engineButton.TextTruncate = Enum.TextTruncate.AtEnd
local nextButton = makeButton(panel, "›", UDim2.fromOffset(32, 30), UDim2.new(1, -50, 0, 52))
nextButton.TextSize = 22

-- RPM readout and redline.
local rpmCaption = makeLabel(panel, "ENGINE SPEED", 9, UDim2.fromOffset(19, 91), Enum.Font.GothamBold, COLORS.muted)
rpmCaption.Size = UDim2.fromOffset(140, 14)
local rpmValue = makeLabel(panel, "0000", 27, UDim2.fromOffset(18, 103), Enum.Font.GothamBlack, COLORS.text)
rpmValue.Size = UDim2.fromOffset(126, 34)
rpmValue.TextYAlignment = Enum.TextYAlignment.Center
local rpmUnit = makeLabel(panel, "RPM", 9, UDim2.fromOffset(111, 119), Enum.Font.GothamBold, COLORS.muted)
rpmUnit.Size = UDim2.fromOffset(40, 14)
local redlineLabel = makeLabel(panel, "REDLINE  6800", 9, UDim2.new(1, -140, 0, 93), Enum.Font.GothamBold, COLORS.muted)
redlineLabel.Size = UDim2.fromOffset(122, 14)
redlineLabel.TextXAlignment = Enum.TextXAlignment.Right

local barBack = Instance.new("Frame")
barBack.Name = "RPMBar"
barBack.BackgroundColor3 = COLORS.panel2
barBack.Position = UDim2.fromOffset(158, 105)
barBack.Size = UDim2.new(1, -177, 0, 29)
barBack.Parent = panel
corner(barBack, 7)
local barPadding = Instance.new("UIPadding")
barPadding.PaddingLeft = UDim.new(0, 7)
barPadding.PaddingRight = UDim.new(0, 7)
barPadding.PaddingTop = UDim.new(0, 6)
barPadding.PaddingBottom = UDim.new(0, 6)
barPadding.Parent = barBack
local barLayout = Instance.new("UIListLayout")
barLayout.FillDirection = Enum.FillDirection.Horizontal
barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
barLayout.VerticalAlignment = Enum.VerticalAlignment.Center
barLayout.Padding = UDim.new(0, 3)
barLayout.Parent = barBack

local RPM_SEGMENTS = 30
local rpmSegments = table.create(RPM_SEGMENTS)
local function segmentColor(fraction)
	if fraction < 0.58 then
		return COLORS.green
	elseif fraction < 0.78 then
		return COLORS.yellow
	elseif fraction < 0.92 then
		return COLORS.orange
	end
	return COLORS.red
end

for i = 1, RPM_SEGMENTS do
	local segment = Instance.new("Frame")
	segment.Name = "Segment" .. i
	segment.BorderSizePixel = 0
	segment.BackgroundColor3 = COLORS.inactive
	segment.Size = UDim2.fromOffset(6, 17) -- recalculated from the actual bar width below
	segment.Parent = barBack
	corner(segment, 3)
	rpmSegments[i] = segment
end

-- Use pixel sizing based on the real inner width. Fractional child sizing plus
-- a fixed UIListLayout gap can leave the right side clipped or uneven.
local function layoutRpmSegments()
	local contentWidth = barBack.AbsoluteSize.X - 14 -- left/right UIPadding
	local gap = 3
	local availableForSegments = math.max(RPM_SEGMENTS * 2, contentWidth - gap * (RPM_SEGMENTS - 1))
	local baseWidth = math.floor(availableForSegments / RPM_SEGMENTS)
	local extraPixels = math.floor(availableForSegments - baseWidth * RPM_SEGMENTS)
	local segmentHeight = math.max(2, barBack.AbsoluteSize.Y - 12) -- top/bottom UIPadding
	for index, segment in ipairs(rpmSegments) do
		local width = baseWidth + (index <= extraPixels and 1 or 0)
		segment.Size = UDim2.fromOffset(width, segmentHeight)
	end
end

barBack:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutRpmSegments)
task.defer(layoutRpmSegments)

-- Vehicle telemetry.
local telemetry = Instance.new("Frame")
telemetry.BackgroundTransparency = 1
telemetry.Position = UDim2.fromOffset(18, 148)
telemetry.Size = UDim2.new(1, -36, 0, 22)
telemetry.Parent = panel

local gearLabel = makeLabel(telemetry, "GEAR   N", 11, UDim2.fromOffset(0, 0), Enum.Font.GothamBold, COLORS.text)
gearLabel.Size = UDim2.new(0.28, 0, 1, 0)
local speedLabel = makeLabel(telemetry, "SPEED   0 km/h", 10, UDim2.new(0.32, 0, 0, 0), Enum.Font.GothamBold, COLORS.muted)
speedLabel.Size = UDim2.new(0.38, 0, 1, 0)
local boostLabel = makeLabel(telemetry, "BOOST   0.00", 10, UDim2.new(0.72, 0, 0, 0), Enum.Font.GothamBold, COLORS.muted)
boostLabel.Size = UDim2.new(0.28, 0, 1, 0)
boostLabel.TextXAlignment = Enum.TextXAlignment.Right

local separator = Instance.new("Frame")
separator.BorderSizePixel = 0
separator.BackgroundColor3 = COLORS.stroke
separator.BackgroundTransparency = 0.35
separator.Position = UDim2.fromOffset(18, 174)
separator.Size = UDim2.new(1, -36, 0, 1)
separator.Parent = panel

-- Wind and backfire controls.
local windButton = makeButton(panel, "WIND  ON", UDim2.fromOffset(108, 32), UDim2.fromOffset(18, 185))
local windLevelLabel = makeLabel(panel, "LEVEL  30%", 9, UDim2.fromOffset(139, 184), Enum.Font.GothamBold, COLORS.muted)
windLevelLabel.Size = UDim2.fromOffset(75, 14)
local windDownButton = makeButton(panel, "−", UDim2.fromOffset(28, 26), UDim2.fromOffset(140, 199))
windDownButton.TextSize = 16
local windUpButton = makeButton(panel, "+", UDim2.fromOffset(28, 26), UDim2.fromOffset(181, 199))
windUpButton.TextSize = 16
local windTrack = Instance.new("Frame")
windTrack.BackgroundColor3 = COLORS.panel3
windTrack.Position = UDim2.fromOffset(220, 208)
windTrack.Size = UDim2.new(1, -440, 0, 7)
windTrack.Parent = panel
corner(windTrack, 5)
local windFill = Instance.new("Frame")
windFill.BorderSizePixel = 0
windFill.BackgroundColor3 = COLORS.accent
windFill.Size = UDim2.new(0.3, 0, 1, 0)
windFill.Parent = windTrack
corner(windFill, 5)

local backfireButton = makeButton(panel, "BACKFIRE  OFF", UDim2.fromOffset(124, 32), UDim2.new(1, -142, 0, 185))

local footer = makeLabel(panel, "W throttle   S brake   E/Q shift   SPACE clutch   I ignition   ENTER start", 8, UDim2.fromOffset(18, 225), Enum.Font.GothamMedium, COLORS.muted)
footer.Size = UDim2.new(1, -36, 0, 12)
footer.TextXAlignment = Enum.TextXAlignment.Center

-- Engine picker popup. It sits just above the main panel.
local popup = Instance.new("Frame")
popup.Name = "EnginePicker"
popup.AnchorPoint = Vector2.new(0.5, 1)
popup.Position = UDim2.new(0.5, 0, 1, -270)
popup.Size = UDim2.new(0.94, 0, 0, 220)
popup.BackgroundColor3 = COLORS.panel
popup.Visible = false
popup.Parent = gui
corner(popup, 13)
stroke(popup, COLORS.stroke, 1.2, 0)
local popupConstraint = Instance.new("UISizeConstraint")
popupConstraint.MinSize = Vector2.new(520, 220)
popupConstraint.MaxSize = Vector2.new(640, 220)
popupConstraint.Parent = popup

local pickerTitle = makeLabel(popup, "AVAILABLE ENGINE PRESETS", 10, UDim2.fromOffset(14, 10), Enum.Font.GothamBold, COLORS.accent)
pickerTitle.Size = UDim2.fromOffset(210, 18)
local searchBox = Instance.new("TextBox")
searchBox.ClearTextOnFocus = false
searchBox.PlaceholderText = "Search engines..."
searchBox.Text = ""
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 10
searchBox.TextColor3 = COLORS.text
searchBox.PlaceholderColor3 = COLORS.muted
searchBox.BackgroundColor3 = COLORS.panel2
searchBox.Position = UDim2.new(1, -174, 0, 8)
searchBox.Size = UDim2.fromOffset(160, 25)
searchBox.Parent = popup
corner(searchBox, 7)
stroke(searchBox, COLORS.stroke, 1, 0.2)

local engineList = Instance.new("ScrollingFrame")
engineList.Name = "PresetList"
engineList.BackgroundTransparency = 1
engineList.BorderSizePixel = 0
engineList.Position = UDim2.fromOffset(10, 40)
engineList.Size = UDim2.new(1, -20, 1, -49)
engineList.ScrollBarThickness = 4
engineList.ScrollBarImageColor3 = COLORS.accentDim
engineList.CanvasSize = UDim2.new(0, 0, 0, 0)
engineList.AutomaticCanvasSize = Enum.AutomaticSize.Y
engineList.Parent = popup
local engineListLayout = Instance.new("UIListLayout")
engineListLayout.Padding = UDim.new(0, 4)
engineListLayout.SortOrder = Enum.SortOrder.LayoutOrder
engineListLayout.Parent = engineList
local engineListPadding = Instance.new("UIPadding")
engineListPadding.PaddingRight = UDim.new(0, 5)
engineListPadding.Parent = engineList

local engineButtons = {}
local engineNames = {}
local selectedIndex = 1
local targetRPM = 0
local displayedRPM = 0
local currentRedline = 6800

local function updatePickerFilter()
	local filter = string.lower(searchBox.Text)
	for index, item in ipairs(engineButtons) do
		local matches = filter == "" or string.find(string.lower(engineNames[index]), filter, 1, true) ~= nil
		item.Visible = matches
	end
	engineList.CanvasPosition = Vector2.new(0, 0)
end

local function buildEngineList(names)
	for _, child in ipairs(engineList:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	table.clear(engineButtons)
	table.clear(engineNames)

	for index, engineName in ipairs(names) do
		engineNames[index] = engineName
		local item = Instance.new("TextButton")
		item.Name = "Engine" .. index
		item.AutoButtonColor = false
		item.Text = engineName
		item.TextXAlignment = Enum.TextXAlignment.Left
		item.Font = Enum.Font.GothamMedium
		item.TextSize = 10
		item.TextColor3 = COLORS.text
		item.BackgroundColor3 = COLORS.panel2
		item.Size = UDim2.new(1, -4, 0, 27)
		item.LayoutOrder = index
		item.Parent = engineList
		corner(item, 6)
		stroke(item, COLORS.stroke, 1, 0.5)
		item.MouseButton1Click:Connect(function()
			commandEvent:Fire("SelectEngine", index)
			popup.Visible = false
			searchBox.Text = ""
		end)
		engineButtons[index] = item
	end
	updatePickerFilter()
end

searchBox:GetPropertyChangedSignal("Text"):Connect(updatePickerFilter)
engineButton.MouseButton1Click:Connect(function()
	popup.Visible = not popup.Visible
end)

previousButton.MouseButton1Click:Connect(function()
	if #engineNames == 0 then return end
	commandEvent:Fire("SelectEngine", selectedIndex - 1 < 1 and #engineNames or selectedIndex - 1)
end)
nextButton.MouseButton1Click:Connect(function()
	if #engineNames == 0 then return end
	commandEvent:Fire("SelectEngine", selectedIndex + 1 > #engineNames and 1 or selectedIndex + 1)
end)

windButton.MouseButton1Click:Connect(function()
	commandEvent:Fire("SetWindEnabled", not (latestSnapshot and latestSnapshot.windEnabled))
end)
windDownButton.MouseButton1Click:Connect(function()
	local level = latestSnapshot and latestSnapshot.windLevel or 0.3
	commandEvent:Fire("SetWindLevel", math.max(0, level - 0.1))
end)
windUpButton.MouseButton1Click:Connect(function()
	local level = latestSnapshot and latestSnapshot.windLevel or 0.3
	commandEvent:Fire("SetWindLevel", math.min(1, level + 0.1))
end)
backfireButton.MouseButton1Click:Connect(function()
	commandEvent:Fire("SetBackfireEnabled", not (latestSnapshot and latestSnapshot.backfireEnabled))
end)

local function updateRpmBars(rpm, redline)
	local fraction = math.clamp((tonumber(rpm) or 0) / math.max(1, tonumber(redline) or 6800), 0, 1.15)
	local fillCount = math.floor(math.clamp(fraction, 0, 1) * RPM_SEGMENTS + 0.5)
	for index, segment in ipairs(rpmSegments) do
		if index <= fillCount then
			segment.BackgroundColor3 = segmentColor(index / RPM_SEGMENTS)
			segment.BackgroundTransparency = 0
		else
			segment.BackgroundColor3 = COLORS.inactive
			segment.BackgroundTransparency = 0.15
		end
	end
end

local function applySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	latestSnapshot = snapshot

	selectedIndex = snapshot.engineIndex or selectedIndex
	local engineName = snapshot.engineName or "Unknown engine"
	engineButton.Text = engineName .. "   ▾"
	if #engineNames == 0 and type(snapshot.engineNames) == "table" then
		buildEngineList(snapshot.engineNames)
	end

	targetRPM = math.max(0, tonumber(snapshot.rpm) or 0)
	currentRedline = math.max(1, tonumber(snapshot.redline) or 6800)
	redlineLabel.Text = string.format("REDLINE  %d", currentRedline)

	local gear = snapshot.gear or 0
	gearLabel.Text = "GEAR   " .. (gear == 0 and "N" or tostring(gear))
	speedLabel.Text = string.format("SPEED   %.0f km/h", snapshot.speedKmh or 0)
	boostLabel.Text = string.format("BOOST   %.2f", snapshot.boost or 0)

	local windOn = snapshot.windEnabled == true
	windButton.Text = "WIND  " .. (windOn and "ON" or "OFF")
	windButton.BackgroundColor3 = windOn and Color3.fromRGB(20, 67, 68) or COLORS.panel3
	windButton.TextColor3 = windOn and COLORS.accent or COLORS.muted
	windLevelLabel.Text = string.format("LEVEL  %d%%", math.floor((snapshot.windLevel or 0) * 100 + 0.5))
	windFill.Size = UDim2.new(math.clamp(snapshot.windLevel or 0, 0, 1), 0, 1, 0)
	windFill.BackgroundColor3 = windOn and COLORS.accent or COLORS.muted

	local backfireOn = snapshot.backfireEnabled == true
	backfireButton.Text = "BACKFIRE  " .. (backfireOn and "ON" or "OFF")
	backfireButton.BackgroundColor3 = backfireOn and Color3.fromRGB(76, 43, 34) or COLORS.panel3
	backfireButton.TextColor3 = backfireOn and COLORS.orange or COLORS.muted

	statusDot.BackgroundColor3 = snapshot.audioReady and COLORS.green or COLORS.yellow
	statusText.Text = snapshot.audioReady and "AUDIO READY" or "AUDIO OFF"
end

snapshotEvent.Event:Connect(applySnapshot)

-- Smooth the tacho between telemetry packets so it visibly follows revs
-- instead of jumping every 0.05 seconds.
local renderConnection = RunService.RenderStepped:Connect(function(dt)
	local blend = 1 - math.exp(-dt * 14)
	displayedRPM += (targetRPM - displayedRPM) * blend
	if math.abs(targetRPM - displayedRPM) < 1 then
		displayedRPM = targetRPM
	end
	rpmValue.Text = string.format("%04d", math.floor(displayedRPM + 0.5))
	updateRpmBars(displayedRPM, currentRedline)
end)

local ok, initialSnapshot = pcall(function()
	return getSnapshot:Invoke()
end)
if ok and initialSnapshot then
	applySnapshot(initialSnapshot)
end

-- Keep the picker responsive if another engine is selected from keyboard/UI.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape then
		popup.Visible = false
	end
end)

script.Destroying:Connect(function()
	if renderConnection then
		renderConnection:Disconnect()
	end
	if gui then
		gui:Destroy()
	end
end)
