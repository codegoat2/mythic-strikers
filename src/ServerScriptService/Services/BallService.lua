--[[
	MythicStrikers — BallService
	Server-authoritative ball physics, possession, passing, shooting,
	interception, and goal detection.

	ARCHITECTURE:
	  - The ball Part lives in Workspace and is Network-owned by the server
	    (nil owner) at all times. Clients NEVER own the ball.
	  - Clients send input requests (RequestPass, RequestShoot, etc.).
	  - BallService validates each request and applies velocity directly
	    via AssemblyLinearVelocity on the server.
	  - Ball state is broadcast to all clients at REPLICATE_RATE hz so
	    clients can do smooth local interpolation without owning physics.
	  - Goals are detected by checking ball position against goal volumes
	    every physics tick via a Touched connection + position guard.

	DEPENDENCIES (resolved at Init time):
	  Remotes, Constants, AntiExploitService (via callback injection)
--]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes   = require(ReplicatedStorage.Remotes)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local BallService = {}
BallService.__index = BallService

-- Injected service references
local TeamService: any = nil
local AntiExploit: any = nil

-- ─────────────────────────────────────────────
-- Private state
-- ─────────────────────────────────────────────
local _ball: BasePart? = nil          -- the physical ball Part in Workspace
local _matchActive     = false        -- only process when a match is running
local _lobbyMode       = false        -- lobby ball practice mode
local _lobbyBall: BasePart? = nil     -- separate ball for town practice
local _goalCallback: ((teamScored: string, scorer: number?, assister: number?) -> ())?  = nil
local _replicateTick   = 0
local REPLICATE_RATE   = 0.05         -- seconds (20 hz)

-- Possession state (match ball)
local _possessor: Player?  = nil      -- Player currently holding the ball
local _lastTouch: Player?  = nil      -- last player to touch the ball
local _lastTouchTeam: string? = nil
local _isLoose             = true
-- Last player to pass the ball; becomes the assister if that pass leads to a goal
local _assistCandidate: Player? = nil
-- Charge timer (per player — a single global let one player's charge power another's shot)
local _chargeStartTime: number? = nil -- for charged shots
local _chargeOwner: Player? = nil

-- Last shot info for save detection
local _lastShotInfo: {
	shooter: Player?,
	direction: Vector3,
	velocity: Vector3,
	time: number
}?
local _possessionConnections: { RBXScriptConnection } = {}

-- Lobby ball state (simpler — no teams, no goals)
local _lobbyPossessor: Player? = nil
local _lobbyIsLoose = true

-- Training ground balls. Each drill owns its own Part; only one player may hold
-- a training ball at a time and the server carries it, exactly like the match
-- ball. Clients never own any of these.
local _trainingPossessor: Player? = nil
local _trainingBall: BasePart? = nil

-- Kinematic flight state for a kicked drill ball. Anchored parts ignore
-- AssemblyLinearVelocity, so a kicked ball is moved by interpolating its
-- CFrame toward _trainingFlightTarget each heartbeat.
local _trainingFlight: {
	ball: BasePart,
	target: Vector3,
	speed: number,
}? = nil

-- Anti-spam: track last action time per player (userId → tick)
local _lastPassTime:   { [number]: number } = {}
local _lastShootTime:  { [number]: number } = {}
local _lastTackleTime: { [number]: number } = {}

-- Action callback (injected by MatchService) — called on successful actions
-- (action: string, player: Player, targetPlayer?: Player)
local _actionCallback: ((action: string, player: Player, targetPlayer: Player?) -> ())? = nil

-- Save callback (injected by MatchService) — called when goalkeeper makes a save
-- (keeper: Player, shooter: Player)
local _saveCallback: ((keeper: Player, shooter: Player) -> ())? = nil

-- ─────────────────────────────────────────────
-- Internal helpers
-- ─────────────────────────────────────────────

local function getBallPosition(): Vector3
	if _ball then return _ball.Position end
	return Vector3.zero
end

local function setBallVelocity(velocity: Vector3)
	if not _ball then return end
	local v = velocity
	-- Hard speed cap
	if v.Magnitude > Constants.BALL_MAX_SPEED then
		v = v.Unit * Constants.BALL_MAX_SPEED
	end
	_ball.AssemblyLinearVelocity = v
end

local function setBallAngularVelocity(av: Vector3)
	if not _ball then return end
	_ball.AssemblyAngularVelocity = av
end

--- Release possession cleanly.
local function releasePossession(keepLastTouch: boolean)
	if _possessor then
		-- Re-enable ball physics
		if _ball then
			_ball.AssemblyLinearVelocity  = Vector3.zero
			_ball.AssemblyAngularVelocity = Vector3.zero
		end
	end
	_possessor = nil
	_isLoose   = true
	if not keepLastTouch then
		-- don't clear _lastTouch — needed for assist detection
	end
end

--- Attach ball to a player (weld-less: update position each tick).
local function grantPossession(player: Player)
	-- Drop previous possessor first
	if _possessor and _possessor ~= player then
		releasePossession(true)
	end
	_possessor     = player
	_lastTouch     = player
	_isLoose       = false

	-- Freeze ball physics while possessed
	if _ball then
		_ball.AssemblyLinearVelocity  = Vector3.zero
		_ball.AssemblyAngularVelocity = Vector3.zero
	end

	-- Notify all clients who has possession
	Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
		Possessor  = player.UserId,
		IsLoose    = false,
		Position   = getBallPosition(),
		Velocity   = Vector3.zero,
	})
