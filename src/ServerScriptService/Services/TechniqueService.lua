--[[
	MythicStrikers — TechniqueService
	Server-authoritative technique execution framework.

	RESPONSIBILITIES:
	  • Validate every technique request (energy, cooldown, ownership, match state, possession)
	  • Apply technique effects based on type (shoot, dribble, pass, block, goalkeeper)
	  • Spend energy and start cooldowns
	  • Award XP and mastery XP for successful technique usage
	  • Broadcast technique activation to clients for VFX/camera

	DEPENDENCIES (injected via Init):
	  BallService, PlayerService, AntiExploitService, MatchService

	SECURITY:
	  • All validation happens server-side.
	  • Clients only request; server validates and executes.
	  • Never trust client-provided technique IDs or timestamps.
--]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants              = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes                = require(ReplicatedStorage.Remotes)
local TechniqueDefinitions   = require(ReplicatedStorage.Shared.Techniques.TechniqueDefinitions)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local TechniqueService = {}

-- ─────────────────────────────────────────────
-- Injected service references
-- ─────────────────────────────────────────────
local BallService: any
local PlayerService: any
local AntiExploitService: any
local MatchService: any

-- ─────────────────────────────────────────────
-- Runtime state
-- ─────────────────────────────────────────────

-- Track active dribble boosts: userId -> { endTime, speedBoost }
local _dribbleBoosts: { [number]: { endTime: number, boost: number } } = {}

-- Track active goalkeeper shields: userId -> { endTime }
local _gkShields: { [number]: { endTime: number } } = {}

-- Track active Titan Rampart barriers: { part, endTime }
local _barriers: { { part: BasePart, endTime: number } } = {}

-- Training-zone flag: lets techniques fire while the training stadium is in
-- use, even when no competitive match is Active.
local _isTrainingMode: boolean = false

-- Optional observer notified after a technique is validated and executed.
local _usedCallback: ((player: Player, techId: string, success: boolean) -> ())? = nil

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function getPlayerRoot(player: Player): BasePart?
	local char = player.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHumanoid(player: Player): Humanoid?
	local char = player.Character
	if not char then return nil end
	return char:FindFirstChildWhichIsA("Humanoid")
end

--- Calculate effective technique power from player attributes.
local function calcEffectivePower(player: Player, basePower: number): number
	local attrs = PlayerService.GetAttributes(player)
	if not attrs then return basePower end

	local techPower = attrs.TechniquePower or 50  -- 1-100
	-- Overall mastery bonus: sum of all mastery levels / 100, capped at 20%
	local allMastery = PlayerService.GetAllMastery(player)
	local totalMastery = 0
	for _, m in pairs(allMastery) do
		totalMastery = totalMastery + (m.Level or 0)
	end
	local masteryBonus = 1 + math.min(0.20, totalMastery / 100)

	local powerMult = 0.7 + (techPower / 100) * 0.6  -- 0.7x to 1.3x
	powerMult = powerMult * masteryBonus

	return basePower * powerMult
end

--- Calculate shot speed from direction and power.
local function calcShotSpeed(player: Player, techPower: number): number
	local attrs = PlayerService.GetAttributes(player)
	if not attrs then
		return Constants.SHOT_MAX_POWER
	end
	local powerStat = attrs.Power or 50
	local normalised = math.clamp(powerStat / 100, 0, 1)
	local baseSpeed = Constants.SHOT_MIN_POWER + normalised * (Constants.SHOT_MAX_POWER - Constants.SHOT_MIN_POWER)
	return baseSpeed * techPower
end

-- ─────────────────────────────────────────────
-- Technique execution by type
-- ─────────────────────────────────────────────

--- Execute a shooting technique.
local function executeShoot(player: Player, def: table, direction: Vector3)
	if not direction or direction.Magnitude < 0.01 then return false end

	local hasBall = BallService.GetPossessor() == player
	if not hasBall then return false end

	local techPower = calcEffectivePower(player, def.Power)
	-- calcEffectivePower already folds in def.Power, so it must not be applied twice
	local speed = calcShotSpeed(player, techPower)

	local scaledDir = direction.Unit
	local vel = scaledDir * math.clamp(speed, 0, Constants.BALL_MAX_SPEED)

	-- Small upward angle for goal shooting
	local elevated = Vector3.new(vel.X, math.max(vel.Y, vel.Magnitude * 0.08), vel.Z)

	BallService.ApplyTechniqueShot(player, elevated, math.clamp(speed, 0, Constants.BALL_MAX_SPEED), nil, 0)

	-- Award mastery XP for shot techniques
	PlayerService.AddTechniqueMasteryXP(player, def.Id, 20, false)

	-- Award XP for using a technique
	PlayerService.GrantRewards(player, { XP = 5 })

	return true
end

--- Execute a dribbling technique — speed boost for a short duration.
local function executeDribble(player: Player, def: table, direction: Vector3)
	local root = getPlayerRoot(player)
	local hum = getHumanoid(player)
	if not root or not hum then return false end

	local techPower = calcEffectivePower(player, def.Power)
	local boostDuration = def.Duration
	local speedBoost = 1 + (techPower * 0.3)  -- 1.0x to 1.3x multiplier on top

	-- Apply speed boost
	local sprintSpeed = Constants.SPRINT_SPEED * speedBoost
	hum.WalkSpeed = sprintSpeed

	_dribbleBoosts[player.UserId] = {
		endTime = tick() + boostDuration,
		boost   = speedBoost,
	}

	-- Award mastery XP
	PlayerService.AddTechniqueMasteryXP(player, def.Id, 15, false)
	PlayerService.GrantRewards(player, { XP = 5 })

	return true
end

--- Execute a passing technique — enhanced pass.
local function executePass(player: Player, def: table, direction: Vector3)
	if not direction or direction.Magnitude < 0.01 then return false end

	local hasBall = BallService.GetPossessor() == player
	if not hasBall then return false end

	local techPower = calcEffectivePower(player, def.Power)
	local attrs = PlayerService.GetAttributes(player) or { Passing = 55, Power = 50 }

	local speed = math.clamp(
		(Constants.PASS_MIN_POWER + (Constants.PASS_MAX_POWER - Constants.PASS_MIN_POWER) * 0.5) * def.Power * techPower,
		Constants.PASS_MIN_POWER, Constants.PASS_MAX_POWER * def.Power
	)

	local vel = direction.Unit * speed
	BallService.ApplyTechniqueShot(player, vel, speed, nil, 0)

	-- Award mastery XP
	PlayerService.AddTechniqueMasteryXP(player, def.Id, 15, false)
	PlayerService.GrantRewards(player, { XP = 5 })

	return true
end

--- Execute a defense/block technique — create a temporary barrier.
local function executeBlock(player: Player, def: table, direction: Vector3)
	local root = getPlayerRoot(player)
	if not root then return false end

	local techPower = calcEffectivePower(player, def.Power)

	-- Create a temporary barrier part in front of the player
	local barrier = Instance.new("Part")
	barrier.Name = "TechniqueBarrier_" .. player.UserId
	barrier.Size = Vector3.new(def.Range or 8, 4, 0.5)
	local anchor  = root.Position
	local facing  = anchor + direction.Unit * (def.Range or 8)
	barrier.CFrame = CFrame.lookAt((anchor + facing) / 2, facing)
	barrier.Anchored = true
	barrier.CanCollide = false
	barrier.Transparency = 0.5
	barrier.BrickColor = BrickColor.new("Bright yellow")
	barrier.Material = Enum.Material.Neon
	barrier.Parent = workspace

	-- Auto-cleanup after duration
	task.delay(def.Duration, function()
		if barrier and barrier.Parent then
			barrier:Destroy()
		end
	end)

	-- Remove from barriers list after duration
	table.insert(_barriers, { part = barrier, endTime = tick() + def.Duration })

	-- Award mastery XP
	PlayerService.AddTechniqueMasteryXP(player, def.Id, 15, false)
	PlayerService.GrantRewards(player, { XP = 5 })

	return true
end

--- Execute a goalkeeper technique — enhanced save.
local function executeGoalkeeper(player: Player, def: table, direction: Vector3)
	local hum = getHumanoid(player)
	if not hum then return false end

	local techPower = calcEffectivePower(player, def.Power)
	local duration = def.Duration

	-- Grant goalkeeper enhanced abilities for the duration.
	-- The boost is kept in RUNTIME state only. Writing it into
	-- PlayerService.GetAttributes() would mutate the persisted profile table
	-- and permanently corrupt the player's Goalkeeping stat.
	_gkShields[player.UserId] = { endTime = tick() + duration }

	-- Clean up after duration
	task.delay(duration, function()
		_gkShields[player.UserId] = nil
	end)

	-- Award mastery XP
	PlayerService.AddTechniqueMasteryXP(player, def.Id, 20, false)
	PlayerService.GrantRewards(player, { XP = 5 })

	return true
end

-- ─────────────────────────────────────────────
-- Dribble boost cleanup (Heartbeat)
-- ─────────────────────────────────────────────

local function onHeartbeat(dt: number)
	local now = tick()

	-- Clean up expired dribble boosts
	for userId, boost in pairs(_dribbleBoosts) do
		if now >= boost.endTime then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				local hum = getHumanoid(player)
				if hum then
					local profile = PlayerService.GetProfile(player)
					if profile then
						-- Restore normal speed
						local speedMult = 0.7 + (profile.Attributes.Speed / 100) * 0.6
						local sprintSpeed = Constants.SPRINT_SPEED * speedMult
						hum.WalkSpeed = sprintSpeed
					else
						hum.WalkSpeed = Constants.SPRINT_SPEED
					end
				end
			end
			_dribbleBoosts[userId] = nil
		end
	end

	-- Clean up expired GK shields (just remove from tracking)
	for userId, shield in pairs(_gkShields) do
		if now >= shield.endTime then
			_gkShields[userId] = nil
		end
	end

	-- Clean up expired barriers
	local i = 1
	while i <= #_barriers do
		local barrier = _barriers[i]
		if now >= barrier.endTime then
			if barrier.part and barrier.part.Parent then
				barrier.part:Destroy()
			end
			table.remove(_barriers, i)
		else
			i = i + 1
		end
	end
end

-- ─────────────────────────────────────────────
-- Remote handler
-- ─────────────────────────────────────────────

local function onRequestTechnique(player: Player, payload: table)
	-- Validate payload
	if typeof(payload) ~= "table" then return end

	local techId = payload.TechId
	if typeof(techId) ~= "string" or #techId == 0 then return end

	-- Get technique definition
	local def = TechniqueDefinitions.Get(techId)
	if not def then
		warn(string.format("[TechniqueService] Unknown technique ID: %s", techId))
		return
	end

	-- Check if player has this technique unlocked
	if not PlayerService.HasTechnique(player, techId) then
		Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
			Type = "TechLocked",
			Message = "You haven't unlocked this technique yet.",
		})
		return
	end

	-- Check match state. Techniques are allowed in town (Waiting), in an active
	-- match, and anywhere while training mode is on. They are refused during
	-- Countdown / HalfTime / Ended so nobody can pre-cast into a kickoff.
	if MatchService and not _isTrainingMode then
		local state = MatchService.GetState()
		if state ~= "Active" and state ~= "Waiting" then
			Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
				Type    = "TechUnavailable",
				Message = "Techniques can't be used right now.",
			})
			return
		end
	end

	-- Anti-exploit validation
	if AntiExploitService then
		local validation = AntiExploitService.ValidateTechnique(player, techId, def.EnergyCost)
		if not validation.ok then
			return
		end
	end

	-- Check energy
	if not PlayerService.SpendEnergy(player, def.EnergyCost) then
		Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
			Type = "NoEnergy",
			Message = "Not enough Mythic Energy.",
		})
		return
	end

	-- Start cooldown
	PlayerService.StartCooldown(player, def.Id, def.Cooldown)

	-- Get direction
	local direction = payload.Direction or Vector3.new(0, 0, 1)
	if typeof(direction) ~= "Vector3" then return end

	-- Execute based on type
	local success = false
	local teamId = nil
	if MatchService then
		teamId = nil  -- TeamService injected separately
	end

	if def.Type == "Shoot" then
		success = executeShoot(player, def, direction)
	elseif def.Type == "Dribble" then
		success = executeDribble(player, def, direction)
	elseif def.Type == "Pass" then
		success = executePass(player, def, direction)
	elseif def.Type == "Block" then
		success = executeBlock(player, def, direction)
	elseif def.Type == "Goalkeeper" then
		success = executeGoalkeeper(player, def, direction)
	end

	-- Broadcast technique activation to all clients (for VFX)
	Remotes.FireAllClients(Constants.Remotes.TechniqueResult, {
		PlayerId    = player.UserId,
		TechId      = def.Id,
		TechName    = def.Name,
		Type        = def.Type,
		Element     = def.Element,
		Direction   = direction,
		Success     = success,
		EnergyLeft  = PlayerService.GetEnergy(player),
		Cooldown    = def.Cooldown,
		VFX         = def.VFX,
		SFX         = def.SFX,
		Cinematic   = def.Cinematic,
		Timestamp   = tick(),
	})

	if success then
		print(string.format("[TechniqueService] %s used %s",
			player.DisplayName, def.Name))
	end

	-- Report the outcome to listeners (e.g. the training-ground drill tracker).
	-- Fires only after validation and execution, so it cannot be spoofed by a
	-- client firing the remote directly.
	if _usedCallback then
		_usedCallback(player, def.Id, success)
	end
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

