-- Luau port of the source module's firing-order generator.
-- Angles are crank degrees; a 4-stroke cycle uses 720 degrees.

local EngineFiring = {}
local EPSILON = 1e-9

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function cyclicGaps(sortedAngles, cycle)
	local gaps = {}
	for index = 1, #sortedAngles do
		local nextAngle
		if index < #sortedAngles then
			nextAngle = sortedAngles[index + 1]
		else
			nextAngle = sortedAngles[1] + cycle
		end
		gaps[index] = nextAngle - sortedAngles[index]
	end
	return gaps
end

local function variance(values)
	if #values < 2 then
		return 0
	end
	local mean = 0
	for _, value in ipairs(values) do
		mean += value
	end
	mean /= #values
	local total = 0
	for _, value in ipairs(values) do
		local delta = value - mean
		total += delta * delta
	end
	return total / #values
end

local function buildCandidates(config)
	local cylinders = config.cylinders
	local layout = config.layout or "inline"
	local crank = config.crank or "even"
	local bankAngle = config.bankAngle or 0

	if layout == "rotary" then
		local events = {}
		for rotor = 0, cylinders - 1 do
			for face = 0, 2 do
				table.insert(events, {
					angle = 360 * face + 360 * rotor / cylinders,
					bank = rotor % 2,
					cyl = 3 * rotor + face,
				})
			end
		end
		table.sort(events, function(a, b)
			if a.angle == b.angle then
				return a.cyl < b.cyl
			end
			return a.angle < b.angle
		end)
		return events
	end

	local isVOrFlat = layout ~= "inline"
	if crank == "even" or (layout == "inline" and crank == "shared") then
		local events = {}
		for cylinder = 0, cylinders - 1 do
			table.insert(events, {
				angle = 720 * cylinder / cylinders,
				bank = isVOrFlat and (cylinder % 2) or 0,
				cyl = cylinder,
			})
		end
		return events
	end

	local bases = {}
	if isVOrFlat then
		local perBank = math.ceil(cylinders / 2)
		local offset = layout == "flat" and 0 or bankAngle
		local step = (crank == "cross" or layout == "flat") and (360 / perBank) or (720 / perBank)
		for cylinder = 0, perBank - 1 do
			local baseAngle = (cylinder * step) % 360
			table.insert(bases, { base = baseAngle, bank = 0, cyl = #bases })
			if #bases < cylinders then
				table.insert(bases, { base = (baseAngle + offset) % 360, bank = 1, cyl = #bases })
			end
		end
	else
		for cylinder = 0, cylinders - 1 do
			table.insert(bases, {
				base = (360 * cylinder / cylinders) % 360,
				bank = 0,
				cyl = cylinder,
			})
		end
	end

	-- The source evaluates every possible 360-degree phase choice and chooses
	-- the arrangement with the widest minimum firing interval. Ties are
	-- resolved by bank-gap variance, then whole-engine gap variance.
	local bestAngles = nil
	local bestMinGap = -math.huge
	local bestNegativeBankVariance = -math.huge
	local bestNegativeTotalVariance = -math.huge
	local combinations = 2 ^ cylinders

	for mask = 0, combinations - 1 do
		local candidateAngles = table.create(cylinders)
		local candidateByCylinder = table.create(cylinders)
		for cylinder = 0, cylinders - 1 do
			local phaseBit = math.floor(mask / (2 ^ cylinder)) % 2
			local angle = (bases[cylinder + 1].base + phaseBit * 360) % 720
			candidateAngles[cylinder + 1] = angle
			candidateByCylinder[cylinder + 1] = {
				angle = angle,
				bank = bases[cylinder + 1].bank,
				cyl = cylinder,
			}
		end

		table.sort(candidateAngles)
		local allGaps = cyclicGaps(candidateAngles, 720)
		local minGap = math.huge
		for _, gap in ipairs(allGaps) do
			minGap = math.min(minGap, gap)
		end

		local bankVariance = 0
		for bank = 0, 1 do
			local bankAngles = {}
			for _, event in ipairs(candidateByCylinder) do
				if event.bank == bank then
					table.insert(bankAngles, event.angle)
				end
			end
			table.sort(bankAngles)
			if #bankAngles > 1 then
				bankVariance += variance(cyclicGaps(bankAngles, 720))
			end
		end

		local negativeBankVariance = -bankVariance
		local negativeTotalVariance = -variance(allGaps)
		local better = false
		if minGap > bestMinGap then
			better = true
		elseif minGap == bestMinGap then
			if negativeBankVariance > bestNegativeBankVariance + EPSILON then
				better = true
			elseif math.abs(negativeBankVariance - bestNegativeBankVariance) <= EPSILON
				and negativeTotalVariance > bestNegativeTotalVariance + EPSILON then
				better = true
			end
		end

		if better then
			bestMinGap = minGap
			bestNegativeBankVariance = negativeBankVariance
			bestNegativeTotalVariance = negativeTotalVariance
			bestAngles = candidateByCylinder
		end
	end

	table.sort(bestAngles, function(a, b)
		if a.angle == b.angle then
			return a.cyl < b.cyl
		end
		return a.angle < b.angle
	end)
	return bestAngles
end

function EngineFiring.Generate(config)
	assert(type(config) == "table", "EngineFiring.Generate expects a preset table")
	local cylinders = tonumber(config.cylinders)
	assert(cylinders and cylinders >= 1 and cylinders <= 16, "cylinders must be between 1 and 16")

	local normalized = table.clone(config)
	normalized.layout = normalized.layout or "inline"
	normalized.crank = normalized.crank or "even"
	if cylinders > 1 and normalized.layout ~= "inline" and cylinders % 2 == 1 and normalized.crank ~= "even" then
		normalized.crank = "even"
	end

	local events = buildCandidates(normalized)
	if normalized.headers == "crossover" and normalized.layout ~= "inline" then
		for index, event in ipairs(events) do
			event.collector = (index - 1) % 2
		end
	end
	return events
end

function EngineFiring.GetCycle(config)
	return config.layout == "rotary" and 1080 or 720
end

return EngineFiring
