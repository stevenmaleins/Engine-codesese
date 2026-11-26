-- VehicleAudioUI.client.lua
-- Studio test-bench UI for VehicleAudioTest.client.lua.
-- Put this LocalScript beside VehicleAudioTest.client.lua in StarterPlayerScripts.
--
-- Visual overhaul. The bridge, the commands (SelectEngine, SetWindEnabled,
-- SetWindLevel, SetBackfireEnabled) and the snapshot fields are unchanged.

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

local playerGui = player:WaitForChild("PlayerGui")
local oldGui = playerGui:FindFirstChild("VehicleAudioLabGui")
if oldGui then
	oldGui:Destroy()
end

----------------------------------------------------------------------
-- Layout constants (design space; the whole dock is scaled with UIScale
-- so it never overflows small screens / phones)
----------------------------------------------------------------------
local DESIGN_W = 620
local PANEL_H = 336
local POPUP_H = 224
local POPUP_GAP = 8
local EDGE_MARGIN = 16
local RPM_SEGMENTS = 32
local WIND_STEPS = 10

local COLORS = {
	bgTop = Color3.fromRGB(14, 21, 32),
	bgBottom = Color3.fromRGB(8, 12, 19),
	surface = Color3.fromRGB(18, 26, 39),
	surfaceHi = Color3.fromRGB(26, 37, 53),
	line = Color3.fromRGB(37, 53, 72),
	accent = Color3.fromRGB(56, 224, 200),
	accentDim = Color3.fromRGB(28, 104, 103),
	accentBg = Color3.fromRGB(15, 55, 57),
	text = Color3.fromRGB(236, 244, 248),
	muted = Color3.fromRGB(127, 146, 164),
	dim = Color3.fromRGB(78, 95, 114),
	green = Color3.fromRGB(69, 213, 157),
	yellow = Color3.fromRGB(246, 194, 82),
	orange = Color3.fromRGB(244, 130, 76),
	red = Color3.fromRGB(245, 79, 86),
	orangeBg = Color3.fromRGB(72, 41, 31),
	greenBg = Color3.fromRGB(14, 46, 38),
	yellowBg = Color3.fromRGB(54, 43, 16),
}

local TWEEN_FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_POPUP_IN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_POPUP_OUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function tween(object, info, props)
	local item = TweenService:Create(object, info, props)
	item:Play()
	return item
end

local function lighten(color, amount)
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

local function darken(color, amount)
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

local function applyProps(object, props)
	if props then
		for key, value in pairs(props) do
			object[key] = value
		end
	end
end

local function corner(parent, radius)
	local item = Instance.new("UICorner")
	item.CornerRadius = UDim.new(0, radius or 10)
	item.Parent = parent
	return item
end

local function stroke(parent, color, thickness, transparency)
	local item = Instance.new("UIStroke")
	item.Color = color or COLORS.line
	item.Thickness = thickness or 1
	item.Transparency = transparency or 0
	item.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	item.Parent = parent
	return item
end

local function newFrame(parent, props, radius)
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = COLORS.surface
	applyProps(frame, props)
	frame.Parent = parent
	if radius then
		corner(frame, radius)
	end
	return frame
end

local function newLabel(parent, text, size, font, color, props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Text = text or ""
	label.TextSize = size or 12
	label.Font = font or Enum.Font.Gotham
	label.TextColor3 = color or COLORS.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Size = UDim2.fromScale(1, 1)
	applyProps(label, props)
	label.Parent = parent
	return label
end

-- Buttons keep their own base colour. Hover/press are layered on top of it, so
-- an "active" toggle (WIND ON, BACKFIRE ON) no longer loses its colour as soon
-- as the mouse leaves it.
local buttonState = setmetatable({}, { __mode = "k" })

local function paintButton(button)
	local state = buttonState[button]
	if not state then
		return
	end
	local color = state.base
	if state.pressed then
		color = darken(state.base, 0.18)
	elseif state.hover then
		color = lighten(state.base, 0.09)
	end
	tween(button, TWEEN_FAST, { BackgroundColor3 = color })
end

local function styleButton(button, base, textColor, strokeColor)
	local state = buttonState[button]
	if not state then
		return
	end
	state.base = base
	paintButton(button)
	if textColor then
		tween(button, TWEEN_FAST, { TextColor3 = textColor })
	end
	if strokeColor then
		tween(state.stroke, TWEEN_FAST, { Color = strokeColor })
	end
end

local function makeButton(parent, text, props)
	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Text = text or ""
	button.TextSize = 12
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = COLORS.text
	button.BackgroundColor3 = COLORS.surface
	button.Size = UDim2.fromOffset(60, 30)
	applyProps(button, props)
	button.Parent = parent
	corner(button, 9)
	local outline = stroke(button, COLORS.line, 1, 0.1)

	local state = { base = button.BackgroundColor3, hover = false, pressed = false, stroke = outline }
	buttonState[button] = state

	button.MouseEnter:Connect(function()
		state.hover = true
		paintButton(button)
	end)
	button.MouseLeave:Connect(function()
		state.hover = false
		state.pressed = false
		paintButton(button)
	end)
	button.MouseButton1Down:Connect(function()
		state.pressed = true
		paintButton(button)
	end)
	button.MouseButton1Up:Connect(function()
		state.pressed = false
		if not UserInputService.MouseEnabled then
			state.hover = false
		end
		paintButton(button)
	end)
	return button
end

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

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local latestSnapshot = nil
local engineButtons = {}
local engineNames = {}
local itemParts = {}
local selectedIndex = 1
local pickerSelected = nil
local targetRPM = 0
local displayedRPM = 0
local currentRedline = 6800
local popupOpen = false
local popupRestY = -(PANEL_H + POPUP_GAP)
local shown = {} -- last values pushed to the UI, so we only animate on change
local connections = {}

local function track(connection)
	connections[#connections + 1] = connection
	return connection
end

----------------------------------------------------------------------
-- Root GUI
----------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "VehicleAudioLabGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 30
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- Invisible click-catcher: clicking anywhere outside the picker closes it.
local scrim = Instance.new("TextButton")
scrim.Name = "Scrim"
scrim.AutoButtonColor = false
scrim.BackgroundTransparency = 1
scrim.BorderSizePixel = 0
scrim.Text = ""
scrim.Size = UDim2.fromScale(1, 1)
scrim.ZIndex = 0
scrim.Visible = false
scrim.Parent = gui

local dock = Instance.new("Frame")
dock.Name = "Dock"
dock.BackgroundTransparency = 1
dock.BorderSizePixel = 0
dock.AnchorPoint = Vector2.new(0.5, 1)
dock.Position = UDim2.new(0.5, 0, 1, -EDGE_MARGIN)
dock.Size = UDim2.fromOffset(DESIGN_W, PANEL_H + POPUP_GAP + POPUP_H)
dock.Parent = gui

local dockScale = Instance.new("UIScale")
dockScale.Parent = dock

----------------------------------------------------------------------
-- Main panel
----------------------------------------------------------------------
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0, 1)
panel.Position = UDim2.fromScale(0, 1)
panel.Size = UDim2.fromOffset(DESIGN_W, PANEL_H)
panel.BackgroundColor3 = Color3.new(1, 1, 1)
panel.BorderSizePixel = 0
panel.Parent = dock
corner(panel, 18)

local panelGradient = Instance.new("UIGradient")
panelGradient.Color = ColorSequence.new(COLORS.bgTop, COLORS.bgBottom)
panelGradient.Rotation = 90
panelGradient.Parent = panel

local panelStroke = stroke(panel, Color3.new(1, 1, 1), 1.25, 0)
local panelStrokeGradient = Instance.new("UIGradient")
panelStrokeGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, COLORS.accentDim),
	ColorSequenceKeypoint.new(0.4, COLORS.line),
	ColorSequenceKeypoint.new(1, COLORS.line),
})
panelStrokeGradient.Rotation = 90
panelStrokeGradient.Parent = panelStroke