--- Set training mode (allows techniques outside of matches).
function TechniqueService.SetTrainingMode(active: boolean)
	_isTrainingMode = active
end

--- Register an observer called after every validated technique execution.
--- Used by TrainingBuilder to advance the technique-practice drill.
function TechniqueService.SetUsedCallback(callback: (player: Player, techId: string, success: boolean) -> ())
	_usedCallback = callback
end

--- Check if a player has a goalkeeper shield active.
function TechniqueService.IsGKShieldActive(player: Player): boolean
	local shield = _gkShields[player.UserId]
	if not shield then return false end
	return tick() < shield.endTime
end

--- Flat bonus to the Goalkeeping stat while Astral Shield is up (0 when idle).
function TechniqueService.GetGoalkeeperBoost(player: Player): number
	return TechniqueService.IsGKShieldActive(player) and 30 or 0
end

--- Check if a player is currently under a dribble speed boost.
function TechniqueService.HasDribbleBoost(player: Player): boolean
	local boost = _dribbleBoosts[player.UserId]
	if not boost then return false end
	return tick() < boost.endTime
end

--- Get the dribble speed multiplier for a player (1.0 if no boost).
function TechniqueService.GetDribbleBoostMultiplier(player: Player): number
	local boost = _dribbleBoosts[player.UserId]
	if not boost or tick() >= boost.endTime then return 1.0 end
	return boost.boost