end

--- Returns the player's HumanoidRootPart position, or nil.
local function getRootPosition(player: Player): Vector3?
	local char = player.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return nil end
	return root.Position
end

--- Returns distance between a player and the ball.
local function distanceToBall(player: Player): number
	local rootPos = getRootPosition(player)
	if not rootPos then return math.huge end
	return (rootPos - getBallPosition()).Magnitude
end

--- Compute shot velocity from direction, power stat, and optional charge ratio.
local function computeShotVelocity(
	direction: Vector3,
	powerStat: number,
	chargeRatio: number,   -- 0–1
	curveAxis: Vector3?,
	curveStat: number
): Vector3
	-- Base speed from stat (50–100 range maps to SHOT_MIN/MAX)
	local normalised = math.clamp(powerStat / 100, 0, 1)
	local baseSpeed  = Constants.SHOT_MIN_POWER
		+ normalised * (Constants.SHOT_MAX_POWER - Constants.SHOT_MIN_POWER)
	local finalSpeed = baseSpeed * (0.6 + 0.4 * chargeRatio)   -- charge amplifies

	local vel = direction.Unit * finalSpeed

	-- Apply curve if curveAxis provided
	if curveAxis and curveStat > 0 then
		local curveStrength = (curveStat / 100) * 0.35
		-- Angular velocity on the ball creates Magnus-effect curve
		-- We approximate it by offsetting the velocity slightly
		vel = vel + curveAxis * (finalSpeed * curveStrength * 0.3)
	end

	return vel
end

--- Compute pass velocity from direction and power stat.
local function computePassVelocity(
	direction: Vector3,
	powerStat: number,
	isLob: boolean
): Vector3
	local normalised = math.clamp(powerStat / 100, 0, 1)
	local speed = Constants.PASS_MIN_POWER
		+ normalised * (Constants.PASS_MAX_POWER - Constants.PASS_MIN_POWER)

	if isLob then
		-- Loft the ball at ~45 degrees
		local flat  = Vector3.new(direction.X, 0, direction.Z).Unit
		local lobDir = (flat + Vector3.new(0, 0.9, 0)).Unit
		return lobDir * speed
	end

	return direction.Unit * speed
end

-- ─────────────────────────────────────────────
-- Goal detection
-- ─────────────────────────────────────────────

