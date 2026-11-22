-- AudioOutput.lua
-- Replaceable Roblox audio graph adapter for the procedural PCM synthesizer.
-- AudioStreamWriter currently works only in local Studio sessions, not Team Create.
-- No other module depends on AudioStreamWriter.

local RunService = game:GetService("RunService")

local AudioOutput = {}
AudioOutput.__index = AudioOutput

local MAX_RENDER_BLOCK = 512

local function makeListenerOutput(listener)
	local existingWires = {}
	local ok, result = pcall(function()
		return listener:GetConnectedWires("Output")
	end)
	if ok then
		existingWires = result
	end

	if #existingWires > 0 then
		return nil, nil, false
	end

	local deviceOutput = Instance.new("AudioDeviceOutput")
	deviceOutput.Name = "VehicleAudioDeviceOutput"

	local wire = Instance.new("Wire")
	wire.Name = "VehicleAudioListenerWire"
	wire.SourceInstance = listener
	wire.SourceName = "Output"
	wire.TargetInstance = deviceOutput
	wire.TargetName = "Input"
	wire.Parent = listener
	deviceOutput.Parent = listener

	if not wire.Connected then
		wire:Destroy()
		deviceOutput:Destroy()
		error("AudioListener could not connect to AudioDeviceOutput")
	end

	return deviceOutput, wire, true
end

function AudioOutput.Start(synth, emitterParent, options)
	options = options or {}
	assert(type(synth) == "table" and type(synth.RenderBlock) == "function",
		"AudioOutput.Start expects SoundSynthesis")
	assert(typeof(emitterParent) == "Instance",
		"Pass a Camera, BasePart, PVInstance or Attachment as emitterParent")

	if not RunService:IsStudio() then
		return nil, "AudioStreamWriter is currently documented as Studio-only. This output adapter is for local Studio testing."
	end

	local okWriter, writerOrError = pcall(function()
		return Instance.new("AudioStreamWriter")
	end)
	if not okWriter then
		return nil, "AudioStreamWriter is unavailable in this Studio build: " .. tostring(writerOrError)
	end

	local writer = writerOrError
	local emitter
	local writerWire
	local listener
	local deviceOutput
	local listenerWire
	local ownsListener = false
	local ownsListenerOutput = false

	local setupOk, setupError = pcall(function()
		writer.Layout = Enum.AudioChannelLayout.Stereo
		writer.WindowSize = options.windowSize or Enum.AudioWindowSize.Medium
		writer.Parent = workspace

		emitter = Instance.new("AudioEmitter")
		emitter.Name = options.emitterName or "VehicleAudioEmitter"
		emitter.Parent = emitterParent

		writerWire = Instance.new("Wire")
		writerWire.Name = "VehicleAudioWriterWire"
		writerWire.SourceInstance = writer
		writerWire.SourceName = "Output"
		writerWire.TargetInstance = emitter
		writerWire.TargetName = "Input"
		writerWire.Parent = emitter

		if not writerWire.Connected then
			error("AudioStreamWriter did not connect to AudioEmitter")
		end

		local listenerParent = options.listenerParent or workspace.CurrentCamera
		assert(listenerParent, "No listener parent available; wait for CurrentCamera")
		listener = listenerParent:FindFirstChildOfClass("AudioListener")
		if not listener then
			listener = Instance.new("AudioListener")
			listener.Name = "VehicleAudioTestListener"
			listener.Parent = listenerParent
			ownsListener = true
		end

		deviceOutput, listenerWire, ownsListenerOutput = makeListenerOutput(listener)
	end)

	if not setupOk then
		if writerWire then writerWire:Destroy() end
		if emitter then emitter:Destroy() end
		if listenerWire then listenerWire:Destroy() end
		if deviceOutput then deviceOutput:Destroy() end
		if ownsListener and listener then listener:Destroy() end
		writer:Destroy()
		return nil, "Audio graph setup failed: " .. tostring(setupError)
	end

	local self = setmetatable({
		writer = writer,
		emitter = emitter,
		writerWire = writerWire,
		listener = listener,
		listenerWire = listenerWire,
		deviceOutput = deviceOutput,
		ownsListener = ownsListener,
		ownsListenerOutput = ownsListenerOutput,
		synth = synth,
		sampleRate = writer.SampleRate or 48000,
		frameRemainder = 0,
		running = true,
		framesWritten = 0,
		blocksWritten = 0,
		framesDropped = 0,
		lastError = nil,
	}, AudioOutput)

	if type(synth.SetSampleRate) == "function" then
		synth:SetSampleRate(self.sampleRate)
	end

	print(string.format("[VehicleAudio] Audio output connected (%d Hz, stereo)", self.sampleRate))
	return self
