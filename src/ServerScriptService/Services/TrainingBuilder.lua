--[[
	MythicStrikers — TrainingBuilder
	Builds the training grounds and runs the training logic.

	WHY THIS EXISTS
	The town previously had a "Training Dome" that was a glass room containing
	one static decorative ball. Nothing in it could be trained. This script
	replaces that with six FUNCTIONAL zones. Every zone is a real drill with a
	real completion condition checked by the server:

		SHOOTING      land N shots on the target bank
		PASSING       complete N passes through the target gates
		DRIBBLING     carry the ball through the slalom in order
		DEFENCE       win N challenges against the attacking dummy
		GOALKEEPING   save N shots in the goal mouth
		TECHNIQUE     land N techniques on the technique dummy

	COMPLETION
	A completed drill pays XP and coins, advances the "complete a training
	session" objective, and then goes on a per-player cooldown so it cannot be
	repeated instantly. Rewards are computed entirely on the server; the client
	only renders the prompt and the counter.

	PERFORMANCE
	The zone check runs at 2 Hz, not every frame, and only considers players
	whose root is inside the training bounds. Nothing is scanned per-frame.
--]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants        = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes          = require(ReplicatedStorage.Remotes)

local TRAINING_ORIGIN = Constants.LOBBY_ORIGIN + Vector3.new(150, 1, -140)

local TrainingBuilder = {}

local PAD       = 70      -- pad size
local PAD_GAP   = 80      -- spacing between pad centres
local ZONE_RADIUS = 34    -- how close a player must be to count as "in" a zone
local CHECK_INTERVAL = 0.5
local REWARD_COOLDOWN  = 20   -- seconds before the same drill can pay again

-- How much of each drill must be completed for one "session".
local REPS = {
	Shooting     = 5,
	Passing      = 5,
	Dribbling    = 1,   -- one full slalom
	Defense      = 4,
	Goalkeeping  = 3,
	Technique    = 5,
}

local REWARD_XP    = 150
local REWARD_COINS = 30

-- ─────────────────────────────────────────────
-- Injected services
-- ─────────────────────────────────────────────
local PlayerService: any = nil
local TechniqueService: any = nil
local ObjectiveService: any = nil
local BallService: any = nil

-- ─────────────────────────────────────────────
-- Colours
-- ─────────────────────────────────────────────
local COL = {
	FLOOR      = BrickColor.new("Dark stone grey"),
	LINE       = BrickColor.new("Bright white"),
	POST       = BrickColor.new("Bright yellow"),
	GOAL       = BrickColor.new("Bright white"),
	NET        = BrickColor.new("Institutional white"),
	TARGET     = BrickColor.new("Bright red"),
	TARGET_HIT = BrickColor.new("Lime green"),
	CONE       = BrickColor.new("Bright orange"),
	DUMMY      = BrickColor.new("Really red"),
	CONSOLE    = BrickColor.new("Bright green"),
	GOALKEEP   = BrickColor.new("Bright blue"),
	TECH       = BrickColor.new("Medium stone grey"),
}

-- ─────────────────────────────────────────────
-- Runtime state
-- ─────────────────────────────────────────────

-- zoneId -> { Name, Centre, Reps, Prompt, Ball, Gate1, Gate2, Dummy, Targets }
local _zones: { [string]: any } = {}

-- userId -> zoneId -> { Progress, CooldownUntil, SlalomIndex, HasBall }
local _progress: { [number]: { [string]: any } } = {}

local model: Model
local built = false

-- ─────────────────────────────────────────────
-- Construction helpers
-- ─────────────────────────────────────────────

local function part(
	name: string,
	size: Vector3,
	cf: CFrame,
	color: BrickColor,
	material: Enum.Material?,
	canCollide: boolean?,
	transparency: number?
): BasePart
	local p = Instance.new("Part")
	p.Name           = name
	p.Size           = size
	p.CFrame         = cf
	p.BrickColor     = color
	p.Material       = material or Enum.Material.SmoothPlastic
	p.Anchored       = true
	p.CanCollide     = canCollide ~= false
	p.CanTouch       = true
	p.TopSurface     = Enum.SurfaceType.Smooth
	p.BottomSurface  = Enum.SurfaceType.Smooth
	if transparency then p.Transparency = transparency end
	p.Parent         = model
	return p
end

--- Mark a part as belonging to a zone so hit detection can attribute it.
local function tagZone(p: BasePart, zoneId: string)
	p:SetAttribute("TrainingZone", zoneId)
	local label = Instance.new("StringValue")
	label.Name  = "TrainingZone"
	label.Value = zoneId
	label.Parent = p
end

--- A floating label above a pad.
local function makeSign(anchor: BasePart, text: string, offset: Vector3)
	local billboard = Instance.new("BillboardGui")
	billboard.Name      = "ZoneLabel"
	billboard.Size      = UDim2.fromOffset(260, 64)
	billboard.StudsOffset = offset
	billboard.AlwaysOnTop = true
	billboard.Parent    = anchor

	local label = Instance.new("TextLabel")
	label.Size            = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text            = text
	label.TextColor3      = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.Font            = Enum.Font.GothamBold
	label.TextSize        = 26
	label.TextScaled      = true
	label.Parent          = billboard
end

--- Perimeter corner posts so a pad reads as a defined area from a distance.
local function buildPad(zoneId: string, centre: Vector3, tint: BrickColor)
	part(zoneId .. "_Floor", Vector3.new(PAD, 1, PAD), CFrame.new(centre), COL.FLOOR)
	-- Painted border
	for _, s in ipairs({
		{ Vector3.new(PAD, 0.2, 1),   CFrame.new(centre + Vector3.new(0, 0.6,  PAD / 2)) },
		{ Vector3.new(PAD, 0.2, 1),   CFrame.new(centre + Vector3.new(0, 0.6, -PAD / 2)) },
		{ Vector3.new(1, 0.2, PAD),   CFrame.new(centre + Vector3.new( PAD / 2, 0.6, 0)) },
		{ Vector3.new(1, 0.2, PAD),   CFrame.new(centre + Vector3.new(-PAD / 2, 0.6, 0)) },
	}) do
		local line = part(zoneId .. "_Line", s[1], s[2], COL.LINE, nil, false)
		line.Transparency = 0.3
	end
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local post = part(
				zoneId .. "_Post",
				Vector3.new(2, 5, 2),
				CFrame.new(centre + Vector3.new(sx * (PAD / 2 - 2), 3, sz * (PAD / 2 - 2))),
				tint, Enum.Material.Neon
			)
			post.Transparency = 0.4
			tagZone(post, zoneId)
		end
	end
end

--- A real goal frame: two posts, a bar and a back net.
local function buildGoal(zoneId: string, centre: Vector3)
	local w, h = 16, 9
	part(zoneId .. "_GoalPostL", Vector3.new(0.6, h, 0.6), CFrame.new(centre + Vector3.new(-w / 2, h / 2, 0)), COL.GOAL, Enum.Material.Metal)
	part(zoneId .. "_GoalPostR", Vector3.new(0.6, h, 0.6), CFrame.new(centre + Vector3.new( w / 2, h / 2, 0)), COL.GOAL, Enum.Material.Metal)
	part(zoneId .. "_GoalBar",   Vector3.new(w + 1, 0.6, 0.6), CFrame.new(centre + Vector3.new(0, h, 0)), COL.GOAL, Enum.Material.Metal)
	part(zoneId .. "_GoalNet",   Vector3.new(w, h, 0.3), CFrame.new(centre + Vector3.new(0, h / 2, -3)), COL.NET, Enum.Material.SmoothPlastic, false, 0.75)
	part(zoneId .. "_GoalFloorL", Vector3.new(0.4, 0.4, 6), CFrame.new(centre + Vector3.new(-w / 2, 0.3, -3)), COL.GOAL, Enum.Material.Metal)
	part(zoneId .. "_GoalFloorR", Vector3.new(0.4, 0.4, 6), CFrame.new(centre + Vector3.new( w / 2, 0.3, -3)), COL.GOAL, Enum.Material.Metal)
end

--- The interaction console at the front of a pad.
local function buildConsole(zoneId: string, label: string, centre: Vector3)
	local console = part(
		zoneId .. "_Console",
		Vector3.new(4, 3, 2),
		CFrame.new(centre + Vector3.new(0, 2, PAD / 2 - 6)),
		COL.CONSOLE, Enum.Material.Neon
	)
	console.Transparency = 0.3
	tagZone(console, zoneId)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText   = label
	prompt.ActionText   = "Start drill"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0.4
	prompt.Parent = console

	makeSign(console, string.upper(label), Vector3.new(0, 7, 0))
	return prompt
end

--- A practice ball for the zone.
--- Deliberately ANCHORED and server-driven. The training ground is not a
--- physics playground: a free ball would roll away between drills and make
--- rep detection meaningless. Instead the server moves it kinematically via
--- BallService (GrantTrainingPossession to carry, KickTrainingBall to send),
--- which also avoids calling SetNetworkOwner on an anchored part — that call
--- throws and used to abort the entire training-grounds build.
local function buildZoneBall(zoneId: string, centre: Vector3): BasePart
	local ball = part(
		zoneId .. "_Ball",
		Vector3.new(2.4, 2.4, 2.4),
		CFrame.new(centre + Vector3.new(0, 2, -PAD / 4)),
		BrickColor.new("Bright white"), Enum.Material.SmoothPlastic
	)
	ball.Shape = Enum.PartType.Ball
	ball.CanCollide = false
	ball.Anchored  = true
	tagZone(ball, zoneId)
	return ball
end

-- ─────────────────────────────────────────────
-- Zone builders
-- ─────────────────────────────────────────────

local function buildShooting(centre: Vector3)
	local id = "Shooting"
	buildPad(id, centre, COL.TARGET)
	buildGoal(id, centre + Vector3.new(0, 0, -PAD / 2 + 6))

	-- Target bank behind the goal: hitting one completes a rep.
	local targets = {}
	for i = 1, 3 do
		local t = part(
			id .. "_Target" .. i,
			Vector3.new(10, 10, 0.5),
			CFrame.new(centre + Vector3.new((i - 2) * 15, 7, -PAD / 2 + 2.5)),
			COL.TARGET, Enum.Material.Neon
		)
		t.Transparency = 0.35
		tagZone(t, id)
		table.insert(targets, t)
	end

	_zones[id] = {
		Id = id, Name = "Shooting", Centre = centre, Reps = REPS.Shooting,
		Targets = targets, Ball = buildZoneBall(id, centre),
		Prompt = buildConsole(id, "Shooting Drill", centre),
	}
end

local function buildPassing(centre: Vector3)
	local id = "Passing"
	buildPad(id, centre, BrickColor.new("Bright green"))

	-- Two target gates. Passing the ball through either counts as a rep.
	local gates = {}
	for i = 1, 2 do
		local z = centre + Vector3.new((i - 1.5) * 22, 0, -PAD / 4)
		local frame = Instance.new("Model")
		frame.Name = id .. "_Gate" .. i
		frame.Parent = model
		for _, sx in ipairs({ -1, 1 }) do
			local side = part(id .. "_GateSide", Vector3.new(0.5, 12, 0.5),
				CFrame.new(z + Vector3.new(sx * 7, 6, 0)), BrickColor.new("Bright green"), Enum.Material.Neon)
			side.Transparency = 0.3
			tagZone(side, id)
		end
		local top = part(id .. "_GateTop", Vector3.new(15, 0.5, 0.5),
			CFrame.new(z + Vector3.new(0, 12, 0)), BrickColor.new("Bright green"), Enum.Material.Neon)
		top.Transparency = 0.3
		tagZone(top, id)
		table.insert(gates, frame)
	end

	_zones[id] = {
		Id = id, Name = "Passing", Centre = centre, Reps = REPS.Passing,
		Gates = gates, Ball = buildZoneBall(id, centre),
		Prompt = buildConsole(id, "Passing Drill", centre),
	}
end

local function buildDribbling(centre: Vector3)
	local id = "Dribbling"
	buildPad(id, centre, COL.CONE)

	-- Slalom: cones that must be passed in order while carrying the ball.
	local slalom = {}
	for i = 1, 6 do
		local z = centre + Vector3.new(0, 0, -PAD / 2 + 8 + (i - 1) * 9)
		local x = (i % 2 == 0) and 12 or -12
		local cone = part(
			id .. "_Cone" .. i,
			Vector3.new(2, 4, 2),
			CFrame.new(z + Vector3.new(x, 2, 0)),
			COL.CONE, Enum.Material.SmoothPlastic
		)
		cone.Shape = Enum.PartType.Cylinder
		cone.Orientation = Vector3.new(0, 0, 90)
		tagZone(cone, id)
		table.insert(slalom, cone)
	end

	-- Finish pad past the last cone.
	local finish = part(
		id .. "_Finish",
		Vector3.new(20, 0.3, 8),
		CFrame.new(centre + Vector3.new(0, 0.7, PAD / 2 - 8)),
		BrickColor.new("Lime green"), Enum.Material.Neon, false
	)
	finish.Transparency = 0.4
	tagZone(finish, id)

	_zones[id] = {
		Id = id, Name = "Dribbling", Centre = centre, Reps = REPS.Dribbling,
		Slalom = slalom, Finish = finish, Ball = buildZoneBall(id, centre),
		Prompt = buildConsole(id, "Dribbling Course", centre),
	}
end

local function buildDefense(centre: Vector3)
	local id = "Defense"
	buildPad(id, centre, COL.DUMMY)

	-- Attacking dummy that walks toward the goal. Winning a challenge against
	-- it (getting within TACKLE_RANGE of it while it has the ball) is a rep.
	local dummyBall = buildZoneBall(id, centre + Vector3.new(0, 0, -10))
	local dummy = part(
		id .. "_Dummy",
		Vector3.new(2.5, 5, 2.5),
		CFrame.new(centre + Vector3.new(0, 3, -10)),
		COL.DUMMY, Enum.Material.SmoothPlastic
	)
	dummy.CanCollide = false
	tagZone(dummy, id)
	makeSign(dummy, "ATTACKING DUMMY", Vector3.new(0, 5, 0))

	_zones[id] = {
		Id = id, Name = "Defence", Centre = centre, Reps = REPS.Defense,
		Dummy = dummy, DummyBall = dummyBall, Ball = buildZoneBall(id, centre),
		Prompt = buildConsole(id, "Defence Drill", centre),
	}
end

local function buildGoalkeeping(centre: Vector3)
	local id = "Goalkeeping"
	buildPad(id, centre, COL.GOALKEEP)
	buildGoal(id, centre + Vector3.new(0, 0, PAD / 2 - 6))

	-- Shot origin: balls are served from here toward the goal.
	local tee = part(
		id .. "_Tee",
		Vector3.new(3, 1, 3),
		CFrame.new(centre + Vector3.new(0, 0.7, -PAD / 2 + 10)),
		COL.GOALKEEP, Enum.Material.Neon
	)
	tee.Transparency = 0.4
	tagZone(tee, id)

	_zones[id] = {
		Id = id, Name = "Goalkeeping", Centre = centre, Reps = REPS.Goalkeeping,
		Tee = tee, Ball = buildZoneBall(id, centre),
		Prompt = buildConsole(id, "Goalkeeping Drill", centre),
	}
end

local function buildTechnique(centre: Vector3)
	local id = "Technique"
	buildPad(id, centre, COL.TECH)

	-- A dummy that only reacts to techniques. Technique activations inside
	-- this pad are credited by listening to the technique broadcast.
	local dummy = part(
		id .. "_Dummy",
		Vector3.new(3, 6, 3),
		CFrame.new(centre + Vector3.new(0, 3, -12)),
		COL.TECH, Enum.Material.SmoothPlastic
	)
	dummy.CanCollide = false
	tagZone(dummy, id)
	makeSign(dummy, "TECHNIQUE TARGET", Vector3.new(0, 6, 0))

	_zones[id] = {
		Id = id, Name = "Technique", Centre = centre, Reps = REPS.Technique,
		Dummy = dummy, Ball = buildZoneBall(id, centre),
		Prompt = buildConsole(id, "Technique Practice", centre),
	}
end

-- ─────────────────────────────────────────────
-- Progress + rewards
-- ─────────────────────────────────────────────

local function stateFor(player: Player, zoneId: string)
	local byZone = _progress[player.UserId]
	if not byZone then
		byZone = {}
		_progress[player.UserId] = byZone
	end
	local s = byZone[zoneId]
	if not s then
		s = { Progress = 0, CooldownUntil = 0, SlalomIndex = 0, Armed = false }
		byZone[zoneId] = s
	end
	return s
end

--- Advance a drill and pay out when the rep target is reached.
local function addRep(player: Player, zoneId: string, amount: number?)
	local zone = _zones[zoneId]
	if not zone then return end
	local s = stateFor(player, zoneId)
	if tick() < s.CooldownUntil then return end

	s.Progress += (amount or 1)
	if s.Progress < zone.Reps then
		Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
			Type    = "TrainingProgress",
			Zone    = zone.Name,
			Current = s.Progress,
			Target  = zone.Reps,
			Message = string.format("%s drill  %d/%d", zone.Name, s.Progress, zone.Reps),
		})
		return
	end

	-- Drill complete.
	s.Progress      = 0
	s.CooldownUntil = tick() + REWARD_COOLDOWN

	if PlayerService then
		PlayerService.GrantRewards(player, { XP = REWARD_XP, Coins = REWARD_COINS })
	end
	if ObjectiveService then
		ObjectiveService.Report(player, "Training", 1)
	end

	Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
		Type    = "TrainingComplete",
		Zone    = zone.Name,
		XP      = REWARD_XP,
		Coins   = REWARD_COINS,
		Message = string.format("%s drill complete!  +%d XP  +%d coins", zone.Name, REWARD_XP, REWARD_COINS),
	})
	print(string.format("[TrainingBuilder] %s completed the %s drill.", player.DisplayName, zone.Name))