--- Goal volumes expected in Workspace.Stadium:
---   GoalA_Trigger  (Team B scores into Team A's goal → Team B scores)
---   GoalB_Trigger  (Team A scores into Team B's goal → Team A scores)
local function setupGoalDetection()
	local stadium = workspace:FindFirstChild("Stadium")
	if not stadium then
		warn("[BallService] Workspace.Stadium not found — goal detection deferred.")
		return
	end

	-- A goal must be credited exactly once. Touched fires repeatedly while the
	-- ball settles inside the trigger, so without this guard a single goal
	-- awards XP/coins many times over and the scoreboard runs away.
	local GOAL_DEBOUNCE = 2.0
	local _lastGoalTime = 0

	local function bindGoal(triggerName: string, scoringTeam: string)
		local trigger = stadium:FindFirstChild(triggerName, true)
		if not trigger then
			warn(string.format("[BallService] Goal trigger '%s' not found.", triggerName))
			return
		end

		trigger.Touched:Connect(function(hit)
			if not _matchActive then return end
			if not _ball then return end
			if hit ~= _ball then return end

			local now = tick()
			if now - _lastGoalTime < GOAL_DEBOUNCE then return end
			_lastGoalTime = now

			local scorer   = _lastTouch and _lastTouch.UserId or nil

			-- Assist: the last player to pass the ball, provided they are on the
			-- same team as the scorer and did not touch it themselves.
			local assister: number? = nil
			local passer   = _assistCandidate
			if passer and scorer and passer.UserId ~= scorer then
				local sameTeam = true
				if TeamService then
					local t1 = TeamService.GetTeam(passer)
					local t2 = TeamService.GetTeam(Players:GetPlayerByUserId(scorer) or passer)
					sameTeam = (t1 ~= nil and t1 == t2)
				end
				if sameTeam then
					assister = passer.UserId
				end
			end
			_assistCandidate = nil

			-- A goal is by definition a shot on target. Credit the shooter so
			-- the "successful shots" stat (and its end-of-match XP) is not dead.
			if scorer and _actionCallback then
				local shooterPlayer = Players:GetPlayerByUserId(scorer)
				if shooterPlayer then
					_actionCallback("shotOnTarget", shooterPlayer)
				end
			end

			if _goalCallback then
				_goalCallback(scoringTeam, scorer, assister)
			end
		end)
	end

	bindGoal("GoalA_Trigger", "TeamB")   -- ball enters TeamA goal → TeamB scores
	bindGoal("GoalB_Trigger", "TeamA")   -- ball enters TeamB goal → TeamA scores
end

-- ─────────────────────────────────────────────
-- Heartbeat: possession tracking + replication
-- ─────────────────────────────────────────────

local function onHeartbeat(dt: number)
	-- ── Match ball heartbeat ──────────────────────────
	if _ball and (_matchActive or _lobbyMode) then
		-- ── Possession: move ball in front of possessor ──────────────────────────
		if _possessor then
			local char = _possessor.Character
			if not char then
				releasePossession(true)
			else
				local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
				local hum  = char:FindFirstChild("Humanoid") :: Humanoid?
				if not root or not hum or hum.Health <= 0 then
					releasePossession(true)
				else
					-- Place ball slightly ahead and below root
					local lookVec   = root.CFrame.LookVector
					local ballOffset = lookVec * 2.8 + Vector3.new(0, -1.5, 0)
					_ball.CFrame    = CFrame.new(root.Position + ballOffset)
					_ball.AssemblyLinearVelocity  = Vector3.zero
					_ball.AssemblyAngularVelocity = Vector3.zero
				end
			end
		end

		-- ── Auto-possession: detect nearby players for loose ball ──────────────
		if _isLoose and _ball.AssemblyLinearVelocity.Magnitude < 60 then
			for _, player in ipairs(Players:GetPlayers()) do
				if distanceToBall(player) <= Constants.POSSESSION_RANGE then
					grantPossession(player)
					break
				end
			end
		end

		-- ── Save detection: goalkeeper near ball on a shot ─────────────────────
		if _isLoose and _lastShotInfo and (tick() - _lastShotInfo.time) < 3 then
			local ballPos  = getBallPosition()
			local ballVel  = _ball.AssemblyLinearVelocity
			if ballVel.Magnitude > 40 then
				-- Find a goalkeeper near the ball on the defending team
				local shooterTeam = (TeamService and TeamService.GetTeam(_lastShotInfo.shooter)) or nil
				for _, keeper in ipairs(Players:GetPlayers()) do
					if keeper ~= _lastShotInfo.shooter then
						local keeperTeam = (TeamService and TeamService.GetTeam(keeper)) or nil
						if keeperTeam and shooterTeam and keeperTeam ~= shooterTeam then
							if distanceToBall(keeper) <= Constants.GK_DIVE_RANGE then
								-- Check if ball is heading toward keeper's goal (behind them relative to shooter)
								if _saveCallback then
									_saveCallback(keeper, _lastShotInfo.shooter)
								end
								_lastShotInfo = nil
								break
							end
						end
					end
				end
			end
		end
	end

	-- ── Lobby ball heartbeat ──────────────────────────
	if _lobbyMode and _lobbyBall then
		if _lobbyPossessor then
			local char = _lobbyPossessor.Character
			if not char then
				-- Release lobby possession
				if _lobbyBall then
					_lobbyBall.AssemblyLinearVelocity  = Vector3.zero
					_lobbyBall.AssemblyAngularVelocity = Vector3.zero
				end
				_lobbyPossessor = nil
				_lobbyIsLoose = true
			else
				local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
				local hum  = char:FindFirstChild("Humanoid") :: Humanoid?
				if not root or not hum or hum.Health <= 0 then
					_lobbyPossessor = nil
					_lobbyIsLoose = true
					if _lobbyBall then
						_lobbyBall.AssemblyLinearVelocity  = Vector3.zero
						_lobbyBall.AssemblyAngularVelocity = Vector3.zero
					end
				else
					-- Carry the lobby ball
					local lookVec = root.CFrame.LookVector
					local ballOffset = lookVec * 2.5 + Vector3.new(0, -1.2, 0)
					_lobbyBall.CFrame = CFrame.new(root.Position + ballOffset)
					_lobbyBall.AssemblyLinearVelocity  = Vector3.zero
					_lobbyBall.AssemblyAngularVelocity = Vector3.zero
				end
			end
		end

		-- ── Auto-possession for lobby ball ─────────────────────────────────────────
		if _lobbyIsLoose and _lobbyBall.AssemblyLinearVelocity.Magnitude < 40 then
			for _, player in ipairs(Players:GetPlayers()) do
				local rootPos = getRootPosition(player)
				if rootPos and (_lobbyBall.Position - rootPos).Magnitude <= Constants.POSSESSION_RANGE then
					_lobbyPossessor = player
					_lobbyIsLoose = false
					_lobbyBall.AssemblyLinearVelocity = Vector3.zero
					_lobbyBall.AssemblyAngularVelocity = Vector3.zero
					Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
						Position  = _lobbyBall.Position,
						Velocity  = Vector3.zero,
						Possessor = player.UserId,
						IsLoose   = false,
						IsLobby   = true,
					})
					break
				end
			end
		end
	end

	-- ── Training ground ball heartbeat ────────────────────────────
	if _trainingFlight and _trainingFlight.ball.Parent then
		local flight = _trainingFlight
		local goal   = flight.target
		local step   = flight.speed * dt
		local here   = flight.ball.Position
		local delta  = goal - here
		if delta.Magnitude <= step then
			flight.ball.CFrame = CFrame.new(goal)
			_trainingFlight     = nil
		else
			flight.ball.CFrame = CFrame.new(here + delta.Unit * step)
		end
	elseif _trainingBall and _trainingPossessor then
		local char = _trainingPossessor.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
		if not root or not hum or hum.Health <= 0 then
			-- Drop it rather than leaving it welded to nothing.
			_trainingPossessor = nil
		else
			local offset = root.CFrame.LookVector * 2.4 + Vector3.new(0, -1.2, 0)
			_trainingBall.CFrame = CFrame.new(root.Position + offset)
		end
	end

	-- ── Replication: broadcast ball state at fixed rate ─────────────────────
	-- Only one ball is broadcast per tick. In town we send the practice ball;
	-- in a match we send the stadium ball. Sending both made the client's single
	-- cached ball oscillate between two positions 20x/second.
	_replicateTick += dt
	if _replicateTick >= REPLICATE_RATE then
		_replicateTick = 0
		if _lobbyMode and _lobbyBall then
			Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
				Position  = _lobbyBall.Position,
				Velocity  = _lobbyBall.AssemblyLinearVelocity,
				Possessor = _lobbyPossessor and _lobbyPossessor.UserId or nil,
				IsLoose   = _lobbyIsLoose,
				IsLobby   = true,
			})
		else
			Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
				Position  = getBallPosition(),
				Velocity  = _ball and _ball.AssemblyLinearVelocity or Vector3.zero,
				Possessor = _possessor and _possessor.UserId or nil,
				IsLoose   = _isLoose,
			})
		end
	end
