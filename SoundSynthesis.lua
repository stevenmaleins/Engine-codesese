-- SoundSynthesis.lua
-- Procedural, asset-free engine audio for the Roblox port.
-- This is a Luau DSP port of the reference worklet's main signal paths:
-- per-cylinder firing -> header delay -> collector/chamber/tailpipe -> radiation,
-- plus intake, pops, induction whine, gear whine, wind, tyres, cabin and room.
-- The original worklet is more detailed; this module is the first real-time Roblox
-- implementation and keeps the same parameter vocabulary and major dependencies.

local SoundSynthesis = {}
SoundSynthesis.__index = SoundSynthesis

local DEFAULT_SAMPLE_RATE = 48000
local RING_SIZE = 8192
local PI = math.pi
local TAU = 2 * PI
local SPEED_OF_SOUND = 343

local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end

local function coefficient(sampleRate, cutoffHz)
	return 1 - math.exp(-2 * PI * math.max(1, cutoffHz) / sampleRate)
end

local function tanh(x)
	if x > 10 then return 1 end
	if x < -10 then return -1 end
	local e = math.exp(2 * x)
	return (e - 1) / (e + 1)
end

local function softClip(x, drive)
	return tanh(x * drive)
end

local function newBiquad()
	return {
		b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0,
		z1 = 0, z2 = 0,
	}
end

local function setBandpass(filter, sampleRate, frequency, q)
	frequency = clamp(frequency, 10, sampleRate * 0.45)
	q = math.max(0.1, q)
	local omega = 2 * PI * frequency / sampleRate
	local cosine = math.cos(omega)
	local alpha = math.sin(omega) / (2 * q)
	local a0 = 1 + alpha
	filter.b0 = alpha / a0
	filter.b1 = 0
	filter.b2 = -alpha / a0
	filter.a1 = -2 * cosine / a0
	filter.a2 = (1 - alpha) / a0
end

local function processBiquad(filter, input)
	local output = filter.b0 * input + filter.z1
	filter.z1 = filter.b1 * input - filter.a1 * output + filter.z2
	filter.z2 = filter.b2 * input - filter.a2 * output
	return output
end

local function nextPinkNoise(self)
	local p = self.rng:NextNumber(-1, 1)
	local pink = self.pink
	pink[1] = 0.99886 * pink[1] + p * 0.0555179
	pink[2] = 0.99332 * pink[2] + p * 0.0750759
	pink[3] = 0.96900 * pink[3] + p * 0.1538520
	pink[4] = 0.86650 * pink[4] + p * 0.3104856
	pink[5] = 0.55000 * pink[5] + p * 0.5329522
	pink[6] = -0.7616 * pink[6] - p * 0.0168980
	local output = (pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + pink[7] + p * 0.5362) * 0.11
	pink[7] = p * 0.115926
	return output
end

local function makeDelay(delaySamples, feedback, lpCutoff, sampleRate)
	-- Short reflection/room delay. Unlike the exhaust tubes, this is an echo line.
	return {
		data = buffer.create(RING_SIZE * 4),
		index = 0,
		delay = clamp(delaySamples, 2, RING_SIZE - 2),
		feedback = feedback,
		lp = 0,
		lpCoef = coefficient(sampleRate, lpCutoff),
	}
end

local function delayProcess(line, input)
	-- Fractional-sample feedback delay with explicit positive wrapping.
	-- Audio buffers use byte offsets, so keep every cursor an integer sample index.
	local writeIndex = line.index or 0
	if type(writeIndex) ~= "number" or writeIndex ~= writeIndex
		or writeIndex == math.huge or writeIndex == -math.huge then
		writeIndex = 0
	end
	writeIndex = math.floor(clamp(writeIndex, 0, RING_SIZE - 1))

	local delaySamples = line.delay or 2
	if type(delaySamples) ~= "number" or delaySamples ~= delaySamples
		or delaySamples == math.huge or delaySamples == -math.huge then
		delaySamples = 2
	end
	delaySamples = clamp(delaySamples, 2, RING_SIZE - 2)

	local readPosition = writeIndex - delaySamples
	if readPosition < 0 then
		readPosition += RING_SIZE
	end
	if readPosition >= RING_SIZE then
		readPosition -= RING_SIZE
	end

	local readIndex = math.floor(clamp(readPosition, 0, RING_SIZE - 1))
	local fraction = clamp(readPosition - readIndex, 0, 1)
	local nextIndex = readIndex + 1
	if nextIndex >= RING_SIZE then
		nextIndex = 0
	end

	-- Recover safely if a stale or mismatched module supplied a malformed line.
	if buffer.len(line.data) ~= RING_SIZE * 4 then
		line.data = buffer.create(RING_SIZE * 4)
		line.lp = 0
		writeIndex = 0
	end

	local firstOffset = readIndex * 4
	local secondOffset = nextIndex * 4
	local first = buffer.readf32(line.data, firstOffset)
	local second = buffer.readf32(line.data, secondOffset)
	local delayed = first + (second - first) * fraction

	line.lp += line.lpCoef * (delayed - line.lp)
	buffer.writef32(line.data, writeIndex * 4, input + line.feedback * line.lp)
	writeIndex += 1
	if writeIndex >= RING_SIZE then
		writeIndex = 0
	end
	line.index = writeIndex
	return delayed
