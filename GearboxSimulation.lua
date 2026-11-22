-- GearboxSimulation.lua
-- Luau port of the reference worklet's clutch / torsional driveline / wheel coupling.
-- Units: angular speed rad/s, torque N*m, speed studs are NOT used here: SI m/s, kg, m.

local GearboxSimulation = {}
GearboxSimulation.__index = GearboxSimulation
GearboxSimulation.API_VERSION = 2

local PI = math.pi
local G = 9.81

local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end

local function approach(current, target, alpha)
	return current + (target - current) * clamp(alpha, 0, 1)
end

local function tanh(x)
	if x > 10 then return 1 end
	if x < -10 then return -1 end
	local e = math.exp(2 * x)
	return (e - 1) / (e + 1)
end

local function finiteNumber(value, fallback)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

function GearboxSimulation.new(params)
	assert(type(params) == "table", "GearboxSimulation.new expects EngineConfig parameters")
	assert(type(params.gears) == "table" and #params.gears > 0, "Gearbox requires at least one forward ratio")

	local info = params.gearboxInfo or {}
	return setmetatable({
		params = params,
		gear = 0,                 -- 0 = neutral; 1..N = forward gears
		requestedGear = 0,
		pendingGear = nil,
		shiftRemaining = 0,
		engageRemaining = 0,
		clutch = 1,
		omegaIn = 0,
		speed = 0,
		twist = 0,
		shaftTorque = 0,
		lastRatio = 0,
		locked = false,
		tyreSlid = false,
		tcMaxLoad = 1,
		shiftTime = finiteNumber(info.shift, 0.22),
		engageTime = finiteNumber(info.engage, 0.60),
		state = {},
	}, GearboxSimulation)
end

function GearboxSimulation:RequestGear(gear)
	local maxGear = #self.params.gears
	gear = math.floor(clamp(finiteNumber(gear, 0), 0, maxGear))
	if gear == self.requestedGear then
		return false
	end

	self.requestedGear = gear
	self.pendingGear = gear
	self.locked = false

	-- Match the source's gearbox-specific shift and engagement timing.
	self.shiftRemaining = math.max(0, self.shiftTime)
	if self.shiftRemaining <= 0 then
		self.gear = gear
		self.pendingGear = nil
		self.engageRemaining = math.max(0, self.engageTime)
	else
		self.gear = 0
	end
	return true
end

function GearboxSimulation:GetState()
	return {
		gear = self.gear,
		requestedGear = self.requestedGear,
		clutch = self.clutch,
		speed = self.speed,
		omegaIn = self.omegaIn,
		shaftTorque = self.shaftTorque,
		twist = self.twist,
		wheelspin = self.tyreSlid,
		tractionLimit = self.tcMaxLoad,
		shifting = self.shiftRemaining > 0,
		engaging = self.engageRemaining > 0,
		locked = self.locked,
	}
end

-- engineOmega is rad/s. engineTorque is net crankshaft torque after engine losses.
-- Returns updated engineOmega, vehicleSpeed and a state table.
function GearboxSimulation:Step(engineOmega, engineTorque, controls, dt, engineMaxTorque, engineAvailableTorque, engineFrictionTorque)
	local p = self.params
	controls = controls or {}
	dt = clamp(finiteNumber(dt, 0), 0, 0.02)
	if dt <= 0 then
		return engineOmega, self.speed, self:GetState()
	end

	local requested = controls.gear
	if requested ~= nil and math.floor(requested) ~= self.requestedGear then
		self:RequestGear(requested)
	end

	if self.shiftRemaining > 0 then
		self.shiftRemaining = math.max(0, self.shiftRemaining - dt)
		self.gear = 0
		if self.shiftRemaining <= 0 then
			self.gear = self.pendingGear or self.requestedGear
			self.pendingGear = nil
			self.engageRemaining = math.max(0, self.engageTime)
		end
	end

	local engagement = 1

	-- Automatically disengage clutch while changing gears.
	if self.shiftRemaining > 0 then
		engagement = 0

		-- Smoothly re-engage after the new gear is selected.
	elseif self.engageRemaining > 0 then
		if self.engageTime > 0 then
			engagement = 1 - self.engageRemaining / self.engageTime
		end

		self.engageRemaining = math.max(0, self.engageRemaining - dt)
	end

	local manualClutch = clamp(finiteNumber(controls.clutch, 1), 0, 1)
	local targetClutch = manualClutch * engagement
	local clutchAlpha = 1 - math.exp(-dt / (targetClutch < self.clutch and 0.004 or 0.03))
	self.clutch = approach(self.clutch, targetClutch, clutchAlpha)

	local speed = math.max(0, self.speed)
	local wheelRadius = math.max(0.05, finiteNumber(p.wheelRadius, 0.33))
	local mass = math.max(1, finiteNumber(p.mass, 1200))
	local ratio = 0
	if self.gear > 0 then
		ratio = (p.gears[self.gear] or 0) * finiteNumber(p.finalDrive, 1)
	end

	if math.abs(ratio - self.lastRatio) > 1e-6 then
		self.twist = 0
		self.lastRatio = ratio
		if ratio > 0 then
			self.omegaIn = speed / wheelRadius * ratio
			self.locked = false
		end
	end

	local drag = math.max(0, finiteNumber(p.drag, 0.4))
	local grip = math.max(0.05, finiteNumber(p.grip, 1))
	local brakeG = math.max(0, finiteNumber(p.brakeG, grip * 0.9))
	local downforce = math.max(0, finiteNumber(p.downforce, 0))
	local brake = clamp(finiteNumber(controls.brake, 0), 0, 1)
	local resistance = 0
	if speed > 0.02 then
		resistance = drag * speed * speed
			+ 0.012 * mass * G
			+ math.min(brakeG * mass * G, grip * (mass * G + downforce * speed * speed) * 0.9) * brake
	end

	if ratio > 0 and self.clutch > 0.002 then
		-- The following coupling equations correspond to the reference worklet:
		-- reflected vehicle mass, clutch capacity, tyre torque limit and torsional shaft.
		local reflectedMass = mass * (wheelRadius / ratio) ^ 2
		local inputInertia = math.max(0.0001, 0.08 * finiteNumber(p.inertia, 0.12))
		local maxClutchTorque = self.clutch * self.clutch * 1.7 * math.max(1, engineMaxTorque)
		local maxTyreTorque = grip * (mass * G + downforce * speed * speed) * wheelRadius / ratio
		local relativeOmega = math.abs(engineOmega - self.omegaIn)
		local slipping = (not self.locked)
			and maxClutchTorque >= maxTyreTorque
			and relativeOmega > (self.tyreSlid and 5 or 15)
		self.tyreSlid = slipping

		local clutchTorqueLimit = math.min(maxClutchTorque, slipping and maxTyreTorque * 0.7 or maxTyreTorque)
		local maxEngineTorqueNow = math.max(1, engineAvailableTorque or engineMaxTorque)
		local slipRatio = slipping and math.min(1, relativeOmega / 60) or 0
		local tractionDemand = (slipping and (0.6 - 0.15 * slipRatio) or 0.9) * maxTyreTorque
			+ math.max(0, finiteNumber(engineFrictionTorque, 0))
		local tcTarget = clamp((tractionDemand / maxEngineTorqueNow), 0, 1) ^ 1.25
		self.tcMaxLoad = approach(self.tcMaxLoad, tcTarget, dt / 0.05)

		local vehicleOmegaAtGear = speed / wheelRadius * ratio
		local stiffness = math.max(0.01, finiteNumber(p.dlStiffness, 13) * 1000 / (ratio * ratio))
		local lash = math.max(0, finiteNumber(p.dlLash, 2.5)) * PI / 180 * ratio / 2
		local insideLash = math.abs(self.twist) < lash
		local effectiveTwist = insideLash and 0 or (self.twist - (self.twist > 0 and lash or -lash))
		local coupledInertia = self.locked and (finiteNumber(p.inertia, 0.12) + inputInertia) or inputInertia
		local reducedInertia = coupledInertia * reflectedMass / (coupledInertia + reflectedMass)
		local damping = 2 * math.max(0, finiteNumber(p.dlDamping, 0.14)) * math.sqrt(stiffness * reducedInertia)
		local shaftTorque = stiffness * effectiveTwist
		if insideLash then
			shaftTorque = shaftTorque
		else
			shaftTorque += damping * (self.omegaIn - vehicleOmegaAtGear)
		end
		self.shaftTorque = shaftTorque

		if self.locked and math.abs(engineOmega - self.omegaIn) > 2 then
			self.locked = false
		end

		if self.locked then
			local acceleration = (engineTorque - shaftTorque) / math.max(0.0001, finiteNumber(p.inertia, 0.12) + inputInertia)
			local reactionTorque = engineTorque - finiteNumber(p.inertia, 0.12) * acceleration
			if math.abs(reactionTorque) > clutchTorqueLimit * 1.05 then
				self.locked = false
			else
				engineOmega += acceleration * dt
				self.omegaIn = engineOmega
			end
		end

		if not self.locked then
			local clutchDelta = engineOmega - self.omegaIn
			local appliedClutchTorque = clutchTorqueLimit * tanh(clutchDelta / 3)
			local engineInertia = math.max(0.0001, finiteNumber(p.inertia, 0.12))
			engineOmega += (engineTorque - appliedClutchTorque) / engineInertia * dt
			self.omegaIn += (appliedClutchTorque - shaftTorque) / inputInertia * dt

			local newDelta = engineOmega - self.omegaIn
			if math.abs(newDelta) < 3 or clutchDelta * newDelta < 0 then
				local sharedAcceleration = (engineTorque - shaftTorque) / (engineInertia + inputInertia)
				local requiredClutchTorque = engineTorque - engineInertia * sharedAcceleration
				local wheelMismatch = insideLash and math.abs(self.omegaIn - vehicleOmegaAtGear) > 3
				if math.abs(requiredClutchTorque) <= clutchTorqueLimit and not wheelMismatch then
					self.locked = true
					local sharedOmega = (engineInertia * engineOmega + inputInertia * self.omegaIn)
						/ (engineInertia + inputInertia)
					engineOmega = sharedOmega
					self.omegaIn = sharedOmega
				end
			end
		end

		self.omegaIn = math.max(0, self.omegaIn)
		local wheelTorque = shaftTorque * ratio / wheelRadius
		speed = math.max(0, speed + (wheelTorque - resistance) / mass * dt)
		local newVehicleOmega = speed / wheelRadius * ratio
		self.twist += (self.omegaIn - newVehicleOmega) * dt
		local maxTwist = lash + 3 * math.max(1, engineMaxTorque) / stiffness
		self.twist = clamp(self.twist, -maxTwist, maxTwist)
		self.lastRatio = ratio
	else
		self.locked = false
		self.tyreSlid = false
		self.tcMaxLoad = approach(self.tcMaxLoad, 1, dt / 0.05)
		local engineInertia = math.max(0.0001, finiteNumber(p.inertia, 0.12))
		engineOmega += engineTorque / engineInertia * dt
		speed = math.max(0, speed - resistance / mass * dt)
		self.omegaIn = ratio > 0 and (speed / wheelRadius * ratio) or engineOmega
		self.twist *= math.max(0, 1 - dt * 20)
		self.shaftTorque = 0
		self.lastRatio = ratio
	end

	if engineOmega < 0 then
		engineOmega = 0
	end
	if math.abs(engineOmega) < 0.4 and not controls.starter then
		engineOmega = 0
	end

	self.speed = speed
	self.state = self:GetState()
	return engineOmega, speed, self.state
end

return GearboxSimulation