end

-- ─────────────────────────────────────────────
-- Remote handlers
-- ─────────────────────────────────────────────

local function onRequestPass(player: Player, payload)
	if not _matchActive and not _lobbyMode then return end
	if _lobbyMode then
		-- In lobby mode, use lobby ball
		if _lobbyPossessor ~= player then return end
	else
		if _possessor ~= player then return end
	end
	if typeof(payload) ~= "table" then return end

	-- Server-side validation (rate limit, possession, direction sanity)
	if AntiExploit then
		local check = AntiExploit.ValidatePass(player, payload)
		if not check.ok then return end
	end

	-- Rate limit
	local now = tick()
	if (now - (_lastPassTime[player.UserId] or 0)) < 0.3 then return end
	_lastPassTime[player.UserId] = now

	-- Validate target direction
	local rawDir = payload.Direction
	if typeof(rawDir) ~= "Vector3" then return end
	if rawDir.Magnitude < 0.01 then return end
	if rawDir.Magnitude > 1.5 then rawDir = rawDir.Unit end

	-- Validate target player if provided (direct pass).
	-- The target must exist, must not be the passer, and — in a match — must be
	-- on the SAME TEAM. Without this a client can plant a phantom assist on any
	-- player in the server (including the opposition).
	local targetPlayer: Player? = nil
	if payload.TargetId then
		if typeof(payload.TargetId) ~= "number" then return end
		targetPlayer = Players:GetPlayerByUserId(payload.TargetId)
		if not targetPlayer then return end
		-- Don't allow passing back to self
		if targetPlayer == player then return end
		-- Don't allow targeting players who are not in the match
		if _matchActive and not _lobbyMode and TeamService then
			local fromTeam = TeamService.GetTeam(player)
			local toTeam   = TeamService.GetTeam(targetPlayer)
			if fromTeam == nil or toTeam == nil or fromTeam ~= toTeam then
				return
			end
		end
		-- Don't allow absurdly distant "direct" passes
		if targetPlayer.Character and player.Character then
			local fromRoot = player.Character:FindFirstChild("HumanoidRootPart")
			local toRoot   = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
			if fromRoot and toRoot and (fromRoot.Position - toRoot.Position).Magnitude > Constants.PASS_MAX_RANGE then
				return
			end
		end
	end

	-- Determine pass velocity
	local isLob = payload.IsLob == true

	-- Get passer's passing stat
	local passStat   = 55   -- default; PlayerService provides real value
	local powerStat  = 50
	-- Inject stats from PlayerService if available (set via BallService.SetStatProvider)
	if BallService._statProvider then
		local stats = BallService._statProvider(player)
		if stats then
			passStat  = stats.Passing or passStat
			powerStat = stats.Power   or powerStat
		end
	end

	local vel = computePassVelocity(rawDir, powerStat, isLob)

	-- Release possession and fire ball
	if _lobbyMode then
		_lobbyPossessor = nil
		_lobbyIsLoose = true
		if _lobbyBall then
			_lobbyBall.AssemblyLinearVelocity = vel
		end
		Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
			Position  = _lobbyBall.Position,
			Velocity  = vel,
			Possessor = nil,
			IsLoose   = true,
			IsLobby   = true,
		})
	else
		releasePossession(true)
		setBallVelocity(vel)
		Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
			Position  = getBallPosition(),
			Velocity  = vel,
			Possessor = nil,
			IsLoose   = true,
		})
	end

	-- Award energy to passer
	if BallService._energyCallback then
		BallService._energyCallback(player, Constants.ENERGY_GAIN_PASS)
	end

	-- Remember the passer so a goal that follows from this pass can be credited
	-- with an assist. Cleared by a shot, a tackle, a goal, or PlaceBall.
	_assistCandidate = player

	-- Notify match service of pass
	if _actionCallback then
		_actionCallback("pass", player, targetPlayer)
	end