local topGlow = newFrame(panel, {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromScale(0.5, 0),
	Size = UDim2.new(0.62, 0, 0, 2),
	BackgroundColor3 = COLORS.accent,
})
local topGlowGradient = Instance.new("UIGradient")
topGlowGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(1, 1),
})
topGlowGradient.Parent = topGlow

local content = Instance.new("Frame")
content.Name = "Content"
content.BackgroundTransparency = 1
content.Position = UDim2.fromOffset(16, 12)
content.Size = UDim2.new(1, -32, 1, -22)
content.Parent = panel

local contentLayout = Instance.new("UIListLayout")
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Padding = UDim.new(0, 8)
contentLayout.Parent = content

local function makeRow(height, order)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, height)
	row.LayoutOrder = order
	row.Parent = content
	return row
end

local function makeCard(height, order)
	local card = newFrame(content, { Size = UDim2.new(1, 0, 0, height), LayoutOrder = order }, 12)
	stroke(card, COLORS.line, 1, 0.3)
	return card
end

----------------------------------------------------------------------
-- Header
----------------------------------------------------------------------
local headerRow = makeRow(28, 1)

local logo = newFrame(headerRow, { Size = UDim2.fromOffset(28, 28), BackgroundColor3 = COLORS.accentBg }, 8)
stroke(logo, COLORS.accentDim, 1, 0.1)
local logoLayout = Instance.new("UIListLayout")
logoLayout.FillDirection = Enum.FillDirection.Horizontal
logoLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
logoLayout.VerticalAlignment = Enum.VerticalAlignment.Center
logoLayout.Padding = UDim.new(0, 2)
logoLayout.Parent = logo
for _, barHeight in ipairs({ 8, 14, 18, 11, 6 }) do
	newFrame(logo, { Size = UDim2.fromOffset(2, barHeight), BackgroundColor3 = COLORS.accent }, 1)
end

newLabel(headerRow, "VEHICLE AUDIO LAB", 13, Enum.Font.GothamBold, COLORS.text, {
	Position = UDim2.fromOffset(38, 0),
	Size = UDim2.fromOffset(260, 15),
})
newLabel(headerRow, "PROCEDURAL ENGINE TEST BENCH", 10, Enum.Font.GothamMedium, COLORS.muted, {
	Position = UDim2.fromOffset(38, 16),
	Size = UDim2.fromOffset(260, 12),
})

local statusPill = newFrame(headerRow, {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.fromScale(1, 0.5),
	Size = UDim2.fromOffset(0, 24),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = COLORS.yellowBg,
}, 12)
local statusStroke = stroke(statusPill, COLORS.yellow, 1, 0.65)
local pillLayout = Instance.new("UIListLayout")
pillLayout.FillDirection = Enum.FillDirection.Horizontal
pillLayout.VerticalAlignment = Enum.VerticalAlignment.Center
pillLayout.SortOrder = Enum.SortOrder.LayoutOrder
pillLayout.Padding = UDim.new(0, 7)
pillLayout.Parent = statusPill
local pillPadding = Instance.new("UIPadding")
pillPadding.PaddingLeft = UDim.new(0, 11)
pillPadding.PaddingRight = UDim.new(0, 13)
pillPadding.Parent = statusPill
local statusDot = newFrame(statusPill, {
	Size = UDim2.fromOffset(8, 8),
	BackgroundColor3 = COLORS.yellow,
	LayoutOrder = 1,
}, 4)
local statusText = newLabel(statusPill, "WAITING", 10, Enum.Font.GothamBold, COLORS.yellow, {
	Size = UDim2.fromOffset(0, 24),
	AutomaticSize = Enum.AutomaticSize.X,
	LayoutOrder = 2,
})

