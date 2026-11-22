-- EngineSimulation.lua
-- Roblox/Luau engine-state port based on the supplied keir.is/revving worklet.
-- This is the mechanical/control-rate layer. Audio-rate cylinder pressure and
-- sample synthesis are handled separately by SoundSynthesis.lua.

local GearboxSimulation = require(script.Parent:WaitForChild("GearboxSimulation"))

local EngineSimulation = {}
EngineSimulation.__index = EngineSimulation

local PI = math.pi
local TAU = 2 * PI
local MAX_SUBSTEP = 1 / 600

local function clamp(x: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, x))
end

local function finiteNumber(value: any, fallback: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

local function expAlpha(dt: number, seconds: number): number
	return 1 - math.exp(-dt / math.max(0.0001, seconds))
end

function EngineSimulation.new(params)
	assert(type(params) == "table", "EngineSimulation.new expects EngineConfig.BuildWorkletParams output")
	assert(type(params.firing) == "table" and #params.firing > 0, "Engine params are missing firing events")
	assert(type(params.gears) == "table" and #params.gears > 0, "Engine params are missing gear ratios")
	assert(params.redline and params.idleRpm and params.peakTorque and params.inertia, "Engine params are missing core values")

	-- Fail early with a useful message if Studio has an older/different
	-- GearboxSimulation ModuleScript than this EngineSimulation expects.
	local gearbox = GearboxSimulation.new(params)
	assert(type(gearbox) == "table", "GearboxSimulation.new must return a table")
	assert(type(gearbox.GetState) == "function",
		"VehicleAudio module mismatch: replace the ENTIRE GearboxSimulation ModuleScript with the matching Milestone 2 file. It must define :GetState().")
	assert(type(gearbox.Step) == "function",
		"VehicleAudio module mismatch: GearboxSimulation is missing :Step(). Replace the entire ModuleScript with the matching Milestone 2 file.")
	assert(type(gearbox.RequestGear) == "function",
		"VehicleAudio module mismatch: GearboxSimulation is missing :RequestGear(). Replace the entire ModuleScript with the matching Milestone 2 file.")

	local self = setmetatable({
		params = params,
		gearbox = gearbox,
		controls = {
			throttle = 0,
			clutch = 1, -- 1 = clutch engaged / pedal released; 0 = pedal fully pressed
			brake = 0,
			gear = 0,
			ignition = false,
			starter = false,
			launch = 0,
		},
		omega = 0, -- crankshaft rad/s
		crankDegrees = 0, -- unwrapped crank angle; state reports angle within cycle
		throttleS = 0,
		throttlePrev = 0,
		crankTime = 0,
		aliveFor = 0,
		wasAlive = false,
		running = false,
		cut = false,
		cutTime = 0,
		cutBurst = 0,
		liftTime = 0,
		popCluster = 0,
		boost = 0,
		turbo = 0,
		combustionCharge = 1,
		afterglow = 0,
		valveOpen = true,
		valveCold = 0,
		hiCam = false,
		idleControlIntegral = 0,
		firedMask = 0,
		lastFired = {},
		state = {
			load = 0,
			engineTorque = 0,
			netTorque = 0,
			engineDrag = 0,
		},
	}, EngineSimulation)

	self.state = self:GetState()
	return self
end

function EngineSimulation:SetControls(controls)
	if type(controls) ~= "table" then
		return
	end

	for key, value in pairs(controls) do
		if key == "throttle" or key == "clutch" or key == "brake" then
			self.controls[key] = clamp(finiteNumber(value, self.controls[key]), 0, 1)
		elseif key == "gear" then
			local gear = math.floor(clamp(finiteNumber(value, self.controls.gear), 0, #self.params.gears))
			if gear ~= self.gearbox.requestedGear then
				self:RequestGear(gear)
			end
		elseif key == "launch" then
			self.controls.launch = math.max(0, finiteNumber(value, self.controls.launch))
		elseif key == "ignition" or key == "starter" then
			self.controls[key] = value == true
		end
	end
end

function EngineSimulation:RequestGear(gear)
	gear = math.floor(clamp(finiteNumber(gear, 0), 0, #self.params.gears))
	self.controls.gear = gear
	return self.gearbox:RequestGear(gear)
end

function EngineSimulation:GetState()
	local p = self.params
	local gearboxState = self.gearbox:GetState()
	local rpm = math.max(0, self.omega * 60 / TAU)
	local cycle = p.cycle or 720

	return {
		rpm = rpm,
		omega = self.omega,
		speed = gearboxState.speed, -- SI m/s; convert Roblox studs/s in your chassis adapter
		crankAngle = self.crankDegrees % cycle,
		cycle = cycle,
		throttle = self.throttleS,
		requestedThrottle = self.controls.throttle,
		clutch = gearboxState.clutch,
		gear = gearboxState.gear,
		requestedGear = gearboxState.requestedGear,
		load = self.state.load or 0,
		liftTime = self.liftTime,
		cutBurst = self.cutBurst,
		running = self.running,
		ignition = self.controls.ignition,
		starter = self.controls.starter,
		cut = self.cut,
		firedMask = self.firedMask,
		fired = self.lastFired,
		boost = self.boost,
		turbo = self.turbo,
		shaftTorque = gearboxState.shaftTorque,
		twist = gearboxState.twist,
		slip = self.omega - gearboxState.omegaIn,
		omegaIn = gearboxState.omegaIn,
		wheelspin = gearboxState.wheelspin,
		tractionLimit = gearboxState.tractionLimit,
		shifting = gearboxState.shifting,
		engaging = gearboxState.engaging,
		locked = gearboxState.locked,
		valveOpen = self.valveOpen,
		hiCam = self.hiCam,
		engineTorque = self.state.engineTorque or 0,
		netTorque = self.state.netTorque or 0,
		engineDrag = self.state.engineDrag or 0,
		paramsName = p.name,
	}
end

function EngineSimulation:_StepOne(dt)
	local p = self.params
	local c = self.controls
	local rpm = math.max(0, self.omega) * 60 / TAU
	local rpmFraction = rpm / math.max(1, p.redline)

	-- Automatic shift assistance.
	-- Cut throttle while changing gears, then smoothly restore it
	-- as the clutch re-engages.

	local shiftThrottleScale = 1

	-- Only apply automatic assistance when the player is not
	-- manually pressing the clutch.
	if c.clutch >= 0.99 then
		if self.gearbox.shiftRemaining > 0 then
			shiftThrottleScale = 0

		elseif self.gearbox.engageRemaining > 0 then
			local engageTime = math.max(0.001, self.gearbox.engageTime)

			local progress = clamp(
				1 - self.gearbox.engageRemaining / engageTime,
				0,
				1
			)

			-- Smoothstep throttle restoration.
			shiftThrottleScale = progress * progress * (3 - 2 * progress)
		end
	end

	local throttleTarget = c.throttle * shiftThrottleScale

	local throttleTau = throttleTarget < self.throttleS
		and 0.012
		or 0.05

	self.throttleS +=
		(throttleTarget - self.throttleS) * expAlpha(dt, throttleTau)

	if rpm < 50 then
		self.crankTime = 0
	elseif not self.running then
		self.crankTime += dt
	end

	local ignitionReady = c.ignition and rpm > 250 and self.crankTime > 0.3
	if ignitionReady then
		self.afterglow = 0.35
	elseif self.afterglow > 0 then
		self.afterglow = math.max(0, self.afterglow - dt)
	end
	local afterglowActive = not ignitionReady and self.afterglow > 0 and rpm > 250

	local wasRunning = self.running
	self.running = ignitionReady and rpm > math.max(0.45 * p.idleRpm, 350)
	if self.running and not wasRunning then
		self.valveCold = p.valveCold or 0
	end
	self.valveCold = math.max(0, self.valveCold - dt)

	if p.valve == "open" then
		self.valveOpen = true
	elseif p.valve == "closed" then
		self.valveOpen = false
	elseif self.valveCold > 0 then
		self.valveOpen = true
	elseif rpm > (p.valveRpm or 3500) then
		self.valveOpen = true
	elseif rpm < (p.valveRpm or 3500) - 500 then
		self.valveOpen = false
	end

	local launchActive = c.launch > 0
	local limitRpm = launchActive and math.min(c.launch, p.redline) or p.redline
	local clutchAtStart = self.gearbox.clutch or 1
	local limiterMode = launchActive and (clutchAtStart < 0.1 and "bang" or "hold") or (p.limiter or "bang")
	local limiterRange = launchActive and limitRpm * 0.12 or math.max(150, limitRpm * 0.025)
	local limiterBlend = 0

	if limiterMode == "bang" then
		if rpm > limitRpm then
			if not self.cut then
				self.cutTime = 0
			end
			self.cut = true
		elseif self.cut then
			self.cutTime += dt
			if self.cutTime >= (p.limCut or 0.06)
				and rpm < limitRpm - math.max(30, limitRpm * 0.005) then
				self.cut = false
			end
		end
		limiterBlend = self.cut and 1 or 0
	else
		limiterBlend = clamp((rpm - (limitRpm - limiterRange)) / math.max(1, limiterRange), 0, 1)
		self.cut = limiterBlend > 0.3
	end

	local engineOverrun = self.throttleS < 0.03 and rpm > p.idleRpm * 1.4
	if self.throttleS > 0.1 then
		self.liftTime = 0
	else
		self.liftTime += dt
	end
	if self.throttlePrev > 0.3 and c.throttle < 0.05 and rpm > p.idleRpm * 1.6 then
		self.cutBurst = 1
	end
	self.throttlePrev += (c.throttle - self.throttlePrev) * math.min(1, dt / 0.08)
	self.cutBurst *= math.max(0, 1 - dt / 0.22)
	self.popCluster *= math.max(0, 1 - dt / 0.18)

	-- Rotary engines use the reference's separate idle-speed integral term.
	if (p.cycle or 720) > 720 then
		local integralTarget = clamp(1.5 * (p.idleRpm - rpm) / math.max(1, p.idleRpm), -0.08, 0.3)
		self.idleControlIntegral += (integralTarget - self.idleControlIntegral) * math.min(1, dt / 0.22)
	else
		self.idleControlIntegral = 0
	end

	local idleAir = (p.cycle or 720) > 720
		and (0.4 * (p.idleRpm - rpm) / math.max(1, p.idleRpm) + self.idleControlIntegral + 0.06)
		or (1.3 * (p.idleRpm - rpm) / math.max(1, p.idleRpm) + 0.06)
	idleAir = clamp(idleAir, 0, 0.4)

	local earlyStart = ignitionReady and self.aliveFor < 0.5
	if ignitionReady then
		self.aliveFor += dt
	else
		self.aliveFor = 0
	end

	local chargeTarget = (engineOverrun or afterglowActive) and 0 or 1
	local chargeTau = engineOverrun and (afterglowActive and 0.3 or 0.1) or (earlyStart and 0.35 or 0.05)
	if ignitionReady and not self.wasAlive then
		self.combustionCharge = math.min(self.combustionCharge, 0.15)
	end
	self.combustionCharge += (chargeTarget - self.combustionCharge) * math.min(1, dt / chargeTau)
	self.wasAlive = ignitionReady

	local tractionLimitedThrottle = self.throttleS
	if p.tractionControl then
		tractionLimitedThrottle = math.min(tractionLimitedThrottle, self.gearbox.tcMaxLoad or 1)
	end

	-- Worklet only adds idle air while ignition/afterglow is able to fire and the limiter allows it.
	local firingWindow = (ignitionReady or afterglowActive) and rpm < limitRpm + limiterRange
	local load
	if firingWindow then
		load = math.min(math.max(tractionLimitedThrottle, idleAir), 1 - limiterBlend)
	else
		load = tractionLimitedThrottle
	end
	load = clamp(load, 0, 1)

	-- Source supercharger/turbo spool and boost response.
	if p.induction == "super" then
		self.boost = (p.boost or 0) * math.min(1.1, 0.45 + 1.1 * rpmFraction) * load
		self.turbo = 0
	elseif p.induction == "turbo" then
		local targetSpool = clamp(load * (2.2 * math.max(0, rpmFraction)) ^ 1.2, 0, 1)
		local lag = math.max(0.05, p.lag or 0.6)
		local spoolTau = targetSpool > self.turbo and lag or lag * 2.5
		self.turbo += (targetSpool - self.turbo) * expAlpha(dt, spoolTau)
		local targetBoost = (p.boost or 0) * self.turbo * clamp(load * 3, 0, 1)
		local boostTau = targetBoost > self.boost and 0.08 or 0.03
		self.boost += (targetBoost - self.boost) * expAlpha(dt, boostTau)
	else
		self.boost = 0
		self.turbo = 0
	end

	if (p.vtecRpm or 0) > 0 then
		if not self.hiCam and rpm > p.vtecRpm and self.throttleS > 0.35 then
			self.hiCam = true
		elseif self.hiCam and (rpm < p.vtecRpm - 250 or self.throttleS < 0.15) then
			self.hiCam = false
		end
	else
		self.hiCam = false
	end

	local torqueEnvelope = 0.5 + 0.5 * math.sin(PI * clamp((rpmFraction - 0.1) / 0.9, 0, 1))
	if (p.vtecRpm or 0) > 0 then
		torqueEnvelope *= self.hiCam and 1.12 or 0.94
	end

	local fireEnabled = firingWindow and (not (engineOverrun or afterglowActive) or self.combustionCharge > 0.03)
	local chargeFactor = (engineOverrun or afterglowActive or earlyStart) and self.combustionCharge or 1
	local combustionTorque = 0
	if fireEnabled and not self.cut then
		combustionTorque = load ^ 0.8 * torqueEnvelope * p.peakTorque
			* (1 + 0.9 * self.boost) * chargeFactor
	end

	-- Crankshaft friction and starter torque follow the reference parameterisation.
	local engineDrag = p.peakTorque * (0.05 + 0.1 * rpmFraction
		+ 0.12 * rpmFraction * rpmFraction * (1 - load))
	if not ignitionReady and not c.starter and rpm < 250 then
		engineDrag *= 0.12 + 0.88 * (rpm / 250)
	end

	local starterTorque = 0
	if c.starter then
		starterTorque = math.max(p.peakTorque * 0.4, p.inertia * 80) * math.max(0, 1 - rpm / 350)
	end

	local netTorque = combustionTorque - engineDrag + starterTorque
	if not self.running and not c.starter then
		netTorque = -engineDrag
	end

	-- Mechanical coupling and wheel speed are integrated by GearboxSimulation.
	local inductionTorqueScale = p.induction == "na" and 1 or (1 + 0.9 * self.boost)
	local maxEngineTorque = p.peakTorque * inductionTorqueScale
	self.omega = self.gearbox:Step(
		self.omega,
		netTorque,
		c,
		dt,
		maxEngineTorque,
		torqueEnvelope * maxEngineTorque,
		engineDrag
	)
	self.omega = math.max(0, self.omega)

	local newRpm = self.omega * 60 / TAU
	local oldCrank = self.crankDegrees
	self.crankDegrees += newRpm * 6 * dt

	-- Report firing events for telemetry. SoundSynthesis independently uses the same firing angles.
	local cycle = p.cycle or 720
	local fired = {}
	for index, event in ipairs(p.firing) do
		local angle = event.angle or 0
		local oldCycle = math.floor((oldCrank - angle) / cycle)
		local newCycle = math.floor((self.crankDegrees - angle) / cycle)
		if newCycle > oldCycle then
			table.insert(fired, event)
			local cylinderIndex = clamp((event.cyl or (index - 1)) + 1, 1, 16)
			self.firedMask = bit32.bor(self.firedMask, bit32.lshift(1, cylinderIndex - 1))
		end
	end
	self.lastFired = fired

	self.state = {
		load = load,
		engineTorque = combustionTorque,
		netTorque = netTorque,
		engineDrag = engineDrag,
		rpm = newRpm,
		speed = self.gearbox.speed,
		boost = self.boost,
		turbo = self.turbo,
		running = self.running,
		cut = self.cut,
		fired = fired,
		firedMask = self.firedMask,
	}
end

function EngineSimulation:Step(dt, controls)
	if controls then
		self:SetControls(controls)
	end
	dt = clamp(finiteNumber(dt, 0), 0, 0.1)
	if dt <= 0 then
		return self:GetState()
	end

	self.firedMask = 0
	self.lastFired = {}
	local firedThisFrame = {}
	local steps = math.max(1, math.ceil(dt / MAX_SUBSTEP))
	local subDt = dt / steps
	for _ = 1, steps do
		self:_StepOne(subDt)
		-- Preserve every firing event crossed during this Heartbeat, rather
		-- than returning only events from the final 1/600-second substep.
		for _, event in ipairs(self.lastFired) do
			table.insert(firedThisFrame, event)
		end
	end
	self.lastFired = firedThisFrame
	self.state = self.state or {}
	return self:GetState()
end

function EngineSimulation:Stop()
	self.controls.ignition = false
	self.controls.starter = false
	self.controls.throttle = 0
end

return EngineSimulation