end

local function onRequestShoot(player: Player, payload)
	if not _matchActive and not _lobbyMode then return end
	if _lobbyMode then
		if _lobbyPossessor ~= player then return end
	else
		if _possessor ~= player then return end
	end
	if typeof(payload) ~= "table" then return end

	-- Server-side validation (rate limit, direction sanity, possession)
	if AntiExploit then
		local check = AntiExploit.ValidateShoot(player, payload)
		if not check.ok then return end
	end

	-- Rate limit
	local now = tick()
	if (now - (_lastShootTime[player.UserId] or 0)) < 0.5 then return end
	_lastShootTime[player.UserId] = now

	-- Validate direction
	local rawDir = payload.Direction
	if typeof(rawDir) ~= "Vector3" then return end
	if rawDir.Magnitude < 0.01 then return end
	-- Cap the direction vector so a client cannot smuggle magnitude into it
	if rawDir.Magnitude > 1.5 then rawDir = rawDir.Unit end

	-- Validate player is within reasonable shooting distance
	-- (ball is attached to them, so distance should be near-zero — sanity check)
	if distanceToBall(player) > Constants.MAX_SHOOT_DISTANCE then return end

	-- Charge ratio (0 for instant, 1 for fully charged).
	-- Only the player who started the charge can use it.
	local chargeRatio = 0
	if payload.IsCharged and _chargeStartTime and _chargeOwner == player then
		chargeRatio = math.clamp(
			(now - _chargeStartTime) / Constants.CHARGED_SHOT_TIME,
			0, 1
		)
	end
	_chargeStartTime = nil
	_chargeOwner     = nil

	-- Curve
	local curveAxis: Vector3? = nil
	if payload.CurveAxis and typeof(payload.CurveAxis) == "Vector3" then
		curveAxis = payload.CurveAxis
	end

	-- Get shooter's stats
	local shootStat  = 55
	local powerStat  = 50
	local curveStat  = 45
	if BallService._statProvider then
		local stats = BallService._statProvider(player)
		if stats then
			shootStat = stats.Shooting or shootStat
			powerStat = stats.Power    or powerStat
			curveStat = stats.Curve    or curveStat
		end
	end

	-- The Shooting stat scales shot speed, so investing in it actually matters.
	local accuracy = 0.85 + (shootStat / 100) * 0.30
	local vel = computeShotVelocity(rawDir, powerStat, chargeRatio, curveAxis, curveStat) * accuracy

	-- Slightly elevate shot toward goal height
	if payload.IsVolley ~= true then
		local elevated = Vector3.new(vel.X, math.max(vel.Y, vel.Magnitude * 0.08), vel.Z)
		vel = elevated
	end

	if _lobbyMode then
		-- Town practice: release the PRACTICE ball, never the stadium ball.
		_lobbyPossessor = nil
		_lobbyIsLoose   = true
		if _lobbyBall then
			_lobbyBall.AssemblyLinearVelocity  = vel
			_lobbyBall.AssemblyAngularVelocity = Vector3.zero
		end
		_assistCandidate = nil
		Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
			Position  = _lobbyBall and _lobbyBall.Position or Vector3.zero,
			Velocity  = vel,
			Possessor = nil,
			IsLoose   = true,
			IsLobby   = true,
		})
	else
		releasePossession(true)
		setBallVelocity(vel)
		-- Spin for curve effect
		if curveAxis then
			setBallAngularVelocity(curveAxis * (curveStat / 100) * 15)
		end
		-- A shot is not a pass: it cancels any pending assist
		_assistCandidate = nil

		-- Broadcast
		Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
			Position   = getBallPosition(),
			Velocity   = vel,
			Possessor  = nil,
			IsLoose    = true,
			IsShot     = true,
			ShooterId  = player.UserId,
		})
	end

	-- Track shot for save detection (match ball only)
	if not _lobbyMode then
		_lastShotInfo = {
			shooter   = player,
			direction = rawDir.Unit,
			velocity  = vel,
			time      = tick(),
		}
	end

	-- Award energy
	if BallService._energyCallback then
		BallService._energyCallback(player, Constants.ENERGY_GAIN_SHOT)
	end

	-- Notify match service of shot
	if _actionCallback and not _lobbyMode then
		_actionCallback("shot", player)
	end