end

local function newExhaustChain(params, sampleRate, lengthScale)
	local muffler = clamp(params.muffler or 0.3, 0, 1)
	lengthScale = lengthScale or 1
	local function delayMs(length)
		return 2 * math.max(0.05, length or 0.5) * lengthScale * sampleRate / SPEED_OF_SOUND
	end
	return {
		collector = makeDelay(delayMs(params.collectorLength), -0.30, 3800, sampleRate),
		chamber = makeDelay(delayMs(params.chamber), 0.38, 2200, sampleRate),
		tail = makeDelay(delayMs(params.tailLength), -0.24, 4200 - 1900 * muffler, sampleRate),
		muffler = muffler,
		chamberGain = params.chamberGain or 0.5,
		mufLp = 0,
		mufLpCoef = coefficient(sampleRate, 10000 - 7500 * muffler),
		air = 0,
		airCoef = coefficient(sampleRate, 3400),
		radLp = 0,
		radCoef = coefficient(sampleRate, 88),
		previous = 0,
	}
end

local function processExhaust(chain, input, load)
	local collector = delayProcess(chain.collector, input)
	chain.mufLp += chain.mufLpCoef * (collector - chain.mufLp)
	local chamber = delayProcess(chain.chamber, chain.mufLp)
	local mixed = collector + chain.chamberGain * chamber
		+ chain.muffler * (0.5 * chain.mufLp - collector)
	local tail = delayProcess(chain.tail, mixed)
	local differentiated = tail + (0.12 + 0.28 * load) * (tail - chain.previous)
	chain.previous = tail
	local scaled = differentiated * (0.9 + 0.35 * (1 - chain.muffler))
	local clipped = scaled > 0 and (2.2 * tanh(scaled / 2.2))
		or (2.2 * tanh(0.7 * scaled / 2.2) / 0.7)
	chain.air += chain.airCoef * (clipped - chain.air)
	chain.radLp += chain.radCoef * (chain.air - chain.radLp)
	return (chain.air - chain.radLp) * (0.55 - 0.22 * chain.muffler) * (1 - 0.55 * chain.muffler)
end