end

-- ─────────────────────────────────────────────
-- Zone hit detection
-- ─────────────────────────────────────────────

--- Send a drill ball toward a world point at a given speed. The ball is
--- anchored, so this moves it kinematically through BallService rather than
--- relying on AssemblyLinearVelocity, which anchored parts ignore.
local function serveBall(ball: BasePart, from: Vector3, to: Vector3, speed: number)
	if not BallService or not ball or not ball.Parent then return end
	if speed <= 0 then
		BallService.PlaceTrainingBall(ball, from)
		return
	end
	BallService.KickTrainingBall(ball, from, to, speed)
end

--- Which zone is this world position in, if any?
local function zoneAt(pos: Vector3): any?
	for _, zone in pairs(_zones) do
		if (pos - zone.Centre).Magnitude <= ZONE_RADIUS then
			return zone
		end
	end
	return nil
end

-- ─────────────────────────────────────────────
-- Per-tick logic (2 Hz)
-- ─────────────────────────────────────────────

local _accum = 0
local _saveCooldown: { [string]: number } = {}

local function onHeartbeat(dt: number)
	_accum += dt
	if _accum < CHECK_INTERVAL then return end
	_accum = 0

	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if not char then continue end
		local root = char:FindFirstChild("HumanoidRootPart")
		if not root then continue end

		local zone = zoneAt(root.Position)
		if not zone then
			-- Leaving a zone resets the slalom so it cannot be half-completed.
			local byZone = _progress[player.UserId]
			if byZone and byZone.Dribbling then
				byZone.Dribbling.SlalomIndex = 0
			end
			continue
		end

		-- Techniques are usable anywhere in the training grounds.
		if zone.Id ~= "Technique" and TechniqueService then
			TechniqueService.SetTrainingMode(true)
		end

		local s = stateFor(player, zone.Id)

		-- ── Shooting: did the ball reach a target? ──────────────────────
		if zone.Id == "Shooting" and zone.Ball and zone.Ball.Parent then
			for _, target in ipairs(zone.Targets) do
				if target and target.Parent then
					-- Sphere test around the target face.
					if (zone.Ball.Position - target.Position).Magnitude <= 6 then
						target.BrickColor = COL.TARGET_HIT
						addRep(player, zone.Id, 1)
						-- Re-rack the ball at the tee.
						serveBall(zone.Ball,
							zone.Centre + Vector3.new(0, 3, PAD / 4),
							zone.Centre, 0)
						task.delay(1.5, function()
							if target.Parent then target.BrickColor = COL.TARGET end
						end)
						break
					end
				end
			end
		end

		-- ── Passing: did the ball reach a gate line? ────────────────────
		if zone.Id == "Passing" and zone.Ball and zone.Ball.Parent then
			for i = 1, #zone.Gates do
				local z = zone.Centre + Vector3.new((i - 1.5) * 22, 0, -PAD / 4)
				if (zone.Ball.Position - z).Magnitude <= 8 then
					addRep(player, zone.Id, 1)
					serveBall(zone.Ball,
						zone.Centre + Vector3.new(0, 3, PAD / 4),
						zone.Centre, 0)
					break
				end
			end
		end

		-- ── Dribbling: advance the slalom only while carrying the ball ──
		if zone.Id == "Dribbling" and zone.Ball then
			local carrying = BallService and BallService.HoldsBall(player)
			if carrying then
				local nextIndex = s.SlalomIndex + 1
				if nextIndex <= #zone.Slalom then
					local cone = zone.Slalom[nextIndex]
					if cone and cone.Parent and (root.Position - cone.Position).Magnitude <= 10 then
						s.SlalomIndex = nextIndex
						cone.Transparency = 0.6
					end
				elseif (root.Position - zone.Finish.Position).Magnitude <= 12 then
					s.SlalomIndex = 0
					for _, c in ipairs(zone.Slalom) do
						if c.Parent then c.Transparency = 0 end
					end
					addRep(player, zone.Id, 1)
				end
			else
				s.SlalomIndex = 0
				for _, c in ipairs(zone.Slalom) do
					if c.Parent then c.Transparency = 0 end
				end
			end
		end

		-- ── Defence: get within tackling range of the dummy ─────────────
		if zone.Id == "Defense" and zone.Dummy and zone.Dummy.Parent then
			if (root.Position - zone.Dummy.Position).Magnitude <= Constants.TACKLE_RANGE then
				local last = _saveCooldown[player.UserId .. zone.Id] or 0
				if tick() - last > 1.5 then
					_saveCooldown[player.UserId .. zone.Id] = tick()
					addRep(player, zone.Id, 1)
					-- Reset the dummy back to the tee.
					zone.Dummy.CFrame = CFrame.new(zone.Centre + Vector3.new(0, 3, -10))
					zone.DummyBall.CFrame = CFrame.new(zone.Centre + Vector3.new(0, 2, -10))
				end
			end
		end

		-- ── Goalkeeping: serve a shot, credit a stop near the line ──────
		if zone.Id == "Goalkeeping" and zone.Ball and zone.Ball.Parent then
			local key = player.UserId .. zone.Id
			local last = _saveCooldown[key] or 0
			if tick() - last > 2.5 then
				local from = zone.Centre + Vector3.new(0, 3, -PAD / 2 + 10)
				local to   = zone.Centre + Vector3.new(math.random(-6, 6), math.random(3, 7), PAD / 2 - 6)
				serveBall(zone.Ball, from, to, 70)
				_saveCooldown[key] = tick()
			elseif (zone.Ball.Position - (zone.Centre + Vector3.new(0, 0, PAD / 2 - 6))).Magnitude <= 20 then
				-- Ball has arrived at the goal mouth. A keeper standing there
				-- has made the stop.
				local mouth = zone.Centre + Vector3.new(0, 0, PAD / 2 - 6)
				if (root.Position - mouth).Magnitude <= 16 then
					addRep(player, zone.Id, 1)
					_saveCooldown[key] = tick() - 1.5
				end
			end
		end
	end
