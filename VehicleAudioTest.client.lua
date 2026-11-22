-- VehicleAudioTest.client.lua
-- Local Studio test rig for procedural vehicle audio.
-- Put this LocalScript in StarterPlayer > StarterPlayerScripts.
-- Pairs with VehicleAudioUI.client.lua in the same folder.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerScripts = player:WaitForChild("PlayerScripts")
local vehicleAudio = ReplicatedStorage:WaitForChild("VehicleAudio")

local EnginePresets = require(vehicleAudio:WaitForChild("EnginePresets"))
local EngineConfig = require(vehicleAudio:WaitForChild("EngineConfig"))
local EngineSimulation = require(vehicleAudio:WaitForChild("EngineSimulation"))
local SoundSynthesis = require(vehicleAudio:WaitForChild("SoundSynthesis"))
local AudioOutput = require(vehicleAudio:WaitForChild("AudioOutput"))

local function requireMethod(moduleValue, moduleName, methodName)
	if type(moduleValue) ~= "table" or type(moduleValue[methodName]) ~= "function" then
		error(string.format(
			"[VehicleAudio] API mismatch: %s must expose %s(). Check that the matching ModuleScript version is installed.",
			moduleName,
			methodName
			), 0)
	end
end

requireMethod(EnginePresets, "EnginePresets", "GetAll")
requireMethod(EnginePresets, "EnginePresets", "GetByName")
requireMethod(EngineConfig, "EngineConfig", "BuildWorkletParams")
requireMethod(EngineSimulation, "EngineSimulation", "new")
requireMethod(SoundSynthesis, "SoundSynthesis", "new")
requireMethod(AudioOutput, "AudioOutput", "Start")

local function getCamera()
	while not workspace.CurrentCamera do
		workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
	end
	return workspace.CurrentCamera
end