----------------------------------------------------------------------
-- Engine selector row
----------------------------------------------------------------------
local engineRow = makeRow(34, 2)

local previousButton = makeButton(engineRow, "‹", {
	Size = UDim2.fromOffset(34, 34),
	TextSize = 22,
})
local nextButton = makeButton(engineRow, "›", {
	Size = UDim2.fromOffset(34, 34),
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromScale(1, 0),
	TextSize = 22,
})
local engineButton = makeButton(engineRow, "", {
	Position = UDim2.fromOffset(42, 0),
	Size = UDim2.new(1, -84, 1, 0),
})
newLabel(engineButton, "ENGINE", 10, Enum.Font.GothamBold, COLORS.dim, {
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.fromOffset(52, 34),
})
local engineNameLabel = newLabel(engineButton, "Select engine", 13, Enum.Font.GothamBold, COLORS.text, {
	Position = UDim2.fromOffset(68, 0),
	Size = UDim2.new(1, -176, 1, 0),
	TextTruncate = Enum.TextTruncate.AtEnd,
})
local engineCountLabel = newLabel(engineButton, "", 11, Enum.Font.GothamBold, COLORS.muted, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -34, 0, 0),
	Size = UDim2.fromOffset(72, 34),
	TextXAlignment = Enum.TextXAlignment.Right,
})
local chevron = newLabel(engineButton, "▾", 13, Enum.Font.GothamBold, COLORS.accent, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 0),
	Size = UDim2.fromOffset(16, 34),
	TextXAlignment = Enum.TextXAlignment.Center,
})

----------------------------------------------------------------------
-- Tachometer card
----------------------------------------------------------------------
local tachCard = makeCard(72, 3)

newLabel(tachCard, "ENGINE SPEED", 10, Enum.Font.GothamBold, COLORS.muted, {
	Position = UDim2.fromOffset(14, 8),
	Size = UDim2.fromOffset(130, 12),
})
local rpmValue = newLabel(tachCard, "0000", 32, Enum.Font.GothamBlack, COLORS.text, {
	Position = UDim2.fromOffset(13, 22),
	Size = UDim2.fromOffset(96, 40),
})
newLabel(tachCard, "RPM", 11, Enum.Font.GothamBold, COLORS.muted, {
	Position = UDim2.fromOffset(110, 40),
	Size = UDim2.fromOffset(34, 14),
})
newFrame(tachCard, {
	Position = UDim2.fromOffset(150, 12),
	Size = UDim2.new(0, 1, 1, -24),
	BackgroundColor3 = COLORS.line,
	BackgroundTransparency = 0.3,
})

local redlineLabel = newLabel(tachCard, 'REDLINE  <font color="#F54F56">6800</font>', 10, Enum.Font.GothamBold, COLORS.muted, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -14, 0, 8),
	Size = UDim2.fromOffset(160, 12),
	TextXAlignment = Enum.TextXAlignment.Right,
	RichText = true,
})

-- Segment bar. Each segment lives in a slot sized by scale, so the bar always
-- fills its full width evenly with no clipping or leftover pixels.
local barArea = Instance.new("Frame")
barArea.Name = "RPMBar"
barArea.BackgroundTransparency = 1
barArea.Position = UDim2.fromOffset(166, 24)
barArea.Size = UDim2.new(1, -180, 0, 26)
barArea.Parent = tachCard

local rpmSegments = table.create(RPM_SEGMENTS)
for i = 1, RPM_SEGMENTS do
	local slot = Instance.new("Frame")
	slot.Name = "Slot" .. i
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.Position = UDim2.new((i - 1) / RPM_SEGMENTS, 0, 0, 0)
	slot.Size = UDim2.new(1 / RPM_SEGMENTS, 0, 1, 0)
	slot.Parent = barArea

	local segment = Instance.new("Frame")
	segment.Name = "Segment"
	segment.BorderSizePixel = 0
	segment.AnchorPoint = Vector2.new(0, 1)
	segment.Position = UDim2.fromScale(0, 1)
	segment.Size = UDim2.new(1, i < RPM_SEGMENTS and -3 or 0, 0.4 + 0.6 * (i / RPM_SEGMENTS), 0)
	segment.BackgroundColor3 = segmentColor(i / RPM_SEGMENTS)
	segment.BackgroundTransparency = 0.86
	segment.Parent = slot
	corner(segment, 2)
	rpmSegments[i] = segment
end

-- Tick labels (in thousands of RPM) under the bar, rebuilt if the redline changes.
local tickArea = Instance.new("Frame")
tickArea.Name = "Ticks"
tickArea.BackgroundTransparency = 1
tickArea.Position = UDim2.fromOffset(166, 54)
tickArea.Size = UDim2.new(1, -180, 0, 12)
tickArea.Parent = tachCard