end

-- Call once per simulation update. Rendering exactly dt * sampleRate keeps the
-- procedural oscillator/DSP clock aligned with the engine state update.
function AudioOutput:WriteForDelta(state, dt)
	if not self.running or type(state) ~= "table" then
		return 0
	end

	dt = math.max(0, math.min(0.1, dt or 0))
	self.frameRemainder += dt * self.sampleRate
	local framesNeeded = math.floor(self.frameRemainder)
	self.frameRemainder -= framesNeeded

	local totalWritten = 0
	local totalFramesForDelta = framesNeeded
	local renderedFramesForDelta = 0
	local previousState = self.synth.previousState or state
	while framesNeeded > 0 and self.running do
		local spaceOk, available = pcall(function()
			return self.writer:Space()
		end)
		if not spaceOk then
			self.lastError = tostring(available)
			warn("[VehicleAudio] AudioStreamWriter:Space failed: " .. self.lastError)
			self:Stop()
			break
		end
		if available <= 0 then
			self.framesDropped += framesNeeded
			break
		end

		local blockFrames = math.min(framesNeeded, available, MAX_RENDER_BLOCK)
		local alphaStart = totalFramesForDelta > 0
			and (renderedFramesForDelta / totalFramesForDelta) or 0
		local alphaEnd = totalFramesForDelta > 0
			and ((renderedFramesForDelta + blockFrames) / totalFramesForDelta) or 1
		local renderOk, left, right = pcall(function()
			return self.synth:RenderBlock(state, blockFrames, previousState, alphaStart, alphaEnd)
		end)
		if not renderOk then
			self.lastError = tostring(left)
			warn("[VehicleAudio] Sound synthesis failed: " .. self.lastError)
			self:Stop()
			break
		end

		local writeOk, written = pcall(function()
			return self.writer:Write({ left, right })
		end)
		if not writeOk then
			self.lastError = tostring(written)
			warn("[VehicleAudio] AudioStreamWriter:Write failed: " .. self.lastError)
			self:Stop()
			break
		end
		if written <= 0 then
			self.framesDropped += framesNeeded
			break
		end

		self.blocksWritten += 1
		self.framesWritten += written
		totalWritten += written
		renderedFramesForDelta += blockFrames
		framesNeeded -= written
		if written < blockFrames then
			-- The writer consumed fewer samples than the DSP rendered; count the short write.
			self.framesDropped += blockFrames - written
			framesNeeded = math.max(0, framesNeeded - (blockFrames - written))
		end
	end

	if type(self.synth.CommitState) == "function" then
		self.synth:CommitState(state)
	end
	return totalWritten
end

function AudioOutput:GetStats()
	return {
		sampleRate = self.sampleRate,
		blocksWritten = self.blocksWritten,
		framesWritten = self.framesWritten,
		framesDropped = self.framesDropped,
		lastError = self.lastError,
	}
end

function AudioOutput:Stop()
	if not self.running then
		return
	end
	self.running = false
	if self.writerWire then self.writerWire:Destroy() end
	if self.emitter then self.emitter:Destroy() end
	if self.ownsListenerOutput then
		if self.listenerWire then self.listenerWire:Destroy() end
		if self.deviceOutput then self.deviceOutput:Destroy() end
	end
	if self.ownsListener and self.listener then
		self.listener:Destroy()
	end
	if self.writer then self.writer:Destroy() end
end

return AudioOutput