local camera = getCamera()
local presets = EnginePresets.GetAll(false)
assert(#presets > 0, "No visible engine presets were returned")

local presetNames = table.create(#presets)
local supraIndex = 1
for index, preset in ipairs(presets) do
	presetNames[index] = preset.name
	if preset.name == "Toyota Supra MkIV (2JZ-GTE)" then
		supraIndex = index
	end
end

-- User-facing sound controls. Wind is enabled at a reduced level by default;
-- backfire is disabled by default until its sound design is improved.
local windEnabled = true
local windLevel = 0.30 -- 0..1 multiplier of the selected preset's wind amount
local backfireEnabled = false

local currentIndex = supraIndex
local preset = nil
local params = nil
local baseWind = 1
local basePops = 0
local engine = nil
local synth = nil
local audioHandle = nil
local gear = 0
local throttleHeld = false
local brakeHeld = false
local clutchHeld = false
local shiftAssistActive = false
local alive = true
local printAccumulator = 0
local uiAccumulator = 0
local heartbeatConnection = nil

-- Local-only bridge between this test rig and the separate UI LocalScript.
local previousBridge = playerScripts:FindFirstChild("VehicleAudioLabBridge")
if previousBridge then
	previousBridge:Destroy()
end

local bridge = Instance.new("Folder")
bridge.Name = "VehicleAudioLabBridge"
bridge.Parent = playerScripts

local commandEvent = Instance.new("BindableEvent")
commandEvent.Name = "Command"
commandEvent.Parent = bridge

local snapshotEvent = Instance.new("BindableEvent")
snapshotEvent.Name = "Snapshot"
snapshotEvent.Parent = bridge

local getSnapshot = Instance.new("BindableFunction")
getSnapshot.Name = "GetSnapshot"
getSnapshot.Parent = bridge

local function applySoundOptions()
	if not params then
		return
	end
	params.wind = windEnabled and (baseWind * windLevel) or 0
	params.pops = backfireEnabled and basePops or 0
end

local function makeParams(selectedPreset)
	local built = EngineConfig.BuildWorkletParams(selectedPreset, nil, {
		mic = 0.35,
		body = 1.35,
		room = 0.08,
		cabin = 0.12,
		wind = 1,
		master = 0.8,
		clip = 0.15,
		tractionControl = true,
	})

	local originalWind = type(built.wind) == "number" and built.wind or 1
	local originalPops = type(built.pops) == "number" and built.pops or 0
	return built, originalWind, originalPops
end

local function publishSnapshot(state)
	if not alive or not engine or not params or not preset then
		return
	end

	local rpm = state and state.rpm or 0
	local snapshot = {
		engineName = preset.name,
		engineIndex = currentIndex,
		engineCount = #presets,
		engineNames = presetNames,
		rpm = rpm,
		redline = params.redline or preset.redline or 7000,
		gear = state and state.gear or 0,
		speedKmh = (state and state.speed or 0) * 3.6,
		boost = state and state.boost or 0,
		running = state and state.running == true or false,
		shifting = state and state.shifting == true or false,
		engaging = state and state.engaging == true or false,
		windEnabled = windEnabled,
		windLevel = windLevel,
		backfireEnabled = backfireEnabled,
		audioReady = audioHandle ~= nil and audioHandle.running == true,
	}

	getSnapshot.OnInvoke = function()
		return snapshot
	end
	snapshotEvent:Fire(snapshot)
end

local function startAudioIfNeeded()
	if audioHandle then
		return
	end
	local output, outputError = AudioOutput.Start(synth, camera, {
		listenerParent = camera,
		emitterName = "VehicleAudioTestEmitter",
	})
	if output then
		audioHandle = output
		print("[VehicleAudio] Procedural audio writer connected.")
	else
		warn("[VehicleAudio] Audio output unavailable: " .. tostring(outputError))
		warn("[VehicleAudio] Simulation and UI will still run without audible output.")
	end
end

local function selectEngine(index)
	index = math.floor(tonumber(index) or currentIndex)
	if index < 1 or index > #presets then
		return false
	end

	local selectedPreset = presets[index]
	local newParams, newBaseWind, newBasePops = makeParams(selectedPreset)
	newParams.wind = windEnabled and (newBaseWind * windLevel) or 0
	newParams.pops = backfireEnabled and newBasePops or 0

	local newEngine = EngineSimulation.new(newParams)
	local newSynth = SoundSynthesis.new(newParams, 48000)

	-- Swap the simulation and synthesizer while retaining the existing audio graph.
	preset = selectedPreset
	params = newParams
	baseWind = newBaseWind
	basePops = newBasePops
	engine = newEngine
	synth = newSynth
	currentIndex = index
	gear = 0
	throttleHeld = false
	brakeHeld = false
	clutchHeld = false
	shiftAssistActive = false

	if audioHandle and audioHandle.running then
		audioHandle.synth = synth
	else
		audioHandle = nil
		startAudioIfNeeded()
	end

	print(string.format("[VehicleAudio] Engine selected: %s (%d/%d)", preset.name, currentIndex, #presets))
	publishSnapshot(engine:GetState())
	return true
end

local function setControl(key, value)
	if engine then
		engine:SetControls({ [key] = value })
	end
end

local function setGear(newGear)
	if not engine then
		return
	end
	newGear = math.clamp(math.floor(newGear), 0, #params.gears)
	if newGear == gear then
		return
	end

	-- Light throttle lift during a shift. Keep the requested pedal state so
	-- throttle returns only if the player is still holding W afterwards.
	local autoAssist = not clutchHeld and (engine.controls.clutch or 1) >= 0.99
	local accepted = engine:RequestGear(newGear)
	if accepted and autoAssist then
		shiftAssistActive = true
		setControl("throttle", 0)
	end

	gear = newGear
	print(string.format("[VehicleAudio] Gear requested: %s", gear == 0 and "N" or tostring(gear)))
end

local function changeGear(delta)
	setGear(gear + delta)
end

local function refreshSoundSettings()
	applySoundOptions()
	publishSnapshot(engine and engine:GetState() or nil)
end

commandEvent.Event:Connect(function(action, value)
	if not alive then
		return
	end

	if action == "SelectEngine" then
		selectEngine(value)
	elseif action == "SetWindEnabled" then
		windEnabled = value == true
		refreshSoundSettings()
	elseif action == "SetWindLevel" then
		windLevel = math.clamp(tonumber(value) or windLevel, 0, 1)
		refreshSoundSettings()
	elseif action == "SetBackfireEnabled" then
		backfireEnabled = value == true
		refreshSoundSettings()
	end
end)

-- Initial engine is the Supra MkIV 2JZ-GTE.
selectEngine(currentIndex)
publishSnapshot(engine:GetState())

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not alive or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local key = input.KeyCode
	if key == Enum.KeyCode.W then
		throttleHeld = true
		setControl("throttle", shiftAssistActive and 0 or 1)
	elseif key == Enum.KeyCode.S then
		brakeHeld = true
		setControl("brake", 1)
	elseif key == Enum.KeyCode.Space then
		clutchHeld = true
		shiftAssistActive = false
		setControl("clutch", 0)
	elseif key == Enum.KeyCode.E then
		changeGear(1)
	elseif key == Enum.KeyCode.Q then
		changeGear(-1)
	elseif key == Enum.KeyCode.Zero or key == Enum.KeyCode.KeypadZero then
		setGear(0)
	elseif key == Enum.KeyCode.Return then
		engine:SetControls({ ignition = true, starter = true })
		print("[VehicleAudio] Ignition on; hold Enter briefly to crank, then release.")
	elseif key == Enum.KeyCode.I then
		local current = engine.controls.ignition
		setControl("ignition", not current)
		print("[VehicleAudio] Ignition: " .. tostring(not current))
	elseif key == Enum.KeyCode.X then
		engine:Stop()
		setControl("brake", 0)
		print("[VehicleAudio] Engine shutdown requested")
	elseif key == Enum.KeyCode.One then
		setGear(1)
	elseif key == Enum.KeyCode.Two then
		setGear(2)
	elseif key == Enum.KeyCode.Three then
		setGear(3)
	elseif key == Enum.KeyCode.Four then
		setGear(4)
	elseif key == Enum.KeyCode.Five then
		setGear(5)
	elseif key == Enum.KeyCode.Six then
		setGear(6)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not alive or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local key = input.KeyCode
	if key == Enum.KeyCode.W then
		throttleHeld = false
		setControl("throttle", 0)
	elseif key == Enum.KeyCode.S then
		brakeHeld = false
		setControl("brake", 0)
	elseif key == Enum.KeyCode.Space then
		clutchHeld = false
		setControl("clutch", 1)
	elseif key == Enum.KeyCode.Return then
		setControl("starter", false)
	end
end)

UserInputService.WindowFocusReleased:Connect(function()
	if not alive then
		return
	end
	throttleHeld = false
	brakeHeld = false
	clutchHeld = false
	shiftAssistActive = false
	engine:SetControls({ throttle = 0, brake = 0, clutch = 1, starter = false })
end)

print("[VehicleAudio] Test rig ready: " .. preset.name)
print("[VehicleAudio] ENTER=crank | I=ignition | W=throttle | S=brake")
print("[VehicleAudio] E/Q=gear up/down | 1-6=select gear | 0=neutral | SPACE=manual clutch | X=shutdown")
print("[VehicleAudio] Use the on-screen panel to select engines and control wind/backfire.")

heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
	if not alive or not engine then
		return
	end

	-- Restore throttle only after the gear change and clutch engagement finish.
	if shiftAssistActive then
		local gearbox = engine.gearbox
		if gearbox.shiftRemaining <= 0 and gearbox.engageRemaining <= 0 then
			shiftAssistActive = false
			setControl("throttle", throttleHeld and 1 or 0)
		end
	end

	local state = engine:Step(dt)
	if audioHandle then
		audioHandle:WriteForDelta(state, dt)
	end

	printAccumulator += dt
	if printAccumulator >= 1 then
		printAccumulator -= 1
		print(string.format(
			"[VehicleAudio] %s | RPM=%d | Speed=%.1f km/h | Gear=%s | Throttle=%.2f | Boost=%.2f | Running=%s",
			preset.name,
			state.rpm,
			state.speed * 3.6,
			state.gear == 0 and "N" or tostring(state.gear),
			state.throttle,
			state.boost,
			tostring(state.running)
			))
	end

	uiAccumulator += dt
	if uiAccumulator >= 0.05 then
		uiAccumulator = 0
		publishSnapshot(state)
	end
end)

script.Destroying:Connect(function()
	alive = false
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end
	if audioHandle then
		local stats = audioHandle:GetStats()
		print(string.format(
			"[VehicleAudio] Audio stats: %d blocks, %d frames, %d dropped frames",
			stats.blocksWritten,
			stats.framesWritten,
			stats.framesDropped
			))
		audioHandle:Stop()
	end
	if bridge and bridge.Parent then
		bridge:Destroy()
	end
end)
