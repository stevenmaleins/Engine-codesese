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
	return {
		data = buffer.create(RING_SIZE * 4),
		index = 0,
		delay = math.floor(clamp(delaySamples, 2, RING_SIZE - 2)),
		feedback = feedback,
		lp = 0,
		lpCoef = coefficient(sampleRate, lpCutoff),
	}
end

local function delayProcess(line, input)
	local readIndex = (line.index - line.delay) % RING_SIZE
	local delayed = buffer.readf32(line.data, readIndex * 4)
	line.lp += line.lpCoef * (delayed - line.lp)
	buffer.writef32(line.data, line.index * 4, input + line.feedback * line.lp)
	line.index = (line.index + 1) % RING_SIZE
	return delayed
end

local function newExhaustChain(params, sampleRate)
	local muffler = clamp(params.muffler or 0.3, 0, 1)
	local function delayMs(length)
		return 2 * math.max(0.05, length or 0.5) * sampleRate / SPEED_OF_SOUND
	end
	return {
		collector = makeDelay(delayMs(params.collectorLength), -0.45, 4500, sampleRate),
		chamber = makeDelay(delayMs(params.chamber), 0.6, 2500, sampleRate),
		tail = makeDelay(delayMs(params.tailLength), -0.38, 5000 - 2500 * muffler, sampleRate),
		muffler = muffler,
		chamberGain = params.chamberGain or 0.5,
		mufLp = 0,
		mufLpCoef = coefficient(sampleRate, 10000 - 7500 * muffler),
		air = 0,
		airCoef = coefficient(sampleRate, 5000),
		radLp = 0,
		radCoef = coefficient(sampleRate, 150),
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
	local differentiated = tail + (0.25 + 0.55 * load) * (tail - chain.previous)
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
		headers[index] = makeDelay(2 * length * sampleRate / SPEED_OF_SOUND, -0.55, 5500, sampleRate)
	end

	local chains = {
		newExhaustChain(params, sampleRate),
		newExhaustChain(params, sampleRate),
	}

	return setmetatable({
		params = params,
		sampleRate = sampleRate,
		phase = 0,
		phaseInitialized = false,
		audioTime = 0,
		pulseEnvelopes = table.create(math.max(1, #firing), 0),
		pulseDecay = math.exp(-1 / (0.018 * sampleRate)),
		headers = headers,
		chains = chains,
		rng = Random.new(17391),
		intakeLine = makeDelay(2 * (params.intakeLength or 0.3) * sampleRate / SPEED_OF_SOUND, -0.5, 2500, sampleRate),
		intakeLp = 0,
		intakeLpCoef = coefficient(sampleRate, 900),
		blockLp = 0,
		blockLpCoef = coefficient(sampleRate, 140),
		bodyLp = {0, 0},
		bodyLpCoef = {coefficient(sampleRate, 110), coefficient(sampleRate, 240)},
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
	if self.previousBoost - boost > 0.15 and p.induction == "turbo" and p.bov ~= "none" then
		self.bovEnvelope = math.max(self.bovEnvelope, self.previousBoost)
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
		local load = clamp(loadFrom + (loadTo - loadFrom) * alpha, 0, 1)
		local boost = math.max(0, boostFrom + (boostTo - boostFrom) * alpha)
		local turbo = math.max(0, turboFrom + (turboTo - turboFrom) * alpha)
		local omegaIn = math.max(0, omegaInFrom + (omegaInTo - omegaInFrom) * alpha)
		local shaftTorque = shaftFrom + (shaftTo - shaftFrom) * alpha
		local liftTime = math.max(0, liftFrom + (liftTo - liftFrom) * alpha)
		local cutBurst = math.max(0, cutBurstFrom + (cutBurstTo - cutBurstFrom) * alpha)
		local throttle = throttleFrom + (throttleTo - throttleFrom) * alpha
		local gear = state.gear or 0
		local gearRatio = gear > 0 and (p.gears[gear] or 1) or 1
		local kmh = speed * 3.6
		local intakeMix = 0.08 + load * 0.15
		local rpmFraction = clamp(rpm / math.max(1, p.redline), 0, 1.5)
		local boostWhine = 0
		local noise = self.rng:NextNumber(-1, 1)
		local pinkNoise = nextPinkNoise(self)
		self.audioTime += 1 / sampleRate
		local crankStep = rpm * 6 / sampleRate
		local oldPhase = self.phase
		self.phase += crankStep

		-- Cylinder exhaust excitation, with each runner having its own resonant delay.
		local bank0, bank1 = 0, 0
		for index, event in ipairs(p.firing) do
			local target = ((event.angle or 0) + 135) % cycle
			local oldCycle = math.floor((oldPhase - target) / cycle)
			local newCycle = math.floor((self.phase - target) / cycle)
			if newCycle > oldCycle then
				local firingStrength = state.running and 1 or (state.starter and 0.32 or 0.035)
				self.pulseEnvelopes[index] = math.max(
					self.pulseEnvelopes[index],
					firingStrength * (0.12 + 0.72 * load)
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
			local envelope = self.pulseEnvelopes[index]
			self.pulseEnvelopes[index] = envelope * self.pulseDecay
			local cylinderNoise = self.rng:NextNumber(-1, 1) * 0.08
			local eventPhase = ((self.phase - (event.angle or 0)) % cycle) / cycle
			local resonant = math.sin(eventPhase * TAU * 2) * 0.18
			local excitation = (envelope * (cylinderNoise * 0.56 + resonant + 0.2))
			local headerOut = delayProcess(self.headers[index], excitation)
			local bank = (event.collector ~= nil and event.collector or event.bank or 0) + 1
			if bank <= 1 then
				bank0 += headerOut
			else
				bank1 += headerOut
			end
		end

		local exhaustL = processExhaust(self.chains[1], bank0, load)
		local exhaustR
		if banks > 1 then
			exhaustR = processExhaust(self.chains[2], bank1, load)
		else
			exhaustR = exhaustL
		end

		-- Intake tract: speed/load-scaled stochastic induction noise through a pipe delay.
		local intakeNoise = noise * (0.015 + load * 0.08) * (0.15 + rpmFraction)
		self.intakeLp += self.intakeLpCoef * (intakeNoise - self.intakeLp)
		local intake = (delayProcess(self.intakeLine, self.intakeLp) + self.intakeLp) * intakeMix

		-- Low frequency block vibration and firing tick.
		local rawBody = (exhaustL + exhaustR) * 0.5
		self.blockLp += self.blockLpCoef * (rawBody - self.blockLp)
		local bodySignal = self.blockLp * 1.2 * body * 0.22
		self.bodyLp[1] += self.bodyLpCoef[1] * (bodySignal - self.bodyLp[1])
		self.bodyLp[2] += self.bodyLpCoef[2] * (bodySignal - self.bodyLp[2])
		local bodyOut = self.bodyLp[1] * 0.55 + self.bodyLp[2] * 0.22

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

		-- Supercharger and turbo tones. Their pitch follows engine speed/spool state.
		boostWhine = 0
		if superWhine then
			local frequency = rpm / 60 * 11.2 * (p.whinePitch or 1)
			local phase = (self.audioTime * frequency) % 1
			boostWhine = (math.sin(phase * TAU) + 0.3 * math.sin(phase * TAU * 2))
				* (p.whine or 0) * load * math.pow(math.max(0, rpmFraction), 2) * 0.035
		elseif turboWhine and turbo > 0.02 then
			local frequency = (200 + 3200 * turbo) * (p.whinePitch or 1)
			self.bovPhase += frequency / sampleRate
			if self.bovPhase >= 1 then self.bovPhase -= 1 end
			boostWhine = (math.sin(self.bovPhase * TAU) + 0.3 * math.sin(self.bovPhase * TAU * 2))
				* (p.whine or 0) * turbo * turbo * 0.035
		end

		local bov = 0
		if self.bovEnvelope > 0.002 then
			local hiss = self.rng:NextNumber(-1, 1)
			self.bovFlutterPhase += (p.flRate or 14) * 1.25 / sampleRate
			if self.bovFlutterPhase >= 1 then self.bovFlutterPhase -= 1 end
			local flutter = p.bov == "flutter" and math.sin(self.bovFlutterPhase * TAU) or 0
			bov = (hiss * (p.flHiss or 0.6) + flutter * 0.45) * self.bovEnvelope * (p.flLevel or 0.5) * 0.12
			self.bovEnvelope *= math.exp(-1 / ((p.flDur or 1.2) * sampleRate))
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
		local leftOut = softClip((leftRaw * micMix + exhaustL * engineMix * 0.20) * master, 1.4)
		local rightOut = softClip((rightRaw * micMix + exhaustR * engineMix * 0.20) * master, 1.4)

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