end

local function onRequestTackle(player: Player, payload)
	if not _matchActive and not _lobbyMode then return end
	if typeof(payload) ~= "table" then return end

	-- Rate limit (tackle cooldown)
	local now = tick()
	if (now - (_lastTackleTime[player.UserId] or 0)) < Constants.TACKLE_COOLDOWN then return end

	-- Must be near the possessor
	local currentPossessor = _lobbyMode and _lobbyPossessor or _possessor
	if not currentPossessor or currentPossessor == player then return end

	local dist = distanceToBall(player)
	if dist > Constants.TACKLE_RANGE then return end

	-- You may not tackle your own teammate. This check was previously an empty
	-- block, so team-mates could strip each other and farm tackle XP.
	if not _lobbyMode and TeamService then
		local tacklerTeam = TeamService.GetTeam(player)
		local victimTeam  = TeamService.GetTeam(currentPossessor)
		if tacklerTeam and victimTeam and tacklerTeam == victimTeam then
			return
		end
	end

	-- Tackle resolution: compare tackling vs dribbling stats
	local tackleStat  = 50
	local dribbleStat = 55
	if BallService._statProvider then
		local tacklerStats   = BallService._statProvider(player)
		local possessorStats = BallService._statProvider(currentPossessor)
		if tacklerStats   then tackleStat  = tacklerStats.Tackling   or tackleStat  end
		if possessorStats then dribbleStat = possessorStats.Dribbling or dribbleStat end
	end

	-- Simple resolution: tackle succeeds if tackling >= dribbling + random(-10,10)
	local tackleRoll  = tackleStat  + math.random(-10, 10)
	local dribbleRoll = dribbleStat + math.random(-5,  15)  -- slight bias toward possessor

	_lastTackleTime[player.UserId] = now

	-- A completed challenge breaks any assist that was in progress
	_assistCandidate = nil

	if tackleRoll >= dribbleRoll then
		-- Tackle succeeds
		local prevPossessor = currentPossessor

		if _lobbyMode then
			_lobbyPossessor = nil
			_lobbyIsLoose = true
			-- Knock ball away in tackle direction
			local rawDir = payload.Direction
			if typeof(rawDir) == "Vector3" and rawDir.Magnitude > 0.01 then
				if _lobbyBall then _lobbyBall.AssemblyLinearVelocity = rawDir.Unit * 35 end
			end
		else
			releasePossession(true)
			-- Knock ball away slightly in tackle direction
			local rawDir = payload.Direction
			if typeof(rawDir) == "Vector3" and rawDir.Magnitude > 0.01 then
				setBallVelocity(rawDir.Unit * 35)
			else
				-- Kick ball forward relative to tackler
				local rootPos = getRootPosition(player)
				if rootPos then
					local awayDir = (getBallPosition() - rootPos)
					if awayDir.Magnitude > 0.01 then
						setBallVelocity(awayDir.Unit * 35)
					end
				end
			end
		end

		-- Award energy to tackler
		if BallService._energyCallback then
			BallService._energyCallback(player, Constants.ENERGY_GAIN_TACKLE)
		end

		-- Notify match service of tackle
		if _actionCallback then
			_actionCallback("tackle", player, prevPossessor)
		end

		-- Notify clients
		Remotes.FireAllClients(Constants.Remotes.NotifyPlayer, {
			Type      = "Tackle",
			TacklerId = player.UserId,
			VictimId  = prevPossessor and prevPossessor.UserId or nil,
		})
	end
	-- On failure: possessor keeps ball, tackler has cooldown
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