local tickLabels = {}
local tickRedline = nil
local function rebuildTicks(redline)
	if tickRedline == redline then
		return
	end
	tickRedline = redline
	for _, label in ipairs(tickLabels) do
		label:Destroy()
	end
	table.clear(tickLabels)

	local step = redline > 12000 and 2000 or 1000
	local count = 0
	while count <= 20 and count * step <= redline do
		tickLabels[#tickLabels + 1] = newLabel(tickArea, tostring(count * step / 1000), 10, Enum.Font.GothamMedium, COLORS.muted, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(count * step / redline, 0, 0, 0),
			Size = UDim2.fromOffset(24, 12),
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		count += 1
	end
end
rebuildTicks(currentRedline)

----------------------------------------------------------------------
-- Telemetry cards
----------------------------------------------------------------------
local statsRow = makeRow(44, 4)
local statsLayout = Instance.new("UIListLayout")
statsLayout.FillDirection = Enum.FillDirection.Horizontal
statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
statsLayout.Padding = UDim.new(0, 8)
statsLayout.Parent = statsRow

local function makeStat(caption, order)
	local card = newFrame(statsRow, { Size = UDim2.new(1 / 3, -6, 1, 0), LayoutOrder = order }, 12)
	stroke(card, COLORS.line, 1, 0.3)
	newLabel(card, caption, 10, Enum.Font.GothamBold, COLORS.muted, {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 12),
	})
	return newLabel(card, "", 18, Enum.Font.GothamBold, COLORS.text, {
		Position = UDim2.fromOffset(12, 18),
		Size = UDim2.new(1, -24, 0, 22),
		RichText = true,
	})
end

local gearLabel = makeStat("GEAR", 1)
local speedLabel = makeStat("SPEED", 2)
local boostLabel = makeStat("BOOST", 3)
gearLabel.Text = "N"
speedLabel.Text = '0 <font size="12" color="#7F92A4">km/h</font>'
boostLabel.Text = "0.00"

----------------------------------------------------------------------
-- Wind + backfire controls
----------------------------------------------------------------------
local controlsRow = makeRow(36, 5)

local windCard = newFrame(controlsRow, { Size = UDim2.new(1, -158, 1, 0) }, 12)
stroke(windCard, COLORS.line, 1, 0.3)
local windInner = Instance.new("Frame")
windInner.BackgroundTransparency = 1
windInner.Position = UDim2.fromOffset(4, 4)
windInner.Size = UDim2.new(1, -8, 1, -8)
windInner.Parent = windCard

local windButton = makeButton(windInner, "WIND  ON", {
	Size = UDim2.new(0, 92, 1, 0),
	TextSize = 11,
})
local windDownButton = makeButton(windInner, "−", {
	Position = UDim2.fromOffset(100, 0),
	Size = UDim2.new(0, 28, 1, 0),
	TextSize = 16,
})
local windUpButton = makeButton(windInner, "+", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -52, 0, 0),
	Size = UDim2.new(0, 28, 1, 0),
	TextSize = 16,
})
local windLevelLabel = newLabel(windInner, "30%", 12, Enum.Font.GothamBold, COLORS.text, {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromScale(1, 0),
	Size = UDim2.new(0, 44, 1, 0),
	TextXAlignment = Enum.TextXAlignment.Right,
})

local windBar = Instance.new("Frame")
windBar.Name = "WindLevel"
windBar.BackgroundTransparency = 1
windBar.AnchorPoint = Vector2.new(0, 0.5)
windBar.Position = UDim2.new(0, 136, 0.5, 0)
windBar.Size = UDim2.new(1, -224, 0, 10)
windBar.Parent = windInner

local windSegments = table.create(WIND_STEPS)
for i = 1, WIND_STEPS do
	local slot = Instance.new("Frame")
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.Position = UDim2.new((i - 1) / WIND_STEPS, 0, 0, 0)
	slot.Size = UDim2.new(1 / WIND_STEPS, 0, 1, 0)
	slot.Parent = windBar

	local segment = Instance.new("Frame")
	segment.BorderSizePixel = 0
	segment.Size = UDim2.new(1, i < WIND_STEPS and -3 or 0, 1, 0)
	segment.BackgroundColor3 = COLORS.line
	segment.Parent = slot
	corner(segment, 3)
	windSegments[i] = segment
end

local backfireButton = makeButton(controlsRow, "BACKFIRE  OFF", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromScale(1, 0),
	Size = UDim2.new(0, 150, 1, 0),
	TextSize = 11,
})