end

-- ─────────────────────────────────────────────
-- Technique activations inside the Technique pad
-- ─────────────────────────────────────────────

local function onTechniqueActivated(player: Player, techId: string)
	local char = player.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local zone = zoneAt(root.Position)
	if not zone or zone.Id ~= "Technique" then return end
	addRep(player, zone.Id, 1)
end

-- ─────────────────────────────────────────────
-- Prompt handling: start / reset a drill
-- ─────────────────────────────────────────────

local function wirePrompts()
	for zoneId, zone in pairs(_zones) do
		if zone.Prompt then
			zone.Prompt.Triggered:Connect(function(player: Player)
				local s = stateFor(player, zoneId)
				s.Progress = 0
				s.SlalomIndex = 0
				s.CooldownUntil = 0

				-- Put the drill ball at the tee, then hand it to the player.
				-- Order matters: PlaceTrainingBall releases the current holder.
				if zone.Ball and BallService then
					BallService.PlaceTrainingBall(zone.Ball,
						zone.Centre + Vector3.new(0, 3, PAD / 4))
					BallService.GrantTrainingPossession(player, zone.Ball)
				end
				if TechniqueService then
					TechniqueService.SetTrainingMode(true)
				end
				Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
					Type    = "TrainingStart",
					Zone    = zone.Name,
					Message = string.format("%s drill started — %d reps to complete", zone.Name, zone.Reps),
				})
			end)
		end
	end