--- Initialise BallService.
--- @param ball BasePart  The physical ball Part in Workspace.
--- @param goalCb function  Called when a goal is scored: (teamScored, scorerUserId?, assisterUserId?)
function BallService.Init(ball: BasePart, goalCb)
	assert(ball and ball:IsA("BasePart"), "[BallService] Valid ball Part required.")
	_ball         = ball
	_goalCallback = goalCb

	-- Server owns ball network — no client physics authority
	ball:SetNetworkOwner(nil)

	-- Keep physics live: an anchored ball would never move
	ball.Anchored = false
	if ball:IsA("BasePart") then
		ball.CustomPhysicalProperties = PhysicalProperties.new(
			Constants.BALL_MASS,      -- density (maps to relative mass)
			Constants.BALL_FRICTION,  -- friction
			Constants.BALL_BOUNCE,    -- elasticity
			0.1,                      -- frictionWeight
			0.1                       -- elasticityWeight
		)
	end

	-- Goal detection
	setupGoalDetection()

	-- Heartbeat
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Remote listeners
	Remotes.OnServerEvent(Constants.Remotes.RequestPass,   onRequestPass)
	Remotes.OnServerEvent(Constants.Remotes.RequestShoot,  onRequestShoot)
	Remotes.OnServerEvent(Constants.Remotes.RequestTackle, onRequestTackle)

	print("[BallService] Initialised.")
end

--- Set active match state. Only processes events when true.
function BallService.SetMatchActive(active: boolean)
	_matchActive = active
	if not active then
		releasePossession(false)
		if _ball then
			setBallVelocity(Vector3.zero)
		end
	end
end

--- Set lobby ball practice mode (town exploration with ball).
function BallService.SetLobbyMode(active: boolean)
	_lobbyMode = active
	if not active then
		-- Stop heartbeat processing of lobby ball
		_lobbyPossessor = nil
		_lobbyIsLoose = true
		if _lobbyBall then
			_lobbyBall.AssemblyLinearVelocity = Vector3.zero
			_lobbyBall.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

--- Set the lobby practice ball.
function BallService.SetLobbyBall(ball: BasePart)
	_lobbyBall = ball
	if ball then
		ball:SetNetworkOwner(nil)
		ball.CustomPhysicalProperties = PhysicalProperties.new(
			Constants.BALL_MASS,
			Constants.BALL_FRICTION,
			Constants.BALL_BOUNCE,
			0.1, 0.1
		)
	end
end

--- Grant the lobby ball to a player.
function BallService.GrantLobbyPossession(player: Player)
	_lobbyPossessor = player
	_lobbyIsLoose = false
	if _lobbyBall then
		_lobbyBall.AssemblyLinearVelocity = Vector3.zero
		_lobbyBall.AssemblyAngularVelocity = Vector3.zero
	end
	Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
		Position  = _lobbyBall and _lobbyBall.Position or Vector3.zero,
		Velocity  = Vector3.zero,
		Possessor = player.UserId,
		IsLoose   = false,
		IsLobby   = true,
	})
end

--- Inject TeamService (used by tackle for team checks).
function BallService.SetTeamService(teamSvc: any)
	TeamService = teamSvc
end

--- Inject AntiExploitService so every ball remote runs through server
--- validation (rate limits, proximity, possession, direction sanity).
function BallService.SetAntiExploitService(antiExploit: any)
	AntiExploit = antiExploit
end

--- Returns whichever ball the player currently holds — match ball or town
--- practice ball. Technique and validation code must use this, otherwise
--- every check silently fails in town where only _lobbyPossessor is set.
function BallService.GetAnyPossessor(): Player?
	return _possessor or _lobbyPossessor
end

--- Returns true when the player holds either ball.
function BallService.HoldsBall(player: Player): boolean
	return _possessor == player or _lobbyPossessor == player
		or _trainingPossessor == player
end

--- Hand a training-ground ball to a player. Only one training ball can be held
--- at a time; requesting a new one releases whatever was held before.
--- The drill balls are anchored and moved by the server, so this deliberately
--- does NOT call SetNetworkOwner — that API throws on anchored parts.
--- @param ball BasePart  the drill ball, owned by TrainingBuilder
function BallService.GrantTrainingPossession(player: Player, ball: BasePart)
	if not ball or not ball.Parent then return end
	_trainingPossessor = player
	_trainingBall      = ball
	_trainingFlight    = nil
	ball.CFrame = CFrame.new(ball.Position)
end

--- Park a drill ball at a position with no travel.
function BallService.PlaceTrainingBall(ball: BasePart, position: Vector3)
	if not ball or not ball.Parent then return end
	_trainingFlight = nil
	if _trainingBall == ball then
		_trainingPossessor = nil
	end
	ball.CFrame = CFrame.new(position)
end

--- Send a drill ball from one point toward another at a given speed (studs/s).
--- Kinematic: the ball is interpolated toward the target each heartbeat.
function BallService.KickTrainingBall(ball: BasePart, from: Vector3, to: Vector3, speed: number)
	if not ball or not ball.Parent then return end
	if _trainingBall == ball then
		_trainingPossessor = nil
	end
	ball.CFrame = CFrame.new(from)
	local dist = (to - from).Magnitude
	if dist < 0.01 or speed <= 0 then
		_trainingFlight = nil
		return
	end
	_trainingFlight = { ball = ball, target = to, speed = speed }