----------------------------------------------------------------------
-- Straight-cut gearbox whine gain (multiplier applied to each preset's own level)
----------------------------------------------------------------------
local gearWhineRow = makeRow(36, 6)
local gearWhineCard = newFrame(gearWhineRow, { Size = UDim2.new(1, 0, 1, 0) }, 12)
stroke(gearWhineCard, COLORS.line, 1, 0.3)

newLabel(gearWhineCard, "GEARBOX WHINE GAIN", 11, Enum.Font.GothamBold, COLORS.text, {
	Position = UDim2.fromOffset(12, 2),
	Size = UDim2.fromOffset(240, 15),
})
local gearWhineInfoLabel = newLabel(gearWhineCard, "Preset whine level: checking...", 10, Enum.Font.GothamMedium, COLORS.muted, {
	Position = UDim2.fromOffset(12, 18),
	Size = UDim2.new(1, -190, 0, 12),
	TextTruncate = Enum.TextTruncate.AtEnd,
})

local gearWhineDownButton = makeButton(gearWhineCard, "−", {
	Position = UDim2.new(1, -142, 0, 3),
	Size = UDim2.fromOffset(30, 30),
	TextSize = 16,
})
local gearWhineValueBox = Instance.new("TextBox")
gearWhineValueBox.Name = "GearWhineMultiplier"
gearWhineValueBox.ClearTextOnFocus = false
gearWhineValueBox.Text = "1.00"
gearWhineValueBox.Font = Enum.Font.GothamBold
gearWhineValueBox.TextSize = 12
gearWhineValueBox.TextColor3 = COLORS.text
gearWhineValueBox.TextXAlignment = Enum.TextXAlignment.Center
gearWhineValueBox.BackgroundColor3 = COLORS.surfaceHi
gearWhineValueBox.BorderSizePixel = 0
gearWhineValueBox.Position = UDim2.new(1, -112, 0, 3)
gearWhineValueBox.Size = UDim2.fromOffset(56, 30)
gearWhineValueBox.Parent = gearWhineCard
corner(gearWhineValueBox, 8)
local gearWhineValueStroke = stroke(gearWhineValueBox, COLORS.line, 1, 0.15)
local gearWhineUnitLabel = newLabel(gearWhineCard, "×", 12, Enum.Font.GothamBold, COLORS.muted, {
	Position = UDim2.new(1, -56, 0, 3),
	Size = UDim2.fromOffset(14, 30),
	TextXAlignment = Enum.TextXAlignment.Center,
})
local gearWhineUpButton = makeButton(gearWhineCard, "+", {
	Position = UDim2.new(1, -42, 0, 3),
	Size = UDim2.fromOffset(30, 30),
	TextSize = 16,
})

----------------------------------------------------------------------
-- Key hints
----------------------------------------------------------------------
local footerRow = makeRow(16, 7)
local footerLayout = Instance.new("UIListLayout")
footerLayout.FillDirection = Enum.FillDirection.Horizontal
footerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
footerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
footerLayout.SortOrder = Enum.SortOrder.LayoutOrder
footerLayout.Padding = UDim.new(0, 14)
footerLayout.Parent = footerRow

local function addHint(key, description, order)
	local hint = Instance.new("Frame")
	hint.BackgroundTransparency = 1
	hint.BorderSizePixel = 0
	hint.Size = UDim2.new(0, 0, 1, 0)
	hint.AutomaticSize = Enum.AutomaticSize.X
	hint.LayoutOrder = order
	hint.Parent = footerRow

	local hintLayout = Instance.new("UIListLayout")
	hintLayout.FillDirection = Enum.FillDirection.Horizontal
	hintLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	hintLayout.SortOrder = Enum.SortOrder.LayoutOrder
	hintLayout.Padding = UDim.new(0, 5)
	hintLayout.Parent = hint

	local cap = newLabel(hint, key, 10, Enum.Font.GothamBold, COLORS.text, {
		Size = UDim2.fromOffset(0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 0,
		BackgroundColor3 = COLORS.surfaceHi,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 1,
	})
	corner(cap, 4)
	stroke(cap, COLORS.line, 1, 0.3)
	local capPadding = Instance.new("UIPadding")
	capPadding.PaddingLeft = UDim.new(0, 6)
	capPadding.PaddingRight = UDim.new(0, 6)
	capPadding.Parent = cap

	newLabel(hint, description, 10, Enum.Font.GothamMedium, COLORS.muted, {
		Size = UDim2.fromOffset(0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
	})
end

addHint("W", "THROTTLE", 1)
addHint("S", "BRAKE", 2)
addHint("E / Q", "SHIFT", 3)
addHint("SPACE", "CLUTCH", 4)
addHint("I", "IGNITION", 5)
addHint("ENTER", "START", 6)

----------------------------------------------------------------------
-- Engine picker popup (sits just above the main panel)
----------------------------------------------------------------------
local popup = Instance.new("Frame")
popup.Name = "EnginePicker"
popup.AnchorPoint = Vector2.new(0, 1)
popup.Position = UDim2.new(0, 0, 1, popupRestY)
popup.Size = UDim2.fromOffset(DESIGN_W, POPUP_H)
popup.BackgroundColor3 = Color3.new(1, 1, 1)
popup.BorderSizePixel = 0
popup.Visible = false
popup.Parent = dock
corner(popup, 16)
local popupStroke = stroke(popup, COLORS.line, 1.25, 0)

local popupGradient = Instance.new("UIGradient")
popupGradient.Color = ColorSequence.new(COLORS.bgTop, COLORS.bgBottom)
popupGradient.Rotation = 90
popupGradient.Parent = popup

local popupTitle = newLabel(popup, "ENGINE PRESETS", 11, Enum.Font.GothamBold, COLORS.accent, {
	Position = UDim2.fromOffset(18, 10),
	Size = UDim2.fromOffset(150, 14),
})
local popupCount = newLabel(popup, "", 10, Enum.Font.GothamMedium, COLORS.muted, {
	Position = UDim2.fromOffset(18, 25),
	Size = UDim2.fromOffset(150, 12),
})

local searchBox = Instance.new("TextBox")
searchBox.Name = "Search"
searchBox.ClearTextOnFocus = false
searchBox.PlaceholderText = "Search engines..."
searchBox.Text = ""
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 12
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.TextColor3 = COLORS.text
searchBox.PlaceholderColor3 = COLORS.dim
searchBox.BackgroundColor3 = COLORS.surface
searchBox.BorderSizePixel = 0
searchBox.AnchorPoint = Vector2.new(1, 0)
searchBox.Position = UDim2.new(1, -14, 0, 10)
searchBox.Size = UDim2.fromOffset(220, 28)
searchBox.Parent = popup
corner(searchBox, 8)
local searchStroke = stroke(searchBox, COLORS.line, 1, 0.1)
local searchPadding = Instance.new("UIPadding")
searchPadding.PaddingLeft = UDim.new(0, 10)
searchPadding.PaddingRight = UDim.new(0, 10)
searchPadding.Parent = searchBox

track(searchBox.Focused:Connect(function()
	tween(searchStroke, TWEEN_FAST, { Color = COLORS.accent })
end))
track(searchBox.FocusLost:Connect(function()
	tween(searchStroke, TWEEN_FAST, { Color = COLORS.line })
end))

newFrame(popup, {
	Position = UDim2.fromOffset(14, 46),
	Size = UDim2.new(1, -28, 0, 1),
	BackgroundColor3 = COLORS.line,
	BackgroundTransparency = 0.4,
})

local engineList = Instance.new("ScrollingFrame")
engineList.Name = "PresetList"
engineList.BackgroundTransparency = 1
engineList.BorderSizePixel = 0
engineList.Position = UDim2.fromOffset(10, 54)
engineList.Size = UDim2.new(1, -20, 1, -62)
engineList.ScrollBarThickness = 4
engineList.ScrollBarImageColor3 = COLORS.accentDim
engineList.ScrollingDirection = Enum.ScrollingDirection.Y
engineList.CanvasSize = UDim2.new(0, 0, 0, 0)
engineList.AutomaticCanvasSize = Enum.AutomaticSize.Y
engineList.Parent = popup

local engineListLayout = Instance.new("UIListLayout")
engineListLayout.Padding = UDim.new(0, 4)
engineListLayout.SortOrder = Enum.SortOrder.LayoutOrder
engineListLayout.Parent = engineList
local engineListPadding = Instance.new("UIPadding")
engineListPadding.PaddingRight = UDim.new(0, 8)
engineListPadding.Parent = engineList

local emptyLabel = newLabel(popup, "No engines match your search", 12, Enum.Font.GothamMedium, COLORS.muted, {
	Position = UDim2.fromOffset(0, 54),
	Size = UDim2.new(1, 0, 0, 40),
	TextXAlignment = Enum.TextXAlignment.Center,
	Visible = false,
})

local ITEM_HEIGHT = 30
local ITEM_PADDING = 4

local function updatePickerFilter()
	local filter = string.lower(searchBox.Text)
	local visibleCount = 0
	for index, item in ipairs(engineButtons) do
		local matches = filter == "" or string.find(string.lower(engineNames[index]), filter, 1, true) ~= nil
		item.Visible = matches
		if matches then
			visibleCount += 1
		end
	end
	emptyLabel.Visible = #engineButtons > 0 and visibleCount == 0
	if filter ~= "" then
		engineList.CanvasPosition = Vector2.new(0, 0)
	end
end

local function refreshPicker()
	if pickerSelected == selectedIndex then
		return
	end
	pickerSelected = selectedIndex
	for index, item in ipairs(engineButtons) do
		local selected = index == selectedIndex
		local parts = itemParts[index]
		styleButton(
			item,
			selected and COLORS.accentBg or COLORS.surface,
			COLORS.text,
			selected and COLORS.accentDim or COLORS.line
		)
		parts.name.TextColor3 = selected and COLORS.accent or COLORS.text
		parts.marker.Visible = selected
	end
end

local function setPopupOpen(open)
	if open == popupOpen then
		return
	end
	popupOpen = open
	scrim.Visible = open
	chevron.Text = open and "▴" or "▾"

	local restPosition = UDim2.new(0, 0, 1, popupRestY)
	local hiddenPosition = UDim2.new(0, 0, 1, popupRestY + 10)

	if open then
		if searchBox.Text ~= "" then
			searchBox.Text = ""
			updatePickerFilter()
		end
		popup.Position = hiddenPosition
		popup.Visible = true
		tween(popup, TWEEN_POPUP_IN, { Position = restPosition })
		-- Bring the current engine into view.
		engineList.CanvasPosition = Vector2.new(0, math.max(0, (selectedIndex - 1) * (ITEM_HEIGHT + ITEM_PADDING) - 70))
	else
		searchBox:ReleaseFocus()
		local closing = tween(popup, TWEEN_POPUP_OUT, { Position = hiddenPosition })
		closing.Completed:Once(function()
			if not popupOpen then
				popup.Visible = false
			end
		end)
	end
end

local function buildEngineList(names)
	for _, child in ipairs(engineList:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	table.clear(engineButtons)
	table.clear(engineNames)
	table.clear(itemParts)
	pickerSelected = nil

	for index, rawName in ipairs(names) do
		local engineName = tostring(rawName)
		engineNames[index] = engineName

		local item = makeButton(engineList, "", {
			Name = "Engine" .. index,
			Size = UDim2.new(1, 0, 0, ITEM_HEIGHT),
			LayoutOrder = index,
		})
		local marker = newFrame(item, {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 7, 0.5, 0),
			Size = UDim2.fromOffset(3, 14),
			BackgroundColor3 = COLORS.accent,
			Visible = false,
		}, 2)
		newLabel(item, string.format("%02d", index), 10, Enum.Font.GothamBold, COLORS.dim, {
			Position = UDim2.fromOffset(18, 0),
			Size = UDim2.fromOffset(28, ITEM_HEIGHT),
		})
		local nameLabel = newLabel(item, engineName, 12, Enum.Font.GothamMedium, COLORS.text, {
			Position = UDim2.fromOffset(52, 0),
			Size = UDim2.new(1, -64, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		item.MouseButton1Click:Connect(function()
			commandEvent:Fire("SelectEngine", index)
			setPopupOpen(false)
		end)

		engineButtons[index] = item
		itemParts[index] = { name = nameLabel, marker = marker }
	end

	popupCount.Text = string.format("%d available", #engineNames)
	updatePickerFilter()
	refreshPicker()
end

track(searchBox:GetPropertyChangedSignal("Text"):Connect(updatePickerFilter))
track(engineButton.MouseButton1Click:Connect(function()
	setPopupOpen(not popupOpen)
end))
track(scrim.MouseButton1Click:Connect(function()
	setPopupOpen(false)
end))

----------------------------------------------------------------------
-- Button wiring (same commands as before)
----------------------------------------------------------------------
track(previousButton.MouseButton1Click:Connect(function()
	if #engineNames == 0 then return end
	commandEvent:Fire("SelectEngine", selectedIndex - 1 < 1 and #engineNames or selectedIndex - 1)
end))
track(nextButton.MouseButton1Click:Connect(function()
	if #engineNames == 0 then return end
	commandEvent:Fire("SelectEngine", selectedIndex + 1 > #engineNames and 1 or selectedIndex + 1)
end))

track(windButton.MouseButton1Click:Connect(function()
	commandEvent:Fire("SetWindEnabled", not (latestSnapshot and latestSnapshot.windEnabled))
end))
local function stepWind(delta)
	local level = latestSnapshot and latestSnapshot.windLevel or 0.3
	local newLevel = math.clamp(math.floor((level + delta) * 100 + 0.5) / 100, 0, 1)
	commandEvent:Fire("SetWindLevel", newLevel)
end
track(windDownButton.MouseButton1Click:Connect(function()
	stepWind(-0.1)
end))
track(windUpButton.MouseButton1Click:Connect(function()
	stepWind(0.1)
end))
track(backfireButton.MouseButton1Click:Connect(function()
	commandEvent:Fire("SetBackfireEnabled", not (latestSnapshot and latestSnapshot.backfireEnabled))
end))

local function setGearWhineMultiplier(value)
	local multiplier = math.clamp(tonumber(value) or 1, 0, 3)
	multiplier = math.floor(multiplier * 100 + 0.5) / 100
	commandEvent:Fire("SetGearWhineMultiplier", multiplier)
end

local function stepGearWhine(delta)
	local current = latestSnapshot and tonumber(latestSnapshot.gearWhineMultiplier) or 1
	setGearWhineMultiplier(current + delta)
end

track(gearWhineDownButton.MouseButton1Click:Connect(function()
	stepGearWhine(-0.10)
end))
track(gearWhineUpButton.MouseButton1Click:Connect(function()
	stepGearWhine(0.10)
end))
track(gearWhineValueBox.Focused:Connect(function()
	tween(gearWhineValueStroke, TWEEN_FAST, { Color = COLORS.accent })
end))
track(gearWhineValueBox.FocusLost:Connect(function()
	tween(gearWhineValueStroke, TWEEN_FAST, { Color = COLORS.line })
	local value = tonumber(gearWhineValueBox.Text)
	if value == nil then
		value = latestSnapshot and tonumber(latestSnapshot.gearWhineMultiplier) or 1
	end
	setGearWhineMultiplier(value)
end))

----------------------------------------------------------------------
-- Snapshot -> UI
----------------------------------------------------------------------
local function updateWindBar(steps, windOn)
	local key = steps .. (windOn and "on" or "off")
	if shown.windBar == key then
		return
	end
	shown.windBar = key
	local fillColor = windOn and COLORS.accent or COLORS.muted
	for index, segment in ipairs(windSegments) do
		tween(segment, TWEEN_FAST, {
			BackgroundColor3 = index <= steps and fillColor or COLORS.line,
			BackgroundTransparency = (index <= steps and not windOn) and 0.35 or 0,
		})
	end
end

local function applySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	latestSnapshot = snapshot

	if type(snapshot.engineNames) == "table" and #snapshot.engineNames ~= #engineNames then
		buildEngineList(snapshot.engineNames)
	end

	selectedIndex = snapshot.engineIndex or selectedIndex
	engineNameLabel.Text = snapshot.engineName or "Unknown engine"
	if #engineNames > 0 then
		engineCountLabel.Text = string.format("%02d / %02d", math.floor(selectedIndex), #engineNames)
	end
	refreshPicker()

	targetRPM = math.max(0, tonumber(snapshot.rpm) or 0)
	currentRedline = math.max(1, tonumber(snapshot.redline) or 6800)
	if shown.redline ~= currentRedline then
		shown.redline = currentRedline
		redlineLabel.Text = string.format('REDLINE  <font color="#F54F56">%.0f</font>', currentRedline)
		rebuildTicks(currentRedline)
	end

	-- Telemetry
	local gear = tonumber(snapshot.gear) or 0
	if gear == 0 then
		gearLabel.Text = "N"
		gearLabel.TextColor3 = COLORS.muted
	elseif gear < 0 then
		gearLabel.Text = "R"
		gearLabel.TextColor3 = COLORS.orange
	else
		gearLabel.Text = string.format("%.0f", gear)
		gearLabel.TextColor3 = COLORS.accent
	end
	speedLabel.Text = string.format('%.0f <font size="12" color="#7F92A4">km/h</font>', tonumber(snapshot.speedKmh) or 0)
	local boost = tonumber(snapshot.boost) or 0
	boostLabel.Text = string.format("%.2f", boost)
	boostLabel.TextColor3 = boost > 0.02 and COLORS.accent or COLORS.text

	-- Wind
	local windOn = snapshot.windEnabled == true
	local windLevel = math.clamp(tonumber(snapshot.windLevel) or 0, 0, 1)
	if shown.windOn ~= windOn then
		shown.windOn = windOn
		windButton.Text = "WIND  " .. (windOn and "ON" or "OFF")
		styleButton(
			windButton,
			windOn and COLORS.accentBg or COLORS.surface,
			windOn and COLORS.accent or COLORS.muted,
			windOn and COLORS.accentDim or COLORS.line
		)
		windLevelLabel.TextColor3 = windOn and COLORS.text or COLORS.muted
	end
	windLevelLabel.Text = string.format("%.0f%%", windLevel * 100)
	updateWindBar(math.floor(windLevel * WIND_STEPS + 0.5), windOn)

	-- Backfire
	local backfireOn = snapshot.backfireEnabled == true
	if shown.backfireOn ~= backfireOn then
		shown.backfireOn = backfireOn
		backfireButton.Text = "BACKFIRE  " .. (backfireOn and "ON" or "OFF")
		styleButton(
			backfireButton,
			backfireOn and COLORS.orangeBg or COLORS.surface,
			backfireOn and COLORS.orange or COLORS.muted,
			backfireOn and COLORS.orange or COLORS.line
		)
	end

	-- Gearbox whine gain: preset values stay unique; this is a shared multiplier.
	local gearWhineMultiplier = math.clamp(tonumber(snapshot.gearWhineMultiplier) or 1, 0, 3)
	if shown.gearWhineMultiplier ~= gearWhineMultiplier then
		shown.gearWhineMultiplier = gearWhineMultiplier
		if not gearWhineValueBox:IsFocused() then
			gearWhineValueBox.Text = string.format("%.2f", gearWhineMultiplier)
		end
	end
	local presetWhine = math.max(0, tonumber(snapshot.gearWhinePresetLevel) or 0)
	local whineAvailable = snapshot.gearWhineAvailable == true
	gearWhineInfoLabel.Text = whineAvailable
		and string.format("PRESET %.2f×  •  multiplier affects whine-enabled cars", presetWhine)
		or "No gearbox whine on this preset — try Subaru WRC, GT3 Cup or F1"
	gearWhineInfoLabel.TextColor3 = whineAvailable and COLORS.accent or COLORS.muted
	gearWhineUnitLabel.TextColor3 = gearWhineMultiplier > 0 and COLORS.text or COLORS.muted

	-- Audio status pill
	local ready = snapshot.audioReady == true
	if shown.audioReady ~= ready then
		shown.audioReady = ready
		local tint = ready and COLORS.green or COLORS.yellow
		statusText.Text = ready and "AUDIO READY" or "AUDIO OFF"
		tween(statusDot, TWEEN_FAST, { BackgroundColor3 = tint })
		tween(statusText, TWEEN_FAST, { TextColor3 = tint })
		tween(statusPill, TWEEN_FAST, { BackgroundColor3 = ready and COLORS.greenBg or COLORS.yellowBg })
		tween(statusStroke, TWEEN_FAST, { Color = tint })
	end
end

track(snapshotEvent.Event:Connect(applySnapshot))

-- Smooth the tacho between telemetry packets so it visibly follows revs
-- instead of jumping every 0.05 seconds. Only touches the UI when something
-- actually changed.
local lastRpmText = nil
local lastFill = nil
local renderConnection = RunService.RenderStepped:Connect(function(dt)
	local blend = 1 - math.exp(-dt * 14)
	displayedRPM += (targetRPM - displayedRPM) * blend
	if math.abs(targetRPM - displayedRPM) < 1 then
		displayedRPM = targetRPM
	end

	local text = string.format("%04d", math.floor(displayedRPM + 0.5))
	if text ~= lastRpmText then
		lastRpmText = text
		rpmValue.Text = text
	end

	local fraction = displayedRPM / currentRedline
	-- Number warms up to red as it approaches the redline.
	rpmValue.TextColor3 = COLORS.text:Lerp(COLORS.red, math.clamp((fraction - 0.88) / 0.12, 0, 1))

	local fill = math.floor(math.clamp(fraction, 0, 1) * RPM_SEGMENTS + 0.5)
	if fill ~= lastFill then
		lastFill = fill
		for index, segment in ipairs(rpmSegments) do
			segment.BackgroundTransparency = index <= fill and 0 or 0.86
		end
	end
end)

local ok, initialSnapshot = pcall(function()
	return getSnapshot:Invoke()
end)
if ok and initialSnapshot then
	applySnapshot(initialSnapshot)
end

----------------------------------------------------------------------
-- Responsive scaling: shrink the whole dock on small screens
----------------------------------------------------------------------
local function updateLayoutScale()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	local scale = math.min((viewport.X - 24) / DESIGN_W, (viewport.Y * 0.72) / PANEL_H, 1)
	dockScale.Scale = math.max(scale, 0.5)

	-- If the picker would run off the top of the screen, let it overlay the panel instead.
	local fits = (EDGE_MARGIN + PANEL_H + POPUP_GAP + POPUP_H) * dockScale.Scale <= viewport.Y
	popupRestY = fits and -(PANEL_H + POPUP_GAP) or 0
	if popupOpen then
		popup.Position = UDim2.new(0, 0, 1, popupRestY)
	end
end

local viewportConnection = nil
local function hookCamera()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateLayoutScale)
	end
	updateLayoutScale()
end
hookCamera()
track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera))

-- Escape closes the picker (even while the search box is focused).
track(UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Escape and popupOpen then
		setPopupOpen(false)
	end
end))

script.Destroying:Connect(function()
	if renderConnection then
		renderConnection:Disconnect()
	end
	if viewportConnection then
		viewportConnection:Disconnect()
	end
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	if gui then
		gui:Destroy()
	end
end)
