-- Builds the exact parameter shape expected by the original engine worklet.
-- This is a config/adapter module; it does not yet run the audio DSP or physics.

local EngineFiring = require(script.Parent:WaitForChild("EngineFiring"))
local GearboxConfig = require(script.Parent:WaitForChild("GearboxConfig"))

local EngineConfig = {}

EngineConfig.DefaultSound = {
	pops = 0.5,
	popRate = 1,
	popSub = 4,
	popSpread = 10,
	popCrack = 1,
	popThump = 1,
	popBang = 0,
	popPitch = 1,
	popBright = 1,
	popWhump = 0.1,
	popTone = 0,
	induction = "na",
	boost = 0.8,
	whine = 0.3,
	whinePitch = 1,
	lag = 0.6,
	bov = "vent",
	flRate = 14,
	flPitch = 650,
	flPitchEnd = 130,
	flDur = 1.2,
	flHiss = 0.6,
	flLevel = 0.5,
	mguk = 0,
	gearWhine = 0,
	gearWhineOrder = 11,
	gearWhineOrderIn = 23,
	gearWhineIn = 0.3,
	idleRough = 1,
	camOverlap = 0,
	chamberGain = 0.5,
	bankBalance = 0,
	blowdownSharp = 0,
}

local function mergeInto(destination, source)
	if source then
		for key, value in pairs(source) do
			destination[key] = value
		end
	end
	return destination
end

function EngineConfig.BuildWorkletParams(preset, runtimeSoundOverrides, audioSettings)
	assert(type(preset) == "table", "BuildWorkletParams expects an engine preset")
	assert(type(preset.gears) == "table" and #preset.gears > 0, "Preset must include gear ratios")

	local source = table.clone(preset)
	source.layout = source.layout or "inline"
	source.crank = source.crank or "even"
	if source.cylinders > 1 and source.layout ~= "inline" and source.cylinders % 2 == 1 and source.crank ~= "even" then
		source.crank = "even"
	end

	local sound = table.clone(EngineConfig.DefaultSound)
	mergeInto(sound, preset.sound)
	mergeInto(sound, runtimeSoundOverrides)

	local driveline = GearboxConfig.GetDrivelineParams(source)
	local settings = audioSettings or {}
	local openAir = source.openAir == true

	local params = {
		firing = EngineFiring.Generate(source),
		banks = source.layout == "inline" and 1 or 2,
		cycle = EngineFiring.GetCycle(source),
		redline = source.redline,
		limiter = source.limiter or "bang",
		limCut = source.limCut ~= nil and source.limCut or 0.06,
		idleRpm = source.idleRpm,
		peakTorque = source.peakTorque,
		inertia = source.inertia,
		headerLength = source.headerLength,
		collectorLength = source.collectorLength,
		tailLength = source.tailLength,
		muffler = source.muffler,
		valve = source.valve or "open",
		valveRpm = source.valveRpm or 3500,
		valveCold = source.valveCold or 0,
		chamber = source.chamber,
		intakeLength = source.intakeLength,
		gears = table.clone(source.gears),
		finalDrive = source.finalDrive,
		mass = source.mass,
		wheelRadius = source.wheelRadius,
		grip = source.grip,
		brakeG = source.brakeG ~= nil and source.brakeG or (0.9 * source.grip),
		vtecRpm = source.vtec or 0,
		twoStep = source.twoStep == true,
		drag = source.drag,
		downforce = source.downforce or 0,
		mic = settings.mic ~= nil and settings.mic or 0.3,
		body = settings.body ~= nil and settings.body or 2.5,
		room = settings.room ~= nil and settings.room or 0.4,
		tunnel = settings.tunnel == true,
		scene = "none",
		tractionControl = settings.tractionControl ~= false,
		master = settings.master ~= nil and settings.master or 1,
		clip = settings.clip ~= nil and settings.clip or 0.15,
		cabin = openAir and 0 or (settings.cabin ~= nil and settings.cabin or 0.5),
		wind = (settings.wind ~= nil and settings.wind or 1) * (sound.wind ~= nil and sound.wind or 1),
		openAir = openAir,
	}

	for key, value in pairs(driveline) do
		params[key] = value
	end
	for key, value in pairs(sound) do
		params[key] = value
	end

	params.wind = (settings.wind ~= nil and settings.wind or 1) * (sound.wind ~= nil and sound.wind or 1)
	params.gearboxInfo = GearboxConfig.GetShiftInfo(source)
	params.name = source.name
	return params
end

return EngineConfig