end

--- Releases whichever ball the player is holding. Used when a drill ends or a
--- player leaves the training grounds.
function BallService.ReleasePlayerBall(player: Player)
	if _possessor == player then
		releasePossession(true)
	end
	if _lobbyPossessor == player then
		_lobbyPossessor = nil
		_lobbyIsLoose   = true
	end
	if _trainingPossessor == player then
		_trainingPossessor = nil
	end
end

--- Start charge timer for a player (called when client begins holding shoot button).
--- Accepts either the match ball or the town practice ball as the charge source.
function BallService.BeginCharge(player: Player)
	if _possessor ~= player and _lobbyPossessor ~= player then return end
	_chargeOwner    = player
	_chargeStartTime = tick()
end

--- Cancel an in-progress charge.
function BallService.CancelCharge()
	_chargeStartTime = nil
	_chargeOwner     = nil
end

--- Place ball at a world position (used for kickoff, reset).
function BallService.PlaceBall(position: Vector3)
	if not _ball then return end
	_ball.CFrame = CFrame.new(position)
	setBallVelocity(Vector3.zero)
	setBallAngularVelocity(Vector3.zero)
	releasePossession(false)
	_lastTouch     = nil
	_lastTouchTeam = nil
	_assistCandidate = nil
	_lastShotInfo  = nil
	_isLoose       = true
end

--- Grant possession directly (used by MatchService for kickoff).
function BallService.GrantPossessionToPlayer(player: Player)
	grantPossession(player)
end

--- Return current possessor Player or nil.
function BallService.GetPossessor(): Player?
	return _possessor
end

--- Return last player to touch the ball.
function BallService.GetLastTouch(): Player?
	return _lastTouch
end

--- Return current ball position.
function BallService.GetBallPosition(): Vector3
	return getBallPosition()
end

--- Forcefully release possession (e.g. player disconnected, technique interrupt).
function BallService.ForceLosePossession(player: Player)
	if _possessor == player then
		releasePossession(true)
		setBallVelocity(Vector3.new(math.random(-10, 10), 5, math.random(-10, 10)))
	end
end

--- Apply a technique-based shot (called by TechniqueService).
--- Bypasses normal possession check — technique has already been validated.
function BallService.ApplyTechniqueShot(
	player: Player,
	direction: Vector3,
	power: number,       -- absolute studs/s
	curveAxis: Vector3?,
	curveSpin: number    -- angular velocity magnitude
)
	if not _ball then return end

	releasePossession(true)
	local vel = direction.Unit * math.clamp(power, 0, Constants.BALL_MAX_SPEED)
	setBallVelocity(vel)
	if curveAxis then
		setBallAngularVelocity(curveAxis * curveSpin)
	end

	Remotes.FireAllClients(Constants.Remotes.BallStateUpdate, {
		Position   = getBallPosition(),
		Velocity   = vel,
		Possessor  = nil,
		IsLoose    = true,
		IsShot     = true,
		IsTech     = true,
		ShooterId  = player.UserId,
	})
end

--- Register a stat provider callback.
--- PlayerService calls this so BallService can read stats without a hard dependency.
--- @param provider function  (player: Player) → PlayerAttributes | nil
function BallService.SetStatProvider(provider)
	BallService._statProvider = provider
end

--- Register an energy award callback.
--- PlayerService calls this so BallService can grant Mythic Energy.
--- @param callback function  (player: Player, amount: number)
function BallService.SetEnergyCallback(callback)
	BallService._energyCallback = callback
end

--- Register an action callback (for match stat tracking).
--- MatchService calls this so BallService can report successful actions.
--- @param callback function  (action: string, player: Player, targetPlayer?: Player)
function BallService.SetActionCallback(callback)
	_actionCallback = callback
end

--- Register a save detection callback (for goalkeeper saves).
--- Called when a shot is intercepted/deflected near the goalkeeper.
--- @param callback function  (keeper: Player, shooter: Player)
function BallService.SetSaveCallback(callback)
	_saveCallback = callback
end

--- Register the goal callback. Called when a goal is scored.
--- @param callback function  (scoringTeam: string, scorerUserId?: number, assisterUserId?: number)
function BallService.SetGoalCallback(callback)
	_goalCallback = callback
end

--- Returns raw ball state table for debugging / MatchService use.
function BallService.GetState()
	return {
		Position  = getBallPosition(),
		Velocity  = _ball and _ball.AssemblyLinearVelocity or Vector3.zero,
		Possessor = _possessor and _possessor.UserId or nil,
		IsLoose   = _isLoose,
	}
end

return BallService