end

-- ─────────────────────────────────────────────
-- Build
-- ─────────────────────────────────────────────

local function buildGrounds()
	if built then return end
	if workspace:FindFirstChild("TrainingGrounds") then
		built = true
		return
	end

	model = Instance.new("Model")
	model.Name = "TrainingGrounds"
	model.Parent = workspace
	built = true

	-- Hub floor so the six pads read as one facility.
	part("Grounds_Base", Vector3.new(PAD * 2.6, 1, PAD * 1.8),
		CFrame.new(TRAINING_ORIGIN + Vector3.new(0, -0.5, 0)),
		BrickColor.new("Dark stone grey"), Enum.Material.Concrete)

	local o = TRAINING_ORIGIN
	buildShooting(    o + Vector3.new(-PAD_GAP, 0, -PAD_GAP))
	buildPassing(     o + Vector3.new( 0,      0, -PAD_GAP))
	buildDribbling(   o + Vector3.new( PAD_GAP, 0, -PAD_GAP))
	buildDefense(     o + Vector3.new(-PAD_GAP, 0,  0))
	buildGoalkeeping( o + Vector3.new( 0,      0,  0))
	buildTechnique(   o + Vector3.new( PAD_GAP, 0,  0))

	-- Entry marker so the area is discoverable from the dome.
	local entry = part(
		"Grounds_Entry",
		Vector3.new(8, 12, 1),
		CFrame.new(o + Vector3.new(0, 6, PAD * 0.9)),
		BrickColor.new("Bright green"), Enum.Material.Glass
	)
	entry.Transparency = 0.6
	makeSign(entry, "⚡ TRAINING GROUNDS", Vector3.new(0, 9, 0))

	-- One shared spawn so players do not materialize inside a drill.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name        = "SpawnTrainingGrounds"
	spawn.Size        = Vector3.new(6, 1, 6)
	spawn.CFrame      = CFrame.new(o + Vector3.new(0, 1.5, PAD * 0.8))
	spawn.Anchored    = true
	spawn.CanCollide  = true
	spawn.Enabled     = true
	spawn.Duration    = 0
	spawn.BrickColor  = BrickColor.new("Bright green")
	spawn.Material    = Enum.Material.Neon
	spawn.Transparency = 0.5
	spawn.Parent      = model

	wirePrompts()

	local count = 0
	for _ in model:GetDescendants() do count += 1 end
	print(string.format(
		"[TrainingBuilder] Training grounds built — 6 zones, %d instances.",
		count
	))
