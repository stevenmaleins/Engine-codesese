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

local function pressureProfile(angleDegrees)
	local angle = angleDegrees * PI / 180
	return math.pow(1 + 4.5 * (1 - math.cos(angle)), -1.3)
end

local function pressureEnvelope(angleDegrees, riseDegrees, startDegrees)
	if angleDegrees < startDegrees or angleDegrees >= 375 then
		return 0
	end

	local rise = math.max(0.5, riseDegrees)
	local t = (angleDegrees - startDegrees) / rise
	if t < 1 then
		return t * t * (3 - 2 * t)
	end

	local tail = (375 - angleDegrees) / 70
	if tail < 1 then
		return tail * tail * (3 - 2 * tail)
	end
	return 1
end

local function raisedSineWindow(angleDegrees, startDegrees, endDegrees)
	if angleDegrees < startDegrees or angleDegrees >= endDegrees then
		return 0
	end
	local phase = PI * (angleDegrees - startDegrees) / (endDegrees - startDegrees)
	local value = math.sin(phase)
	return value * value
end

local function outputLimit(self, signal, channel, master, clipAmount)
	if clipAmount <= 0 then
		return tanh(signal * master * 1.8)
	end

	local magnitude = math.abs(signal)
	local envelope = self.clipEnv[channel]
	if magnitude > envelope then
		envelope += (magnitude - envelope) * 0.02
	else
		envelope += (magnitude - envelope) * 0.0003
	end
	self.clipEnv[channel] = math.max(0, envelope)

	local peak = math.max(0.001, envelope)
	local ceiling = peak * (1 - 0.8 * clipAmount)
	local limited = clamp(signal, -ceiling, ceiling) * math.pow(peak / ceiling, 0.8)
	return tanh(limited * master * 1.8)
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
	-- The ring cursor is an integer invariant maintained by makeDelay and this
	-- function. Wrap explicitly so every buffer offset is valid and integral.
	local writeIndex = line.index
	if writeIndex < 0 or writeIndex >= RING_SIZE then
		writeIndex = 0
	end

	-- Validate the allocation only at ring wrap, not on every audio sample.
	-- The hot path stays light enough for 48 kHz real-time synthesis.
	if writeIndex == 0 and buffer.len(line.data) ~= RING_SIZE * 4 then
		line.data = buffer.create(RING_SIZE * 4)
		line.lp = 0
	end

	local readPosition = writeIndex - line.delay
	if readPosition < 0 then
		readPosition += RING_SIZE
	end
	if readPosition >= RING_SIZE then
		readPosition -= RING_SIZE
	end

	local readIndex = math.floor(readPosition)
	local fraction = readPosition - readIndex
	local nextIndex = readIndex + 1
	if nextIndex >= RING_SIZE then
		nextIndex = 0
	end

	local first = buffer.readf32(line.data, readIndex * 4)
	local second = buffer.readf32(line.data, nextIndex * 4)
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
		collector = makeDelay(delayMs(params.collectorLength), -0.13, 3200, sampleRate),
		chamber = makeDelay(delayMs(params.chamber), 0.12, 1900, sampleRate),
		tail = makeDelay(delayMs(params.tailLength), -0.10, 3400 - 1300 * muffler, sampleRate),
		muffler = muffler,
		chamberGain = params.chamberGain or 0.5,
		mufLp = 0,
		mufLpCoef = coefficient(sampleRate, 10000 - 7500 * muffler),
		air = 0,
		airCoef = coefficient(sampleRate, 2850),
		radLp = 0,
		radCoef = coefficient(sampleRate, 58),
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
	local differentiated = tail + (0.055 + 0.13 * load) * (tail - chain.previous)
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
		headers[index] = makeDelay(2 * length * sampleRate / SPEED_OF_SOUND, -0.10, 4200, sampleRate)
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
		mufflerState = clamp(params.muffler or 0.3, 0, 1),
		soundTurbo = 0,
		turboPhase = 0,
		whooshLp = 0,
		turboNoiseHigh = 0,
		turboNoiseLow = 0,
		turboNoiseHighCoef = coefficient(sampleRate, 2200),
		turboNoiseLowCoef = coefficient(sampleRate, 350),
		prevPsi = table.create(math.max(1, #firing), 0),
		p0 = table.create(math.max(1, #firing), 0),
		pe = table.create(math.max(1, #firing), 0),
		crack = table.create(math.max(1, #firing), 0),
		evoJit = table.create(math.max(1, #firing), 0),
		wet = table.create(math.max(1, #firing), 0),
		kBlow = 1 / (0.0015 * sampleRate),
		crackDecay = math.exp(-1 / (0.0005 * sampleRate)),
		tick = 0,
		tickDecay = math.exp(-1 / (0.0007 * sampleRate)),
		intakeFormant = newBiquad(),
		intakeFormantHz = 0,
		intakeCounter = 0,
		clipEnv = {0, 0},
		bovFlow = 0,
		bovPressure = 0,
		bovRev = 0,
		bovStart = 1,
		surgeFade = 0,
		surgePhase = 0,
		ventP = 0,
		ventV = 0,
		jetState = 0,
		bovBp = newBiquad(),
		bovBp2 = newBiquad(),
		bovFilterCounter = 0,
		headers = headers,
		chains = chains,
		rng = Random.new(17391),
		intakeLine = makeDelay(2 * (params.intakeLength or 0.3) * sampleRate / SPEED_OF_SOUND, -0.10, 1850, sampleRate),
		intakeLp = 0,
		intakeLpCoef = coefficient(sampleRate, 760),
		blockLp = 0,
		blockLpCoef = coefficient(sampleRate, 112),
		bodyLp = {0, 0},
		bodyLpCoef = {coefficient(sampleRate, 110), coefficient(sampleRate, 225)},
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
		local boostAmount = clamp(self.previousBoost / math.max(0.35, p.boost or 1), 0, 1)
		local spool = clamp(state.turbo or self.soundTurbo or 0, 0, 1.2)
		if boostAmount > 0.04 then
			self.bovEnvelope = math.max(self.bovEnvelope, boostAmount)
			self.bovStart = boostAmount
			self.bovFlow = math.max(self.bovFlow, math.max(0.1, spool))
			self.bovPressure = math.max(self.bovPressure, 1.29 * spool * spool)
			self.bovRev = 0
			self.surgeFade = 0
			self.ventP = self.previousBoost
			self.ventV = 0
			self.jetState = 0
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
	local valveOpen = state.valveOpen
	if type(valveOpen) ~= "boolean" then
		valveOpen = p.valve == "open"
			or (p.valve == "auto" and (state.rpm or 0) >= (p.valveRpm or 3500))
	end
	local targetMuffler = valveOpen and muffler or clamp(muffler + 0.55, 0, 1)
	local blockSeconds = frameCount / sampleRate
	self.mufflerState += (targetMuffler - self.mufflerState)
		* (1 - math.exp(-blockSeconds / 0.25))
	for _, chain in ipairs(self.chains) do
		if math.abs(chain.muffler - self.mufflerState) > 0.003 then
			chain.muffler = self.mufflerState
			chain.mufLpCoef = coefficient(sampleRate, 10000 - 7500 * self.mufflerState)
			chain.tail.lpCoef = coefficient(sampleRate, 3400 - 1300 * self.mufflerState)
		end
	end

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
		local rpmFraction = clamp(rpm / math.max(1, p.redline), 0, 1.5)
		local boostWhine = 0
		local noise = self.rng:NextNumber(-1, 1)
		local pinkNoise = nextPinkNoise(self)
		self.audioTime += 1 / sampleRate
		local crankStep = rpm * 6 / sampleRate
		self.phase += crankStep
		local runningTarget = state.running and 1 or (state.starter and 0.30 or 0)
		local runningTau = runningTarget > self.runningMix and 0.025 or 0.14
		self.runningMix += (runningTarget - self.runningMix)
			* (1 - math.exp(-1 / (runningTau * sampleRate)))

		-- The LFA reference and the other presets share a combustion-pressure source.
		-- Every cylinder has its own phase, pressure envelope and tiny timing/energy variation.
		local bank0, bank1 = 0, 0
		local pressureRumble = 0
		local intakeTone = 0
		local effectiveLoad = 0.3 + 0.7 * load
		local rpmTexture = clamp(rpm / 2500, 0, 1)
		local hiCam = state.hiCam == true
		local pressureStart = hiCam and 112 or 135
		local camShift = hiCam and 18 or 0
		local camScale = hiCam and 1.7 or 1
		local phaseScale = 720 / math.max(720, cycle)
		local blowdownAmount = clamp((p.blowdownSharp or 0)
			* clamp((load - 0.12) / 0.88, 0, 1), 0, 1)
		local pulseRise = math.min(
			14 / (1 + 1.33 * blowdownAmount),
			0.006 * math.max(300, rpm) / (1 + 2 * blowdownAmount)
		)
		local crackStrength = 3 * math.sqrt(blowdownAmount)
		local overrun = load < 0.03 and rpm > (p.idleRpm or 700) * 1.4
		local idleRoughness = clamp(p.idleRough or 1, 0, 3)
		local camOverlap = clamp(p.camOverlap or 0, 0, 1)

		for index, event in ipairs(p.firing) do
			local cylinderPhase = ((self.phase - (event.angle or 0)) % cycle) * phaseScale
			local previousCylinderPhase = self.prevPsi[index] or cylinderPhase
			self.prevPsi[index] = cylinderPhase
			local phaseSine = math.sin(cylinderPhase * PI / 180)

			-- A firing event only injects pressure at the actual crank-phase wrap.
			-- The exhaust pressure then develops over the next ~135 crank degrees.
			if cylinderPhase < previousCylinderPhase - 360 then
				self.evoJit[index] = self.rng:NextNumber(0, 3)
				local shouldFire = (state.running == true or state.starter == true)
					and state.cut ~= true
				if overrun and self.rng:NextNumber() > 0.30 then
					shouldFire = false
				end
				local idleMissChance = camOverlap * (1 - load)
					* (rpm < (p.idleRpm or 700) * 1.25 and 0.04 or 0.008)
				if shouldFire and self.rng:NextNumber() < idleMissChance then
					shouldFire = false
				end

				if shouldFire then
					local variation = 0.08 + 0.22 * idleRoughness
						* (1 - load) * (1 - load) + 0.5 * (1 - self.runningMix)
					local pressure = effectiveLoad * (0.35 + 0.65 * self.runningMix)
					self.p0[index] = pressure
						* (1 + variation * self.rng:NextNumber(-1, 1))
				else
					self.p0[index] = 0
				end
			end

			local jitter = self.evoJit[index] or 0
			if previousCylinderPhase < pressureStart + jitter
				and cylinderPhase >= pressureStart + jitter then
				if self.p0[index] > 0 then
					self.pe[index] = self.p0[index] * pressureProfile(pressureStart)
				else
					self.pe[index] = -0.02 * (1 - 0.6 * effectiveLoad)
				end
				self.crack[index] = crackStrength * self.pe[index]
				self.tick += 0.5
			end

			local envelope = pressureEnvelope(cylinderPhase - jitter, pulseRise, pressureStart)
			local pressurePulse = self.pe[index] * envelope
			self.pe[index] -= pressurePulse * self.kBlow

			local pistonPulse = 0
			if cylinderPhase > 180 and cylinderPhase < 360 then
				pistonPulse = envelope * (-phaseSine)
					* (0.004 + 0.01 * effectiveLoad) * rpmTexture
			end

			local excitation = pressurePulse + pistonPulse + self.crack[index] * envelope
			self.crack[index] *= self.crackDecay
			excitation += self.rng:NextNumber(-1, 1) * envelope
				* (pressurePulse * 0.22 + 3e-4 * effectiveLoad * rpmTexture)

			local headerOut = delayProcess(self.headers[index], excitation * 9)
			local bank = (event.collector ~= nil and event.collector or event.bank or 0) + 1
			if bank <= 1 then
				bank0 += headerOut
			else
				bank1 += headerOut
			end

			-- A low-order pressure contribution supplies engine-body weight; this is
			-- driven by cylinder pressure, not a constant bass oscillator.
			if cylinderPhase < 180 then
				pressureRumble += self.p0[index] * pressureProfile(cylinderPhase)
			end
			if cylinderPhase >= 540 then
				pressureRumble += 0.3 * effectiveLoad
					* pressureProfile(720 - cylinderPhase)
			end

			-- Intake resonance follows cylinder phase and engine speed. The filter
			-- below adds a broad acoustic formant instead of a fixed sine tone.
			local intakeStart = 345 - camShift * 0.7
			local intakeEnd = 600 + camShift * 0.7
			intakeTone += raisedSineWindow(cylinderPhase, intakeStart, intakeEnd)
				* math.max(0, phaseSine) * effectiveLoad * rpmTexture * camScale
		end

		self.tick *= self.tickDecay

		local rawHeaderLeft = bank0
		local rawHeaderRight = banks > 1 and bank1 or bank0
		local bodySource = rawHeaderLeft + rawHeaderRight
		local headerLeft = rawHeaderLeft
		local headerRight = rawHeaderRight

		-- Turbochargers attenuate the exhaust runner signal, but should not create
		-- a permanent, high-frequency noise layer across the engine sound.
		if p.induction == "turbo" then
			if banks > 1 then
				self.turboLp[1] += self.turboLpCoef * (headerLeft - self.turboLp[1])
				self.turboLp[2] += self.turboLpCoef * (headerRight - self.turboLp[2])
				headerLeft = self.turboLp[1] * 0.55
				headerRight = self.turboLp[2] * 0.55
			else
				self.turboLp[1] += self.turboLpCoef * (bodySource - self.turboLp[1])
				headerLeft = self.turboLp[1] * 0.45
				headerRight = headerLeft
			end
		end

		-- Run both exhaust paths for every engine. Even a single-bank engine needs
		-- slightly different left/right tube lengths to avoid a hard, mono, comb-like tone.
		local exhaustL = processExhaust(self.chains[1], headerLeft, load)
		local exhaustR = processExhaust(self.chains[2], headerRight, load)

		-- Match the reference radiation point: body coloration comes from the
		-- same header signal after turbo attenuation, not the raw unfiltered pulses.
		bodySource = headerLeft + headerRight

		-- Keep the lower body resonance from the cylinder pressure waveform.
		self.blockLp += self.blockLpCoef * (pressureRumble - self.blockLp)
		self.bodyLp[1] += self.bodyLpCoef[1] * (bodySource - self.bodyLp[1])
		self.bodyLp[2] += self.bodyLpCoef[2] * (self.bodyLp[1] - self.bodyLp[2])
		local bodyOut = self.bodyLp[2] * (0.55 * body)

		-- A broad intake formant sweeps from bass/midrange to a clearer wail as rpm rises.
		-- High-redline engines naturally reach a higher formant; low-revving engines do not.
		self.intakeCounter += 1
		local redline = math.max(1800, p.redline or 6800)
		local highRevFactor = clamp((redline - 2500) / 6500, 0, 1)
		local topFormantHz = clamp(350 + (redline - 4000) * 0.05, 380, 850)
		local rpmPosition = clamp(rpm / redline, 0, 1)
		local targetFormantHz = 210
			+ (topFormantHz - 210) * math.pow(rpmPosition, 1.2)
		if self.intakeCounter % 64 == 1
			or math.abs(targetFormantHz - self.intakeFormantHz) > 45 then
			self.intakeFormantHz += (targetFormantHz - self.intakeFormantHz) * 0.35
			setBandpass(self.intakeFormant, sampleRate, self.intakeFormantHz, 1.35)
		end

		local intakeNoise = noise * intakeTone
			* (0.12 + 0.14 * math.sqrt(load))
		self.intakeLp += self.intakeLpCoef * (intakeNoise - self.intakeLp)
		local intakeTube = delayProcess(self.intakeLine, self.intakeLp) + self.intakeLp
		local intakeResonance = processBiquad(self.intakeFormant, intakeTube)
		local defaultIntakeResonance = 0.24 + 0.28 * highRevFactor
		local intakeResonanceGain = clamp(p.intakeResonance or defaultIntakeResonance, 0, 1.5)
		local intake = intakeTube * 0.055 + intakeResonance * intakeResonanceGain * 0.11


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

		-- Turbo whine stays subtle; the airflow bed carries most of its identity.
		-- A loud harmonic oscillator was the main source of the synthetic "electric" whistle.
		boostWhine = 0
		if superWhine then
			local frequency = rpm / 60 * 11.2 * (p.whinePitch or 1)
			local phase = (self.audioTime * frequency) % 1
			boostWhine = (math.sin(phase * TAU) + 0.10 * math.sin(phase * TAU * 2))
				* (p.whine or 0) * load * math.pow(math.max(0, rpmFraction), 2) * 0.024
		elseif turboWhine and turbo > 0.015 then
			local frequency = (200 + 3200 * turbo) * (p.whinePitch or 1)
			self.turboPhase += frequency / sampleRate
			if self.turboPhase >= 1 then
				self.turboPhase -= math.floor(self.turboPhase)
			end
			local phase = self.turboPhase * TAU
			boostWhine = (math.sin(phase) + 0.16 * math.sin(phase * 2 + 0.12))
				* (p.whine or 0.2) * turbo * turbo * 0.012
		end

		self.turboNoiseHigh += self.turboNoiseHighCoef * (pinkNoise - self.turboNoiseHigh)
		self.turboNoiseLow += self.turboNoiseLowCoef * (pinkNoise - self.turboNoiseLow)
		self.whooshLp += 0.25 * (noise - self.whooshLp)
		if turboWhine then
			-- A restrained 350-2200 Hz airflow band, scaled by spool and load.
			local turbineAir = self.turboNoiseHigh - self.turboNoiseLow
			boostWhine += turbineAir * turbo * (0.045 + 0.055 * load)
				* (0.45 + 0.35 * (p.whine or 0.3))
		end

		local bov = 0
		if p.induction == "turbo" and self.bovEnvelope > 0.002 then
			local spool = clamp(turbo, 0, 1.2)
			if p.bov == "flutter" then
				-- A simple pressure-flow oscillator naturally changes pulse spacing
				-- as spool and engine load change; the airflow noise is band-limited.
				local flowScale = math.max(0.12, spool)
				local halfFlow = 0.5 * flowScale + 0.02
				local pressureForce = 0.6 * flowScale * flowScale
				local spring = 0.15 * flowScale * flowScale
				local flowRatio = self.bovFlow / halfFlow - 1
				local flowCurve
				if self.bovFlow >= 0 then
					flowCurve = spring + pressureForce
						* (1 + 1.5 * flowRatio - 0.5 * flowRatio * flowRatio * flowRatio)
				else
					local ratio = self.bovFlow / halfFlow
					flowCurve = spring + 0.5 * pressureForce * ratio * ratio
				end
				local scale = 1.5 * (0.5 + 0.5 * flowScale)
				local step = TAU * (p.flRate or 14) * 1.25
					* (0.35 + 0.65 * flowScale) / sampleRate
				local damping = (0.06 + 3 * load) * math.sqrt(math.max(0, self.bovPressure))
				local pressureStep = scale * (flowCurve - self.bovPressure) * step
				local flowStep = (self.bovFlow - damping) / scale * step
				self.bovFlow = clamp(self.bovFlow + pressureStep, -3, 3)
				self.bovPressure = clamp(self.bovPressure + flowStep, -0.5, 3)

				local negativeFlow = math.max(0, -self.bovFlow)
				local positiveFlow = math.max(0, self.bovFlow)
				local revTau = negativeFlow > self.bovRev and 0.009 or 0.014
				self.bovRev += (negativeFlow - self.bovRev)
					* (1 - math.exp(-1 / (revTau * sampleRate)))

				local stillReleasing = load > 0.2 or spool < 0.06
				local fadeTau = stillReleasing and 0.06 or 0.01
				local fadeTarget = stillReleasing and 0 or 1
				self.surgeFade += (fadeTarget - self.surgeFade)
					* (1 - math.exp(-1 / (fadeTau * sampleRate)))

				local pressureMix = 0.3 + 0.7 * math.min(1, load * 1.5)
				local surgeTarget = 0.35 + self.bovRev + positiveFlow * 0.3
				pressureMix += (surgeTarget - pressureMix) * self.surgeFade

				self.bovFilterCounter += 1
				if self.bovFilterCounter % 64 == 1 then
					local centreHz = clamp((p.flPitch or 650) * (0.3 + 0.7 * spool), 170, 2400)
					setBandpass(self.bovBp, sampleRate, centreHz, 5)
					setBandpass(self.bovBp2, sampleRate, clamp(p.flPitchEnd or 130, 70, 700), 4)
				end
				self.surgePhase += clamp(p.flPitch or 650, 170, 2400)
					* (0.3 + 0.7 * spool) / sampleRate
				if self.surgePhase >= 1 then
					self.surgePhase -= math.floor(self.surgePhase)
				end
				local surgeRadians = self.surgePhase * TAU
				local surgeTone = math.sin(surgeRadians)
					+ 0.45 * math.sin(surgeRadians * 2)
					+ 0.20 * math.sin(surgeRadians * 3)
					+ 0.10 * math.sin(surgeRadians * 4)
				local ventBase = (self.whooshLp * 0.6 + surgeTone * 0.25 * self.bovRev)
					* pressureMix * spool * spool
				local filteredVent = processBiquad(self.bovBp, ventBase) * 4
				local ventHiss = (noise - self.whooshLp) * pressureMix
					* spool * spool * 0.6 * (p.flHiss or 0.6)
				local ventTail = processBiquad(self.bovBp2, math.max(0, -flowStep) * 25 * spool)
				bov = (filteredVent + ventHiss + ventTail)
					* math.min(1, self.bovStart / 0.6) * 1.35 * self.surgeFade * (p.flLevel or 0.5)
			else
				-- Vent-style valves use a decaying pressure reservoir and broad airflow noise.
				self.ventP = math.max(0, self.ventP - (0.5 + 2.5 * load) / sampleRate)
				local openTarget = load < 0.12 and self.ventP > 0.04 and 1 or 0
				local openTau = openTarget > self.ventV and 0.025 or 0.05
				self.ventV += (openTarget - self.ventV)
					* (1 - math.exp(-1 / (openTau * sampleRate)))
				local jet = self.ventV * math.pow(math.max(0, self.ventP), 0.75)
				self.jetState += (jet - self.jetState)
					* (1 - math.exp(-1 / (0.004 * sampleRate)))
				self.bovFilterCounter += 1
				if self.bovFilterCounter % 64 == 1 then
					setBandpass(self.bovBp, sampleRate,
						clamp(1200 + 3500 * math.sqrt(math.min(1, self.ventP / math.max(0.1, p.boost or 1))), 500, 4200), 0.8)
				end
				bov = (processBiquad(self.bovBp, noise) * 2.2
					+ (noise - self.whooshLp) * 0.35) * self.jetState * 0.62 * (p.flLevel or 0.5)
			end
			self.bovEnvelope *= math.exp(-1 / (0.9 * sampleRate))
			if self.surgeFade < 0.01 and (load > 0.2 or spool < 0.06)
				and self.bovEnvelope < 0.01 then
				self.bovEnvelope = 0
				self.bovFlow = 0
				self.bovPressure = 0
				self.bovRev = 0
			end
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

		-- Reference-style mix: the exhaust is the main voice; the intake/body layers
		-- supply low-mid weight, and accessories sit around the engine rather than on top.
		local exhaustWeight = banks > 1 and 0.70 or 0.60
		local exhaustLeft = (exhaustL * exhaustWeight + exhaustR * (1 - exhaustWeight))
			* (1 - 0.75 * mic)
		local exhaustRight = (exhaustR * exhaustWeight + exhaustL * (1 - exhaustWeight))
			* (1 - 0.75 * mic)
		local tickSound = self.tick * noise * 0.012 * (1 - rpmFraction) * (1 - rpmFraction)
		local engineAux = self.blockLp * 1.2 + intake + tickSound
			+ (headerLeft + headerRight) * 0.02 + gearTone * 0.65
			+ ersTone + boostWhine + bov + pop
		local auxiliaryMix = 0.35 + 0.65 * mic
		local leftRaw = exhaustLeft + engineAux * auxiliaryMix + bodyOut + windLeft + tyre
		local rightRaw = exhaustRight + engineAux * auxiliaryMix + bodyOut + windRight + tyre * 0.98

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

		local leftSignal = leftRaw
		local rightSignal = rightRaw

		-- Mild DC blocking: keep the low engine modes while removing buffer drift.
		local leftDc = leftSignal - self.dcInput[1] + 0.998 * self.dcOutput[1]
		local rightDc = rightSignal - self.dcInput[2] + 0.998 * self.dcOutput[2]
		self.dcInput[1], self.dcInput[2] = leftSignal, rightSignal
		self.dcOutput[1], self.dcOutput[2] = leftDc, rightDc

		-- Soft, envelope-following output limiting inspired by the reference audio engine.
		-- A fixed saturator was exaggerating sharp edges and adding more "robot" harmonics.
		local master = p.master or 1
		local clipAmount = clamp(p.clip or 0.15, 0, 1)
		local leftOut = outputLimit(self, leftDc, 1, master, clipAmount)
		local rightOut = outputLimit(self, rightDc, 2, master, clipAmount)

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