end

--- Initialise TechniqueService.
function TechniqueService.Init(ballSvc, playerSvc, antiExploitSvc, matchSvc)
	BallService         = ballSvc
	PlayerService       = playerSvc
	AntiExploitService  = antiExploitSvc
	MatchService        = matchSvc

	-- Remote listener
	Remotes.OnServerEvent(Constants.Remotes.RequestTechnique, onRequestTechnique)

	-- Heartbeat for cleanup
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Give every new profile the starter techniques. The rest of the roster is
	-- discovered through play — see EvaluateUnlocks. Previously ALL SEVEN were
	-- granted immediately, which removed any reason to explore.
	local function grantStarters(p: Player)
		for _, techId in ipairs(TechniqueDefinitions.GetStarterTechniques()) do
			PlayerService.UnlockTechnique(p, techId)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		task.defer(function()
			grantStarters(player)
			TechniqueService.EvaluateUnlocks(player)
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			-- Wait for the profile to finish loading. Bounded, because the
			-- DataStore load can fail and CharacterAdded may never fire.
			local deadline = tick() + 20
			while not PlayerService.GetProfile(player) and tick() < deadline do
				task.wait(0.5)
			end
			if not PlayerService.GetProfile(player) then return end
			grantStarters(player)
			TechniqueService.EvaluateUnlocks(player)
		end)
	end)

	-- Discovery check. Deliberately low frequency: requirements only become
	-- true on a level-up, a statistic crossing a threshold, or a position
	-- change, and the check is cheap.
	task.spawn(function()
		while true do
			task.wait(5)
			for _, player in ipairs(Players:GetPlayers()) do
				TechniqueService.EvaluateUnlocks(player)
			end
		end
	end)

	print("[TechniqueService] Initialised.")
