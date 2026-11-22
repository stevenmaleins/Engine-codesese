-- Exact gearbox timing and driveline defaults extracted from the source module.
-- This is configuration support, not the dynamic gearbox simulation yet.

local GearboxConfig = {}

GearboxConfig.Types = {
	manual = {
		label = "manual",
		shift = 0.22,
		engage = 0.60,
		stiffness = 13,
		lash = 2.5,
		damping = 0.14,
	},
	dct = {
		label = "dual clutch",
		shift = 0.08,
		engage = 0.12,
		stiffness = 14,
		lash = 1.2,
		damping = 0.30,
	},
	auto = {
		label = "automatic",
		shift = 0.12,
		engage = 0.20,
		stiffness = 12,
		lash = 1,
		damping = 0.60,
	},
	seq = {
		label = "sequential",
		shift = 0.05,
		engage = 0.06,
		stiffness = 20,
		lash = 3,
		damping = 0.12,
	},
	cvt = {
		label = "cvt",
		shift = 0,
		engage = 0.30,
		stiffness = 12,
		lash = 1,
		damping = 0.60,
	},
	direct = {
		label = "direct drive",
		shift = 0,
		engage = 3,
		stiffness = 60,
		lash = 0,
		damping = 0.50,
	},
}

local function gearboxType(preset)
	local kind = preset.gearbox or "manual"
	local settings = GearboxConfig.Types[kind]
	assert(settings, string.format("Unknown gearbox type '%s'", tostring(kind)))
	return kind, settings
end

function GearboxConfig.GetShiftInfo(preset)
	local _, settings = gearboxType(preset)
	local gears = preset.gears or {}
	return {
		shift = preset.shiftTime ~= nil and preset.shiftTime or settings.shift,
		engage = preset.engageTime ~= nil and preset.engageTime or settings.engage,
		label = string.format("%d-spd %s", #gears, settings.label),
	}
end

function GearboxConfig.GetDrivelineParams(preset)
	local _, settings = gearboxType(preset)
	local custom = preset.driveline or {}
	return {
		dlStiffness = custom.stiffness ~= nil and custom.stiffness or settings.stiffness,
		dlLash = custom.lash ~= nil and custom.lash or settings.lash,
		dlDamping = custom.damping ~= nil and custom.damping or settings.damping,
	}
end

function GearboxConfig.GetType(presetOrName)
	local kind = type(presetOrName) == "table" and (presetOrName.gearbox or "manual") or presetOrName
	local settings = GearboxConfig.Types[kind or "manual"]
	if not settings then
		return nil
	end
	return table.clone(settings)
end

return GearboxConfig
