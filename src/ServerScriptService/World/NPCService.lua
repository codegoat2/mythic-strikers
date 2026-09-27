--[[
	MythicStrikers — NPCService
	Lightweight town population.

	WHY
	The prototype's "NPCs" were bobbing cylinders driven by the CLIENT, which
	meant every player simulated every NPC and none of them did anything. This
	moves the population to the server, animates it once per frame for all
	players, and drops simulation entirely for anyone far away.

	PERFORMANCE MODEL
	  • NPCs are single-part Models (body + head). No rigs, no pathfinding.
	  • Simulation runs on one shared Heartbeat, not per player.
	  • An NPC is only stepped while a player is within ACTIVE_RANGE of it.
	    Beyond that its transform is frozen, which is invisible at that distance
	    and removes the cost entirely.
	  • NPC count scales with graphics quality via Palette.Quality.NPCDetail.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage.Shared.Config.Palette)
local Kit     = require(script.Parent.BuildKit)

local NPCService = {}

-- Beyond this distance an NPC is not stepped at all.
local ACTIVE_RANGE = 160
-- Where the loop decides to re-evaluate, not every frame.
local SWEEP_INTERVAL = 0.25
local TICK = 1 / 30

-- Townsfolk palette. Muted everyday clothing so the population sits inside the
-- art direction; the only saturated NPC is the kit-wearing player figure.
local SHIRTS = {
	Palette.World.DeepBlue, Palette.World.Charcoal, Palette.World.ConcreteDark,
	Palette.World.WoodDark, Palette.World.SteelBlue, Palette.World.RenderCool,
	Palette.World.BrickSand, Palette.World.MetalDark,
}
local PANTS = {
	Palette.World.Charcoal, Palette.World.Navy, Palette.World.WoodDark,
	Palette.World.ConcreteDark, Palette.World.Graphite,
}
local SKINS = {
	Color3.fromRGB(240, 208, 178), Color3.fromRGB(214, 172, 138),
	Color3.fromRGB(178, 132, 100), Color3.fromRGB(142, 100, 74),
	Color3.fromRGB(108, 76, 58),
}
local HAIR = {
	Palette.World.Charcoal, Palette.World.WoodDark, Color3.fromRGB(120, 78, 44),
	Color3.fromRGB(60, 44, 36), Color3.fromRGB(190, 180, 160),
}

-- Anchor data. Each townsperson gets a behaviour so the population is not a
-- single mass of identical idle figures.
local BEHAVIOURS = {
	{ id = "Idle",    weight = 4 },
	{ id = "Wander",  weight = 3 },
	{ id = "Sit",     weight = 2 },
	{ id = "Watch",   weight = 2 },
	{ id = "Train",   weight = 2 },
}

local _npcs: { { model: Model, body: BasePart, home: Vector3,
	behaviour: string, phase: number, speed: number, radius: number } } = {}
local _accum = 0
local _sweepAccum = 0
local _bound = false
local _quality = "HIGH"

-- ─────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────

local function makeNPC(folder: Folder, name: string, pos: Vector3, seed: string, behaviour: string)
	local rng = Kit.seedFor(seed)
	local model = Kit.model(name, folder)
	local cf = CFrame.new(pos)

	local shirt = SHIRTS[rng:NextInteger(1, #SHIRTS)]
	local pants = PANTS[rng:NextInteger(1, #PANTS)]
	local skin = SKINS[rng:NextInteger(1, #SKINS)]
	local hair = HAIR[rng:NextInteger(1, #HAIR)]
	local scale = 0.95 + rng:NextNumber() * 0.18

	-- Legs
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(model, name .. "_Leg" .. s, Vector3.new(1.5, 4, 1.5),
			cf * CFrame.new(s * 0.9, 2 * scale, 0), pants, Palette.Materials.Smooth)
	end
	-- Torso
	local body = Kit.trim(model, name .. "_Body", Vector3.new(3.6, 4.4, 2),
		cf * CFrame.new(0, 6.2 * scale, 0), shirt, Palette.Materials.Smooth)
	-- Arms
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(model, name .. "_Arm" .. s, Vector3.new(1.2, 4, 1.2),
			cf * CFrame.new(s * 2.3, 6.2 * scale, 0), shirt, Palette.Materials.Smooth)
	end
	-- Head + hair
	Kit.trim(model, name .. "_Head", Vector3.new(2.4, 2.4, 2.2),
		cf * CFrame.new(0, 9.6 * scale, 0), skin, Palette.Materials.Smooth)
	Kit.trim(model, name .. "_Hair", Vector3.new(2.6, 1.1, 2.4),
		cf * CFrame.new(0, 10.7 * scale, 0), hair, Palette.Materials.Smooth)

	-- Kit-wearing NPCs: the town is a football town, so some of its people
	-- should be in club colours. This is a controlled accent, not a rainbow.
	if behaviour == "Train" then
		local club = if rng:NextNumber() < 0.5 then Palette.Teams.A.Primary else Palette.Teams.B.Primary
		Kit.trim(model, name .. "_Kit", Vector3.new(3.7, 3.4, 2.1),
			cf * CFrame.new(0, 6.2 * scale, 0), club, Palette.Materials.Smooth)
	end

	return {
		model = model,
		body = body,
		home = pos,
		behaviour = behaviour,
		phase = rng:NextNumber() * math.pi * 2,
		speed = 2.5 + rng:NextNumber() * 2.5,
		radius = 6 + rng:NextNumber() * 12,
	}
end

-- ─────────────────────────────────────────────
-- Behaviour
-- ─────────────────────────────────────────────

local function stepNPC(npc, t: number)
	local model = npc.model
	if not model or not model.Parent then return end
	local body = npc.body
	if not body or not body.Parent then return end

	-- The body's own CFrame is the NPC root. Everything else is welded visually
	-- by sharing the same build-time offset, so animating the root is enough
	-- as long as we restore the same relative layout. Simpler: move the whole
	-- model by pivoting on the body.
	local base = model:GetPivot()
	local p = npc.phase

	if npc.behaviour == "Idle" then
		-- Subtle breathing sway. Nothing more.
		local bob = math.sin(t * 1.4 + p) * 0.12
		model:PivotTo(base * CFrame.new(0, bob, 0))

	elseif npc.behaviour == "Wander" then
		-- Slow lissajous loop around the home point. Reads as a person ambling
		-- without needing any pathfinding or collision.
		local ax = math.sin(t * 0.35 * npc.speed * 0.4 + p) * npc.radius
		local az = math.cos(t * 0.28 * npc.speed * 0.4 + p * 1.7) * npc.radius
		local step = math.sin(t * 6 + p) * 0.28
		model:PivotTo(CFrame.new(npc.home.X + ax, npc.home.Y + step, npc.home.Z + az)
			* CFrame.Angles(0, t * 0.3 * npc.speed * 0.3 + p, 0))

	elseif npc.behaviour == "Sit" then
		-- Lowered and still, as if on a bench.
		local bob = math.sin(t * 1.1 + p) * 0.06
		model:PivotTo(CFrame.new(npc.home.X, npc.home.Y - 2.2 + bob, npc.home.Z))

	elseif npc.behaviour == "Watch" then
		-- Standing, turning slowly, as if watching something off to one side.
		model:PivotTo(CFrame.new(npc.home.X, npc.home.Y, npc.home.Z)
			* CFrame.Angles(0, math.sin(t * 0.25 + p) * 0.9 + p, 0))

	elseif npc.behaviour == "Train" then
		-- Jogging on the spot. Obviously a footballer, obviously cheap.
		local j = math.abs(math.sin(t * 4 + p)) * 0.7
		model:PivotTo(CFrame.new(
			npc.home.X + math.sin(t * 1.1 + p) * 4,
			npc.home.Y + j,
			npc.home.Z + math.cos(t * 0.9 + p) * 4
		) * CFrame.Angles(0, t * 2.2 + p, 0))
	end
end

-- ─────────────────────────────────────────────
-- Distance gating
-- ─────────────────────────────────────────────

--- Cheapest possible test: distance to the nearest player character root.
local function anyPlayerNear(pos: Vector3): boolean
	local players = Players:GetPlayers()
	for i = 1, #players do
		local char = players[i].Character
		if char then
			local root = char:FindFirstChild("HumanoidRootPart")
			if root and (root.Position - pos).Magnitude < ACTIVE_RANGE then
				return true
			end
		end
	end
	return false
end

-- ─────────────────────────────────────────────
-- Init
-- ─────────────────────────────────────────────

function NPCService.Init(quality: string?)
	NPCService._quality = quality or "HIGH"
	local detail = Palette.Quality[NPCService._quality] or Palette.Quality.HIGH
	local countScale = { [0] = 0.35, [1] = 0.7, [2] = 1.0, [3] = 1.0 }
	local count = math.floor(24 * (countScale[detail.NPCDetail] or 1))

	local lobby = workspace:WaitForChild("Lobby", 20)
	local anchors = {}
	if lobby then
		local tc = lobby:FindFirstChild("TownCentre")
		if tc then
			for _, d in ipairs(tc:GetChildren()) do
				if d:IsA("BasePart") and string.find(d.Name, "NPCAnchor_") then
					table.insert(anchors, d)
				end
			end
		end
	end

	if #anchors == 0 then
		warn("[NPCService] No NPC anchors found — town will feel empty. "
			.. "Is WorldBuilder running before NPCService.Init?")
		return
	end

	local folder = Kit.folder("NPCs", lobby)

	for i = 1, count do
		local anchor = anchors[((i - 1) % #anchors) + 1]
		if anchor and anchor.Parent then
			-- Pick a behaviour by seeded weight so the mix is stable per server.
			local key = string.format("npc_%d", i)
			local rng = Kit.seedFor(key)
			local total = 0
			for _, b in ipairs(BEHAVIOURS) do total += b.weight end
			local roll = rng:NextInteger(1, total)
			local acc = 0
			local behaviour = "Idle"
			for _, b in ipairs(BEHAVIOURS) do
				acc += b.weight
				if roll <= acc then behaviour = b.id break end
			end

			-- Jitter around the anchor so NPCs are not stacked on one point.
			local a = rng:NextNumber() * math.pi * 2
			local r = rng:NextNumber() * 6
			local pos = anchor.Position + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)

			local npc = makeNPC(folder, string.format("NPC_%02d", i), pos, key, behaviour)
			table.insert(_npcs, npc)
			-- Spawn them already in their idle pose so nothing pops on frame 1.
			stepNPC(npc, rng:NextNumber() * 10)
		end
	end

	if not _bound then
		_bound = true
		RunService.Heartbeat:Connect(function(dt)
			NPCService._tick(dt)
		end)
	end

	print(string.format("[NPCService] %d townsfolk placed in the town centre.", #_npcs))
end

function NPCService._tick(dt: number)
	if #_npcs == 0 then return end

	local t = os.clock()
	_accum += dt
	if _accum < TICK then return end
	_accum = 0

	-- Distance re-evaluation is far more expensive than the animation itself,
	-- so it runs on a slow sweep rather than every tick.
	_sweepAccum += TICK
	local resweep = false
	if _sweepAccum >= SWEEP_INTERVAL then
		_sweepAccum = 0
		resweep = true
	end

	for i = 1, #_npcs do
		local npc = _npcs[i]
		if resweep then
			npc._near = anyPlayerNear(npc.home)
		end
		if npc._near then
			stepNPC(npc, t)
		end
	end
end

function NPCService.SetQuality(quality: string)
	NPCService._quality = quality
end

function NPCService.GetCount(): number
	return #_npcs
end

return NPCService
-- resync