end

--- Check whether a player can discover a technique yet, and unlock it if so.
--- Called periodically, not on a hot path, because it only becomes true when a
--- requirement is met and is idempotent once unlocked.
function TechniqueService.EvaluateUnlocks(player: Player)
	local profile = PlayerService.GetProfile(player)
	if not profile then return end

	for _, def in ipairs(TechniqueDefinitions.GetDiscoverableTechniques()) do
		if not PlayerService.HasTechnique(player, def.Id) then
			local ok = TechniqueDefinitions.MeetsRequirements(
				def,
				profile.Level,
				profile.Statistics,
				profile.Position
			)
			if ok then
				if PlayerService.UnlockTechnique(player, def.Id) then
					Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
						Type    = "TechniqueUnlocked",
						TechId  = def.Id,
						Message = "TECHNIQUE DISCOVERED — " .. def.Name,
					})
					print(string.format(
						"[TechniqueService] %s discovered %s",
						player.DisplayName, def.Name
					))
				end
			end
		end
	end
end

--- Returns the full technique list for the UI, marking each entry as
--- unlocked / locked / undiscovered so the client can render ??? rows for
--- techniques the player has not found yet.
function TechniqueService.GetTechniqueListFor(player: Player): { table }
	local profile = PlayerService.GetProfile(player)
	local result = {}
	for _, def in ipairs(TechniqueDefinitions.List) do
		table.insert(result, {
			Id           = def.Id,
			Name         = def.Name,
			Type         = def.Type,
			Element      = def.Element,
			Tier         = def.Tier,
			EnergyCost   = def.EnergyCost,
			Cooldown     = def.Cooldown,
			Description  = def.Description,
			Hint         = def.Hint,
			Unlocked     = PlayerService.HasTechnique(player, def.Id),
			Equipped     = false,
			MasteryLevel = PlayerService.GetMasteryLevel(player, def.Id),
		})
	end
	if profile and profile.EquippedTechs then
		for _, entry in ipairs(result) do
			for _, equippedId in ipairs(profile.EquippedTechs) do
				if equippedId == entry.Id then
					entry.Equipped = true
					break
				end
			end
		end
	end
	return result
end

--- Returns the list of equipped technique definitions for a player.
function TechniqueService.GetEquippedTechniques(player: Player): { table }
	local profile = PlayerService.GetProfile(player)
	if not profile then return {} end

	local result = {}
	for _, techId in ipairs(profile.EquippedTechs or {}) do
		local def = TechniqueDefinitions.Get(techId)
		if def then
			table.insert(result, def)
		end
	end
	return result
end

return TechniqueService