function SoundSynthesis.new(params, sampleRate)
	assert(type(params) == "table", "SoundSynthesis.new expects EngineConfig parameters")
	sampleRate = sampleRate or DEFAULT_SAMPLE_RATE
	assert(sampleRate >= 8000, "Sample rate is unexpectedly low")

	local firing = params.firing or {}
	local headers = {}
	for index, event in ipairs(firing) do
		local jitter = (((index - 1) * 7919) % 97) / 97 - 0.5
		local length = (params.headerLength or 0.5) * (1 + 0.2 * jitter)
		headers[index] = makeDelay(2 * length * sampleRate / SPEED_OF_SOUND, -0.34, 4800, sampleRate)
	end

	local chains = {
		newExhaustChain(params, sampleRate, 1),
		newExhaustChain(params, sampleRate, 1.035),
	}

	return setmetatable({
		params = params,
		sampleRate = sampleRate,
		phase = 0,
		phaseInitialized = false,
		audioTime = 0,
		audioLoad = 0,
		runningMix = 0,
		soundTurbo = 0,
		turboPhase = 0,
		turboWobblePhase = 0,
		turboNoiseLp = 0,
		turboNoiseLpCoef = coefficient(sampleRate, 850),
		bovNoiseHigh = 0,
		bovNoiseLow = 0,
		bovNoiseHighCoef = coefficient(sampleRate, 6500),
		bovNoiseLowCoef = coefficient(sampleRate, 900),
		levelFollower = 0,
		compressorGain = 1,
		levelAttackCoef = 1 - math.exp(-1 / (0.008 * sampleRate)),
		levelReleaseCoef = 1 - math.exp(-1 / (0.110 * sampleRate)),
		compressorAttackCoef = 1 - math.exp(-1 / (0.012 * sampleRate)),
		compressorReleaseCoef = 1 - math.exp(-1 / (0.180 * sampleRate)),
		pulseFast = table.create(math.max(1, #firing), 0),
		pulseSlow = table.create(math.max(1, #firing), 0),
		pulseHiss = table.create(math.max(1, #firing), 0),
		pulseFastDecay = math.exp(-1 / (0.00075 * sampleRate)),
		pulseSlowDecay = math.exp(-1 / (0.0045 * sampleRate)),
		pulseHissDecay = math.exp(-1 / (0.0012 * sampleRate)),
		headers = headers,
		chains = chains,
		rng = Random.new(17391),
		intakeLine = makeDelay(2 * (params.intakeLength or 0.3) * sampleRate / SPEED_OF_SOUND, -0.28, 2100, sampleRate),
		intakeLp = 0,
		intakeLpCoef = coefficient(sampleRate, 900),
		blockLp = 0,
		blockLpCoef = coefficient(sampleRate, 145),
		bodyLp = {0, 0},
		bodyLpCoef = {coefficient(sampleRate, 125), coefficient(sampleRate, 260)},
		turboLp = {0, 0},
		turboLpCoef = coefficient(sampleRate, 2200),
		dcInput = {0, 0},
		dcOutput = {0, 0},
		windLp = 0,
		windRum = 0,
		windCounter = 0,
		gust = 0,
		pink = {0, 0, 0, 0, 0, 0, 0},
		windMods = {wk0 = 0, wk1 = 0, wk2 = 0, wkA = 0, wkL = 0, wkR = 0},
		windLoFilter = newBiquad(),
		windMidFilter = newBiquad(),
		windHiFilter = newBiquad(),
		windGlassFilter = newBiquad(),
		tyreFilter = newBiquad(),
		tyrePhase = 0,
		cabinLp = {0, 0},
		roomLeft = makeDelay(sampleRate * 0.031, 0.36, 6500, sampleRate),
		roomRight = makeDelay(sampleRate * 0.043, 0.31, 6200, sampleRate),
		tunnelLeft = makeDelay(sampleRate * 0.084, 0.68, 3800, sampleRate),
		tunnelRight = makeDelay(sampleRate * 0.103, 0.68, 3800, sampleRate),
		popVoices = {},
		popEnvelope = 0,
		popThumpEnvelope = 0,
		popPhase = 0,
		popPhaseFrequency = 80,
		bovEnvelope = 0,
		bovPhase = 0,
		bovFlutterPhase = 0,
		previousThrottle = 0,
		previousBoost = 0,
		previousGear = 0,
		previousSpeed = 0,
		previousState = nil,
		blockCounter = 0,
	}, SoundSynthesis)
end

function SoundSynthesis:SetSampleRate(sampleRate)
	if sampleRate == self.sampleRate then
		return
	end
	-- Delay lines are sample-rate dependent. Recreate the processor cleanly.
	local replacement = SoundSynthesis.new(self.params, sampleRate)
	for key, value in pairs(replacement) do
		self[key] = value
	end
end

function SoundSynthesis:TriggerPop(size)
	local p = self.params
	size = clamp(size or 0.5, 0, 1)
	local randomShape = self.rng:NextNumber() ^ 2
	local subCount = math.floor(clamp((p.popSub or 4) * (0.4 + size + 0.4 * self.rng:NextNumber()) + 0.5, 1, 6))
	local spreadSamples = (p.popSpread or 10) * 0.001 * self.sampleRate * (0.5 + size)
	local pitch = math.max(0.2, p.popPitch or 1)

	for sub = 1, subCount do
		local amplitude = size * (0.6 + 0.8 * self.rng:NextNumber())
		local crackShape = self.rng:NextNumber()
		local fastTime = (0.00012 + 0.0005 * size) * (2.2 - 1.2 * randomShape) / pitch
		local slowTime = (0.0012 + 0.006 * size) * (1.5 - 0.5 * randomShape) / pitch
		fastTime /= (1 + 2.5 * amplitude * (p.popCrack or 1) * (0.5 + randomShape))
		table.insert(self.popVoices, {
			wait = sub == 1 and 0 or math.floor(spreadSamples * self.rng:NextNumber()),
			amplitude = amplitude,
			fast = 0,
			slow = 0,
			hiss = 0,
			hissAmplitude = amplitude * (0.1 + 2.6 * randomShape) * (p.popBright or 1)
				* math.min(1, 0.4 + amplitude * (p.popCrack or 1)),
			fastDecay = math.exp(-1 / (math.max(0.00005, fastTime) * self.sampleRate)),
			slowDecay = math.exp(-1 / (math.max(0.0002, slowTime) * self.sampleRate)),
			hissDecay = math.exp(-1 / ((0.0012 + 0.0025 * randomShape) * self.sampleRate)),
			started = false,
			age = 0,
		})
	end

	self.popEnvelope = math.max(self.popEnvelope, size * (p.popThump or 1))
	self.popThumpEnvelope = math.min(0.6, self.popThumpEnvelope + size * (p.popWhump or 0.1) * 0.08)
	self.popPhaseFrequency = (55 + 50 * (1 - size)) * math.sqrt(p.popPitch or 1)
end

function SoundSynthesis:_CheckEvents(state)
	local p = self.params
	local throttle = state.requestedThrottle or state.throttle or 0
	local rpm = state.rpm or 0

	-- Throttle-lift afterfire and turbo blow-off are edge-triggered once per audio block.
	if self.previousThrottle > 0.3 and throttle < 0.05 and rpm > (p.idleRpm or 700) * 1.6 then
		if (p.pops or 0) > 0 then
			self:TriggerPop(clamp(0.35 + (p.popBang or 0) * 0.4, 0, 1))
		end
	end

	local boost = state.boost or 0
	local boostDrop = self.previousBoost - boost
	local throttleLift = self.previousThrottle > 0.30 and throttle < 0.05
	if p.induction == "turbo" and p.bov ~= "none"
		and (boostDrop > 0.07 or throttleLift) then
		-- Normalize boost to the selected preset's boost range, not absolute
		-- bar-like units, so even moderate spool produces an audible vent.
		local boostAmount = clamp(self.previousBoost / math.max(0.35, p.boost or 1), 0, 1)
		if boostAmount > 0.04 then
			self.bovEnvelope = math.max(self.bovEnvelope, boostAmount)
		end
	end

	self.previousThrottle = throttle
	self.previousBoost = boost
	self.previousGear = state.gear or 0
	self.previousSpeed = state.speed or 0
end

function SoundSynthesis:RenderBlock(state, frameCount, previousState, alphaStart, alphaEnd)
	assert(type(state) == "table", "RenderBlock expects engine state")
	frameCount = math.floor(clamp(frameCount or 512, 1, 4096))

	local p = self.params
	local sampleRate = self.sampleRate
	local left = buffer.create(frameCount * 4)
	local right = buffer.create(frameCount * 4)
	local fromState = previousState or self.previousState or state
	alphaStart = clamp(alphaStart or 0, 0, 1)
	alphaEnd = clamp(alphaEnd or 1, alphaStart, 1)
	local function mixState(key, fallback)
		local from = fromState[key]
		local to = state[key]
		if type(from) ~= "number" then from = fallback end
		if type(to) ~= "number" then to = fallback end
		return from, to
	end
	local rpmFrom, rpmTo = mixState("rpm", 0)
	local speedFrom, speedTo = mixState("speed", 0)
	local loadFrom, loadTo = mixState("load", 0)
	local boostFrom, boostTo = mixState("boost", 0)
	local turboFrom, turboTo = mixState("turbo", 0)
	local omegaInFrom, omegaInTo = mixState("omegaIn", 0)
	local shaftFrom, shaftTo = mixState("shaftTorque", 0)
	local liftFrom, liftTo = mixState("liftTime", 0)
	local cutBurstFrom, cutBurstTo = mixState("cutBurst", 0)
	local throttleFrom, throttleTo = mixState("requestedThrottle", state.throttle or 0)
	local gearWhine = p.gearWhine or 0
	local mic = clamp(p.mic or 0.3, 0, 1)
	local body = p.body or 2.5
	local windAmount = p.wind or 1
	local openAir = p.openAir == true
	local banks = p.banks or 1
	local cycle = p.cycle or 720

	if not self.phaseInitialized then
		self.phase = fromState.crankAngle or state.crankAngle or 0
		self.phaseInitialized = true
	end
	self:_CheckEvents(state)

	local muffler = clamp(p.muffler or 0.3, 0, 1)
	local superWhine = p.induction == "super" and (p.whine or 0) > 0
	local turboWhine = p.induction == "turbo" and (p.whine or 0) > 0
	local cabinCoef = coefficient(sampleRate, 12000 - 8500 * clamp(p.cabin or 0, 0, 1))

	for sample = 0, frameCount - 1 do
		local alpha = alphaStart + (alphaEnd - alphaStart) * ((sample + 1) / frameCount)
		local rpm = math.max(0, rpmFrom + (rpmTo - rpmFrom) * alpha)
		local speed = math.max(0, speedFrom + (speedTo - speedFrom) * alpha)
		local targetLoad = clamp(loadFrom + (loadTo - loadFrom) * alpha, 0, 1)
		local loadTau = targetLoad > self.audioLoad and 0.045 or 0.105
		self.audioLoad += (targetLoad - self.audioLoad)
			* (1 - math.exp(-1 / (loadTau * sampleRate)))
		local load = clamp(self.audioLoad, 0, 1)
		local boost = math.max(0, boostFrom + (boostTo - boostFrom) * alpha)
		local turboTarget = math.max(0, turboFrom + (turboTo - turboFrom) * alpha)
		local turboTau = turboTarget > self.soundTurbo and 0.060 or 0.17
		self.soundTurbo += (turboTarget - self.soundTurbo)
			* (1 - math.exp(-1 / (turboTau * sampleRate)))
		local turbo = self.soundTurbo
		local omegaIn = math.max(0, omegaInFrom + (omegaInTo - omegaInFrom) * alpha)
		local shaftTorque = shaftFrom + (shaftTo - shaftFrom) * alpha
		local liftTime = math.max(0, liftFrom + (liftTo - liftFrom) * alpha)
		local cutBurst = math.max(0, cutBurstFrom + (cutBurstTo - cutBurstFrom) * alpha)
		local throttle = throttleFrom + (throttleTo - throttleFrom) * alpha
		local gear = state.gear or 0
		local gearRatio = gear > 0 and (p.gears[gear] or 1) or 1
		local kmh = speed * 3.6
		local intakeMix = 0.055 + load * 0.10
		local rpmFraction = clamp(rpm / math.max(1, p.redline), 0, 1.5)
		local boostWhine = 0
		local noise = self.rng:NextNumber(-1, 1)
		local pinkNoise = nextPinkNoise(self)
		self.audioTime += 1 / sampleRate
		local crankStep = rpm * 6 / sampleRate
		local oldPhase = self.phase
		self.phase += crankStep
		local runningTarget = state.running and 1 or (state.starter and 0.30 or 0)
		local runningTau = runningTarget > self.runningMix and 0.025 or 0.14
		self.runningMix += (runningTarget - self.runningMix)
			* (1 - math.exp(-1 / (runningTau * sampleRate)))

		-- Cylinder exhaust excitation, with each runner having its own resonant delay.
		local bank0, bank1 = 0, 0
		for index, event in ipairs(p.firing) do
			local target = ((event.angle or 0) + 135) % cycle
			local oldCycle = math.floor((oldPhase - target) / cycle)
			local newCycle = math.floor((self.phase - target) / cycle)
			if newCycle > oldCycle then
				local firingStrength = state.running and 1 or (state.starter and 0.32 or 0.035)
				-- Keep the no-throttle idle alive, then let load add body rather
				-- than multiplying the entire engine sound by five or six times.
				local impulse = firingStrength
					* (0.22 + 0.46 * math.sqrt(load) + 0.025 * rpmFraction)
					* (0.96 + 0.08 * self.rng:NextNumber())
				self.pulseFast[index] = math.min(2, self.pulseFast[index] + impulse)
				self.pulseSlow[index] = math.min(2, self.pulseSlow[index] + impulse)
				self.pulseHiss[index] = math.max(
					self.pulseHiss[index],
					impulse * (0.08 + 0.15 * self.rng:NextNumber())
				)
				if (p.pops or 0) > 0 and rpm > (p.idleRpm or 700) * 1.5 and load < 0.04 then
					local liftEnvelope = math.exp(-liftTime / 0.7) + 0.012 * rpmFraction
					local chance = p.pops * (p.popRate or 1) * (1 + 1.5 * (p.popBang or 0))
						* ((0.03 + 0.09 * rpmFraction) * liftEnvelope + 0.35 * cutBurst)
					if self.rng:NextNumber() < clamp(chance, 0, 0.95) then
						local size = math.min(1, self.rng:NextNumber() ^ 1.6
							+ (p.popBang or 0) * (0.5 + 0.5 * self.rng:NextNumber()))
						self:TriggerPop(size)
					end
				end
			end
			local fast = self.pulseFast[index] * self.pulseFastDecay
			local slow = self.pulseSlow[index] * self.pulseSlowDecay
			local hiss = self.pulseHiss[index] * self.pulseHissDecay
			self.pulseFast[index] = fast
			self.pulseSlow[index] = slow
			self.pulseHiss[index] = hiss
			local eventPhase = ((self.phase - (event.angle or 0)) % cycle) / cycle
			local resonant = math.sin(eventPhase * TAU * 2) * slow * 0.032
			-- Less click-like high-frequency edge, with a softer pressure tail.
			local excitation = fast - slow * 0.28 + resonant
				+ hiss * self.rng:NextNumber(-1, 1) * 0.055
			local headerOut = delayProcess(self.headers[index], excitation)
			local bank = (event.collector ~= nil and event.collector or event.bank or 0) + 1
			if bank <= 1 then
				bank0 += headerOut
			else
				bank1 += headerOut
			end
		end

		local rawHeaderLeft = bank0
		local rawHeaderRight = banks > 1 and bank1 or bank0

		-- A quiet, crank-synchronous low-order bed keeps idle audible without
		-- turning the engine into a constant pure tone. Load adds only a modest
		-- amount of level; the firing pulses remain the main character.
		local crankRadians = self.phase * PI / 180
		local firingOrder = #p.firing * 360 / math.max(360, cycle)
		local orderPhase = crankRadians * firingOrder
		local bedWave = math.sin(orderPhase)
			+ 0.32 * math.sin(orderPhase * 2 + 0.21)
			+ 0.15 * math.sin(orderPhase * 3 + 0.63)
			+ 0.07 * math.sin(orderPhase * 4 + 1.01)
		local bedLevel = self.runningMix
			* (0.035 + 0.030 * math.sqrt(load) + 0.010 * rpmFraction)
		local engineBed = bedWave * bedLevel
		local bodySource = rawHeaderLeft + rawHeaderRight + engineBed
		local headerLeft = rawHeaderLeft
		local headerRight = rawHeaderRight

		-- Turbo damping belongs on the exhaust route only; the engine block
		-- continues to radiate its full mechanical firing energy.
		if p.induction == "turbo" then
			self.turboLp[1] += self.turboLpCoef * (headerLeft - self.turboLp[1])
			self.turboLp[2] += self.turboLpCoef * (headerRight - self.turboLp[2])
			headerLeft = self.turboLp[1] * 0.55
			headerRight = banks > 1 and self.turboLp[2] * 0.55 or headerLeft
		end

		local exhaustL = processExhaust(self.chains[1], headerLeft, load)
		local exhaustR = banks > 1
			and processExhaust(self.chains[2], headerRight, load)
			or exhaustL

		-- Intake tract: speed/load-scaled stochastic induction noise through a pipe delay.
		local intakeNoise = noise * (0.004 + load * 0.026) * (0.12 + rpmFraction * 0.75)
		self.intakeLp += self.intakeLpCoef * (intakeNoise - self.intakeLp)
		local intake = (delayProcess(self.intakeLine, self.intakeLp) + self.intakeLp) * intakeMix

		-- Low-frequency block/body resonance must be driven from the header
		-- pressure pulses, not the already high-passed tailpipe signal.
		local rawBody = bodySource
		self.blockLp += self.blockLpCoef * (rawBody - self.blockLp)
		self.bodyLp[1] += self.bodyLpCoef[1] * (rawBody - self.bodyLp[1])
		self.bodyLp[2] += self.bodyLpCoef[2] * (self.bodyLp[1] - self.bodyLp[2])
		local bodyOut = self.bodyLp[1] * (0.34 * body)
			+ self.bodyLp[2] * (0.28 * body)
			+ self.blockLp * (0.10 * body)

		-- Procedural afterfire transient with crack, hiss and low thump components.
		local popNoise = self.rng:NextNumber(-1, 1)
		local pop = popNoise * self.popEnvelope * 0.045
		self.popEnvelope *= math.exp(-1 / (0.018 * sampleRate))
		self.popThumpEnvelope *= math.exp(-1 / (0.045 * sampleRate))
		self.popPhase += self.popPhaseFrequency / sampleRate
		if self.popPhase >= 1 then self.popPhase -= 1 end
		pop += self.popThumpEnvelope * math.sin(self.popPhase * TAU) * 0.22
		for voiceIndex = #self.popVoices, 1, -1 do
			local voice = self.popVoices[voiceIndex]
			if voice.wait > 0 then
				voice.wait -= 1
			else
				if not voice.started then
					voice.fast = voice.amplitude
					voice.slow = voice.amplitude
					voice.hiss = voice.hissAmplitude
					voice.started = true
				end
				voice.fast *= voice.fastDecay
				voice.slow *= voice.slowDecay
				voice.hiss *= voice.hissDecay
				pop += voice.fast - voice.slow + voice.hiss * popNoise * 0.35
				voice.age += 1
				if voice.age > sampleRate * 0.09 or (voice.fast + voice.slow + voice.hiss) < 0.00001 then
					table.remove(self.popVoices, voiceIndex)
				end
			end
		end

		-- Supercharger and turbo tones. The turbo uses its own smoothed phase,
		-- a restrained harmonic stack and a little filtered turbine airflow.
		boostWhine = 0
		if superWhine then
			local frequency = rpm / 60 * 11.2 * (p.whinePitch or 1)
			local phase = (self.audioTime * frequency) % 1
			boostWhine = (math.sin(phase * TAU) + 0.24 * math.sin(phase * TAU * 2))
				* (p.whine or 0) * load * math.pow(math.max(0, rpmFraction), 2) * 0.032
		elseif turboWhine and turbo > 0.015 then
			local frequency = (320 + 2600 * math.sqrt(turbo)) * (p.whinePitch or 1)
			self.turboPhase += frequency / sampleRate
			if self.turboPhase >= 1 then
				self.turboPhase -= math.floor(self.turboPhase)
			end
			self.turboWobblePhase += (3.5 + 2.5 * turbo) / sampleRate
			if self.turboWobblePhase >= 1 then
				self.turboWobblePhase -= 1
			end
			local phase = self.turboPhase * TAU
			local wobble = 0.92 + 0.08 * math.sin(self.turboWobblePhase * TAU)
			local turbineTone = math.sin(phase)
				+ 0.18 * math.sin(phase * 2 + 0.18)
				+ 0.07 * math.sin(phase * 3 + 0.51)
			local toneLevel = (p.whine or 0) * (0.012 + 0.012 * turbo) * math.sqrt(turbo)
			boostWhine = turbineTone * toneLevel * wobble
		end
		self.turboNoiseLp += self.turboNoiseLpCoef * (pinkNoise - self.turboNoiseLp)
		if turboWhine then
			boostWhine += (pinkNoise - self.turboNoiseLp) * turbo * (0.002 + 0.005 * load)
		end

		-- Filtered airflow burst. Flutter is amplitude-modulated air noise rather
		-- than a low sine tone, so it sounds like pulsing pressure release.
		self.bovNoiseHigh += self.bovNoiseHighCoef * (noise - self.bovNoiseHigh)
		self.bovNoiseLow += self.bovNoiseLowCoef * (noise - self.bovNoiseLow)
		local bovAir = (self.bovNoiseHigh - self.bovNoiseLow) * 2.1
		local bov = 0
		if self.bovEnvelope > 0.002 then
			local flutterRate = clamp(p.flRate or 19, 10, 32) * (0.92 + 0.16 * self.bovEnvelope)
			self.bovFlutterPhase += flutterRate / sampleRate
			if self.bovFlutterPhase >= 1 then
				self.bovFlutterPhase -= math.floor(self.bovFlutterPhase)
			end
			local pulse = math.max(0, math.sin(self.bovFlutterPhase * TAU))
			local flutterGate = p.bov == "flutter" and (0.12 + 0.88 * pulse * pulse) or 1
			local duration = clamp(p.flDur or 0.42, 0.18, 0.70)
			bov = bovAir * self.bovEnvelope * (p.flHiss or 0.6)
				* (p.flLevel or 0.5) * 0.38 * flutterGate
			self.bovEnvelope *= math.exp(-1 / (duration * sampleRate))
		end

		-- Gear mesh whine: frequency follows the gearbox input/output shaft and tooth order.
		local gearTone = 0
		if gearWhine > 0 and gear > 0 and omegaIn > 1 then
			local outputHz = (omegaIn / gearRatio) / TAU
			local inputHz = omegaIn / TAU
			local order = p.gearWhineOrder or 11
			local inputOrder = (p.gearWhineTeeth and p.gearWhineTeeth[gear]) or p.gearWhineOrderIn or 23
			local meshHz = outputHz * order
			local meshPhase = (self.audioTime * meshHz) % 1
			local inputPhase = (self.audioTime * inputHz * inputOrder) % 1
			local torqueFactor = clamp(math.abs(shaftTorque) / math.max(1, p.peakTorque), 0, 1.5)
			gearTone = gearWhine * (0.025 + 0.20 * torqueFactor)
				* (math.sin(meshPhase * TAU) + 0.25 * math.sin(meshPhase * TAU * 2)
					+ 0.10 * math.sin(inputPhase * TAU))
		end
		local ersTone = 0
		if (p.mguk or 0) > 0 then
			local ersFrequency = rpm * 0.16
			self.ersPhase = (self.ersPhase or 0) + ersFrequency / sampleRate
			if self.ersPhase >= 1 then self.ersPhase -= 1 end
			local ersLoad = load > 0.5 and load * load or 0.03
			ersTone = (math.sin(self.ersPhase * TAU) + 0.12 * math.sin(self.ersPhase * TAU * 2))
				* p.mguk * ersLoad * math.min(1, rpmFraction * 1.5) * 0.022
		end

		-- Speed-reactive wind and tyre model ported from the worklet's pink-noise path.
		local windLeft = 0
		local windRight = 0
		local tyre = 0
		if windAmount > 0 and speed > 0.5 then
			local h = kmh
			self.windCounter += 1
			if (self.windCounter % 64) == 1 then
				local d = 64 / sampleRate
				local mods = self.windMods
				mods.wk0 += (self.rng:NextNumber(-1, 1) - mods.wk0) * d / 0.35
				mods.wk1 += (self.rng:NextNumber(-1, 1) - mods.wk1) * d / 0.8
				mods.wk2 += (self.rng:NextNumber(-1, 1) - mods.wk2) * d / 1.6
				mods.wkA += (self.rng:NextNumber(-1, 1) - mods.wkA) * d / 0.5
				mods.wkL += (self.rng:NextNumber(-1, 1) - mods.wkL) * d / 0.9
				mods.wkR += (self.rng:NextNumber(-1, 1) - mods.wkR) * d / 0.9
				self.gust = math.max(0, self.gust * (1 - d / 0.6))
				if self.rng:NextNumber(-1, 1) > (0.985 - 0.01 * math.min(1, h / 200)) then
					self.gust = math.min(1, self.gust + 0.5 + 0.5 * math.abs(self.rng:NextNumber(-1, 1)))
				end

				local speedScale = math.sqrt(math.max(0.2, h / 120))
				local lowHz = clamp(170 * speedScale * (1 + 0.18 * mods.wk2), 100, 600)
				local midHz = clamp(520 * speedScale * (1 + 0.22 * mods.wk1), 250, 1600)
				local highHz = clamp(1250 * speedScale * (1 + 0.3 * mods.wk0 + 0.15 * self.gust), 500, 4200)
				setBandpass(self.windLoFilter, sampleRate, lowHz, 2.2)
				setBandpass(self.windMidFilter, sampleRate, midHz, 3.5)
				setBandpass(self.windHiFilter, sampleRate, highHz, 6)
				setBandpass(self.windGlassFilter, sampleRate, 240 + 60 * mods.wk2, 1.8)
				setBandpass(self.tyreFilter, sampleRate, clamp(110 + 1.2 * h, 110, 420), 1.2)
			end

			local mods = self.windMods
			local low = processBiquad(self.windLoFilter, pinkNoise)
			local mid = processBiquad(self.windMidFilter, pinkNoise)
			local high = processBiquad(self.windHiFilter, pinkNoise)
			local windMix = windAmount * math.pow(math.min(1, h / 320), 3)
				* (0.75 + 0.25 * mods.wkA + 0.6 * self.gust)
			local windCore
			if openAir then
				self.windRum += (pinkNoise - self.windRum) * 0.012
				local rumble = tanh(self.windRum * 6) * 0.5
				windCore = (low * 2.6 + mid * 2.2 + high * 1.3 * (0.6 + 0.4 * self.gust) + rumble)
					* windMix * 1.1
			else
				local glass = processBiquad(self.windGlassFilter, pinkNoise)
				local filtered = low * 2.2 + mid * 1.2 + glass * 2.5
				self.windLp += (filtered - self.windLp) * 0.09
				windCore = (self.windLp * 1.4 + mid * 0.25) * windMix * 0.9
			end

			self.tyrePhase += clamp(30 + 0.6 * h, 30, 150) / sampleRate * TAU
			if self.tyrePhase >= TAU then self.tyrePhase -= TAU end
			local tyreMix = windAmount * math.min(1, h / 220) * (openAir and 0.45 or 0.4)
				* (0.85 + 0.15 * mods.wkA)
			tyre = (processBiquad(self.tyreFilter, pinkNoise) * 2
				+ 0.12 * math.sin(self.tyrePhase)) * tyreMix * 0.4
			windLeft = windCore * (1 + 0.25 * mods.wkL)
			windRight = windCore * (1 + 0.25 * mods.wkR)
		end

		-- Interior/cabin coloration and short room reflections.
		local leftRaw = exhaustL * 0.55 + exhaustR * 0.12 + bodyOut + intake * 0.45
			+ gearTone * 0.65 + ersTone + boostWhine + bov + pop + windLeft + tyre
		local rightRaw = exhaustR * 0.55 + exhaustL * 0.12 + bodyOut + intake * 0.45
			+ gearTone * 0.65 + ersTone + boostWhine + bov + pop + windRight + tyre * 0.98

		local cabin = clamp(p.cabin or 0, 0, 1)
		self.cabinLp[1] += cabinCoef * (leftRaw - self.cabinLp[1])
		self.cabinLp[2] += cabinCoef * (rightRaw - self.cabinLp[2])
		leftRaw = leftRaw * (1 - 0.35 * cabin) + self.cabinLp[1] * 0.35 * cabin
		rightRaw = rightRaw * (1 - 0.35 * cabin) + self.cabinLp[2] * 0.35 * cabin

		local room = clamp(p.room or 0, 0, 1)
		local roomInput = (leftRaw + rightRaw) * 0.5
		local leftEcho = delayProcess(self.roomLeft, roomInput)
		local rightEcho = delayProcess(self.roomRight, roomInput)
		leftRaw += leftEcho * room * 0.28
		rightRaw += rightEcho * room * 0.28
		if p.tunnel then
			local tunnelLeft = delayProcess(self.tunnelLeft, roomInput)
			local tunnelRight = delayProcess(self.tunnelRight, roomInput)
			leftRaw += tunnelLeft * room * 0.65
			rightRaw += tunnelRight * room * 0.65
		else
			delayProcess(self.tunnelLeft, 0)
			delayProcess(self.tunnelRight, 0)
		end

		local micMix = 0.35 + 0.65 * mic
		local engineMix = 1 - 0.75 * mic
		local master = (p.master or 1) * 1.0
		local leftSignal = (leftRaw * micMix + exhaustL * engineMix * 0.50) * master
		local rightSignal = (rightRaw * micMix + exhaustR * engineMix * 0.50) * master

		-- Remove subsonic/DC drift without cutting the exhaust firing fundamental.
		local leftDc = leftSignal - self.dcInput[1] + 0.995 * self.dcOutput[1]
		local rightDc = rightSignal - self.dcInput[2] + 0.995 * self.dcOutput[2]
		self.dcInput[1], self.dcInput[2] = leftSignal, rightSignal
		self.dcOutput[1], self.dcOutput[2] = leftDc, rightDc
		-- Keep the exhaust as the dominant engine source; accessories are mixed
		-- around it rather than competing with it.
		local peak = math.max(math.abs(leftDc), math.abs(rightDc))
		local followerCoef = peak > self.levelFollower
			and self.levelAttackCoef or self.levelReleaseCoef
		self.levelFollower += followerCoef * (peak - self.levelFollower)

		-- Gentle peak control keeps the first throttle transient from jumping
		-- far above idle while preserving the natural rise in engine load.
		local targetGain = 1
		if self.levelFollower > 0.24 then
			targetGain = clamp((0.24 / self.levelFollower) ^ 0.55, 0.52, 1)
		end
		local gainCoef = targetGain < self.compressorGain
			and self.compressorAttackCoef or self.compressorReleaseCoef
		self.compressorGain += gainCoef * (targetGain - self.compressorGain)

		local leftOut = softClip(leftDc * self.compressorGain * 1.06, 1.20)
		local rightOut = softClip(rightDc * self.compressorGain * 1.06, 1.20)

		buffer.writef32(left, sample * 4, leftOut)
		buffer.writef32(right, sample * 4, rightOut)
	end

	return left, right
end

function SoundSynthesis:CommitState(state)
	if type(state) ~= "table" then
		return
	end
	self.previousState = {
		rpm = state.rpm or 0,
		speed = state.speed or 0,
		load = state.load or 0,
		boost = state.boost or 0,
		turbo = state.turbo or 0,
		omegaIn = state.omegaIn or 0,
		shaftTorque = state.shaftTorque or 0,
		liftTime = state.liftTime or 0,
		cutBurst = state.cutBurst or 0,
		requestedThrottle = state.requestedThrottle or state.throttle or 0,
		throttle = state.throttle or 0,
		gear = state.gear or 0,
		crankAngle = state.crankAngle or self.phase,
		running = state.running == true,
		starter = state.starter == true,
	}
	if type(state.crankAngle) == "number" then
		self.phase = state.crankAngle % (self.params.cycle or 720)
	end
end

return SoundSynthesis