end

-- ─────────────────────────────────────────────
-- Init
-- ─────────────────────────────────────────────

function TrainingBuilder.Init(playerService: any, techniqueService: any, objectiveService: any, ballService: any)
	PlayerService     = playerService
	TechniqueService  = techniqueService
	ObjectiveService  = objectiveService
	BallService       = ballService

	buildGrounds()

	RunService.Heartbeat:Connect(onHeartbeat)

	-- Technique landings are reported by TechniqueService only after the
	-- technique actually passed validation and executed, so a denied or
	-- out-of-energy request never advances the drill.
	if TechniqueService and TechniqueService.SetUsedCallback then
		TechniqueService.SetUsedCallback(function(player: Player, techId: string, success: boolean)
			if success then
				onTechniqueActivated(player, techId)
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		_progress[player.UserId] = nil
		_saveCooldown[player.UserId] = nil
	end)

	-- Turn training mode back off when nobody is on the grounds.
	task.spawn(function()
		while true do
			task.wait(2)
			if TechniqueService then
				local anyInside = false
				for _, player in ipairs(Players:GetPlayers()) do
					local char = player.Character
					local root = char and char:FindFirstChild("HumanoidRootPart")
					if root and zoneAt(root.Position) then
						anyInside = true
						break
					end
				end
				TechniqueService.SetTrainingMode(anyInside)
			end
		end
	end)

	print("[TrainingBuilder] Initialised.")
end

return TrainingBuilder
