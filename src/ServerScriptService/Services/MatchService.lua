--[[
	MythicStrikers — MatchService
	Owns the complete match lifecycle:

	  Waiting → Countdown → Active → HalfTime → Active(2nd) → Ended → Resetting

	Coordinates BallService, TeamService, and PlayerService.
	Fires remotes to keep all clients in sync.
	All score, timer, and goal logic is 100% server-side.

	DEPENDENCIES (injected via Init):
	  BallService, TeamService
	  PlayerService injected separately via SetPlayerService()
	  to avoid circular require chains.
--]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants   = require(ReplicatedStorage.Shared.Config.Constants)
local MatchConfig = require(ReplicatedStorage.Shared.Config.MatchConfig)
local Remotes     = require(ReplicatedStorage.Remotes)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local MatchService = {}

-- ─────────────────────────────────────────────
-- Injected service references
-- ─────────────────────────────────────────────
local BallService
local TeamService
local PlayerService   -- injected later to avoid circular deps
local ObjectiveService -- injected optionally; match objectives are additive
local _playerServiceInjected = false

-- ─────────────────────────────────────────────
-- Match state
-- ─────────────────────────────────────────────
local _state: string       = "Waiting"   -- matches Types.MatchState
local _mode: string        = "5v5"
local _config              = MatchConfig.Get("5v5")

local _scoreA: number      = 0
local _scoreB: number      = 0
local _half: number        = 1           -- 1 or 2
local _timeLeft: number    = 0
local _matchId: string     = ""
local _kickoffTeam: string = "TeamA"

-- Per-match goal tracking for assists
-- { [userId] = { goals, assists } }
local _goalData: { [number]: { goals: number, assists: number } } = {}
local _passChain: { [number]: number } = {}   -- ballOwner → lastPasser userId

-- Per-player match statistics: userId → { passes, passesSuccess, ... }
local _playerStats: { [number]: table } = {}

-- Roster of players who actually started this match. Rewards are paid only to
-- these users; late joiners and spectators are excluded.
local _participants: { [number]: boolean } = {}

-- Match queue: list of Player objects waiting to join
local _queue: { Player } = {}

-- Heartbeat connection handle
local _timerConnection: RBXScriptConnection?

-- True while a goal celebration / result screen is on screen. The clock is
-- frozen for this period so the final seconds do not bleed into the break.
local _celebrating: boolean = false

-- Re-entrancy guard: endMatch / runHalfTime must not run twice concurrently,
-- otherwise the whole reward package is paid twice.
local _ending: boolean = false

-- Goal reset debounce
local _goalScoredAt: number = 0
local GOAL_DEBOUNCE = 2   -- seconds — ignore duplicate goal triggers

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function generateMatchId(): string
	return string.format("MATCH_%d_%d", os.time(), math.random(1000, 9999))
end

local function broadcastMatchState()
	Remotes.FireAllClients(Constants.Remotes.MatchStateUpdate, {
		State    = _state,
		ScoreA   = _scoreA,
		ScoreB   = _scoreB,
		Half     = _half,
		TimeLeft = math.ceil(_timeLeft),
		MatchId  = _matchId,
		Mode     = _mode,
	})
end

local function broadcastScore()
	Remotes.FireAllClients(Constants.Remotes.ScoreUpdate, {
		ScoreA = _scoreA,
		ScoreB = _scoreB,
		Half   = _half,
	})
end

local function setState(newState: string)
	_state = newState
	broadcastMatchState()
	print(string.format("[MatchService] State → %s  [%s]", newState, _matchId))
end

--- Find the kickoff spawn position (centre circle).
local function getKickoffPosition(): Vector3
	local stadium = workspace:FindFirstChild("Stadium")
	if stadium then
		local marker = stadium:FindFirstChild("KickoffPoint", true)
		if marker and marker:IsA("BasePart") then
			return marker.Position + Vector3.new(0, Constants.BALL_RADIUS + 0.5, 0)
		end
	end
	-- Fallback: field centre at standard height
	return Vector3.new(0, 3, 0)
end

--- Return lobby spawn positions (SpawnLobby_* spawn points).
local function getLobbySpawnPositions(): { CFrame }
	local lobby = workspace:FindFirstChild("Lobby")
	local positions: { CFrame } = {}
	if lobby then
		for _, desc in ipairs(lobby:GetDescendants()) do
			if desc:IsA("SpawnLocation") and string.find(desc.Name, "SpawnLobby") then
				table.insert(positions, desc.CFrame + Vector3.new(0, 3, 0))
			end
		end
	end
	if #positions == 0 then
		-- Fallback positions around lobby origin
		local O = Constants.LOBBY_ORIGIN
		for i = 1, 8 do
			local a = ((i-1) / 8) * math.pi * 2
			table.insert(positions, CFrame.new(O + Vector3.new(math.cos(a)*20, 3, 160+math.sin(a)*20)))
		end
	end
	return positions
end

--- Teleport all players back to the lobby spawn positions.
local function teleportToLobby()
	local spawnRing = getLobbySpawnPositions()
	for i, player in ipairs(Players:GetPlayers()) do
		local pos = spawnRing[(i - 1) % #spawnRing + 1]
		local char = player.Character
		if char then
			local root = char:FindFirstChild("HumanoidRootPart")
			if root then
				root.CFrame = pos
			end
		end
		-- Reassign to spectator team (lobby team)
		TeamService.AssignToTeam(player, "Spectator")
	end
end

--- Award match-end rewards via PlayerService.
--- Only players who actually started the match are paid: a player who joined
--- thirty seconds before the whistle previously received a full payout AND a
--- rating penalty for a match they never touched.
local function awardEndRewards(winnerTeam: string?)
	if not PlayerService then return end

	for _, player in ipairs(Players:GetPlayers()) do
		if not _participants[player.UserId] then continue end

		-- A nil profile used to throw here and abort the whole loop, silently
		-- denying every remaining player their rewards.
		local profile = PlayerService.GetProfile(player)
		if not profile then
			warn(string.format(
				"[MatchService] No profile for %s at match end — skipping rewards.",
				player.Name
			))
			continue
		end

		local teamId      = TeamService.GetTeam(player)
		local isWinner    = (winnerTeam ~= nil) and (teamId == winnerTeam)
		local isDraw      = (winnerTeam == nil)
		local isSpectator = (teamId == "Spectator" or teamId == nil)

		-- Career tallies. The XP for these was already paid at the moment they
		-- happened in onGoalScored, so it is NOT paid a second time here.
		local g = _goalData[player.UserId]
		local goals   = g and g.goals or 0
		local assists = g and g.assists or 0

		-- In-match performance stats
		local mStats  = _playerStats[player.UserId] or {}
		local sPasses  = mStats.passesSuccess or 0
		local sTackles = mStats.tacklesSuccess or 0
		local sSaves   = mStats.savesSuccess or 0
		local sShots   = mStats.shotsSuccess or 0

		-- Outcome bonus
		local outcomeXP = isDraw and Constants.XP_DRAW_BONUS
			or (isWinner and Constants.XP_WIN_BONUS or Constants.XP_LOSS_BONUS)
		local outcomeCoins = isDraw and Constants.COIN_DRAW_BONUS
			or (isWinner and Constants.COIN_WIN_BONUS or Constants.COIN_LOSS_BONUS)

		-- A spectator took no part and must not be moved up or down the ladder.
		local ratingDelta = 0
		if not isSpectator then
			ratingDelta = isDraw and 0
				or (isWinner and Constants.RATING_WIN_GAIN or -Constants.RATING_LOSS_PENALTY)
		end

		local performanceXP =
			  sPasses  * Constants.XP_PER_PASS
			+ sTackles * Constants.XP_PER_TACKLE
			+ sSaves   * Constants.XP_PER_SAVE
			+ sShots   * Constants.XP_PER_SHOT_ON_TARGET

		local payload = {
			XP           = outcomeXP + performanceXP,
			Coins        = outcomeCoins,
			RatingDelta  = ratingDelta,
			GoalsScored  = goals,
			AssistsGiven = assists,
		}

		PlayerService.GrantRewards(player, payload)

		-- Record W/D/L. This was never called from anywhere, so MatchesPlayed,
		-- Wins and Losses stayed at 0 for the entire lifetime of a profile.
		PlayerService.RecordMatchResult(player, isWinner, isDraw)

		-- Send result screen with full stats
		Remotes.FireClient(Constants.Remotes.RewardsGranted, player, payload)
		Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
			Type     = "MatchResult",
			IsWinner = isWinner,
			IsDraw   = isDraw,
			ScoreA   = _scoreA,
			ScoreB   = _scoreB,
			Stats    = mStats,
			Goals    = goals,
			Assists  = assists,
			Level    = profile.Level,
		})
	end
end

-- ─────────────────────────────────────────────
-- Countdown coroutine
-- ─────────────────────────────────────────────

local function runCountdown(seconds: number, onComplete: () -> ())
	local remaining = seconds
	while remaining > 0 do
		Remotes.FireAllClients(Constants.Remotes.MatchCountdown, remaining)
		task.wait(1)
		remaining -= 1
	end
	onComplete()
end

-- ─────────────────────────────────────────────
-- Half-time flow
-- ─────────────────────────────────────────────

local function startSecondHalf()
	_half      = 2
	_timeLeft  = _config.Duration
	_kickoffTeam = (_scoreA >= _scoreB) and "TeamB" or "TeamA"   -- trailing team kicks off
	_goalScoredAt = 0   -- clear goal debounce so the 2nd half can't swallow an early goal
	_ending     = false

	-- Swap teams' sides by teleporting to spawn (sides swapped in stadium layout)
	TeamService.TeleportTeamToSpawn("TeamA")
	TeamService.TeleportTeamToSpawn("TeamB")

	task.wait(1)

	BallService.PlaceBall(getKickoffPosition())

	-- Kickoff player
	local kickoffPlayers = TeamService.GetTeamPlayers(_kickoffTeam)
	if kickoffPlayers[1] then
		BallService.GrantPossessionToPlayer(kickoffPlayers[1])
	end

	setState("Active")
	BallService.SetMatchActive(true)
	print("[MatchService] Second half started.")
end

local function runHalfTime()
	setState("HalfTime")
	BallService.SetMatchActive(false)
	Remotes.FireAllClients(Constants.Remotes.HalfTimeNotify, {
		ScoreA = _scoreA,
		ScoreB = _scoreB,
	})
	task.wait(_config.HalfTime)
	-- The match may have been force-ended during the break; do not resurrect it.
	if _state ~= "HalfTime" then return end
	startSecondHalf()
end

-- ─────────────────────────────────────────────
-- Match end
-- ─────────────────────────────────────────────

local function endMatch()
	-- Guard: ForceEndMatch and the timer could otherwise run two concurrent
	-- endMatch coroutines and pay the full reward package twice.
	if _ending and _state == "Ended" then return end
	_ending      = true
	_celebrating = true

	if _timerConnection then
		_timerConnection:Disconnect()
		_timerConnection = nil
	end

	BallService.SetMatchActive(false)
	setState("Ended")

	-- Determine winner
	local winnerTeam: string?
	if _scoreA > _scoreB then
		winnerTeam = "TeamA"
	elseif _scoreB > _scoreA then
		winnerTeam = "TeamB"
	else
		winnerTeam = nil   -- draw
	end

	-- Broadcast final result
	Remotes.FireAllClients(Constants.Remotes.MatchStateUpdate, {
		State      = "Ended",
		ScoreA     = _scoreA,
		ScoreB     = _scoreB,
		WinnerTeam = winnerTeam,
		MatchId    = _matchId,
	})

	awardEndRewards(winnerTeam)

	-- Clear the per-match objective track so it does not linger in the town UI.
	if ObjectiveService then
		for _, p in ipairs(Players:GetPlayers()) do
			ObjectiveService.OnMatchEnd(p)
		end
	end

	-- Clean up after short delay then return to lobby state
	task.delay(8, function()
		setState("Resetting")
		BallService.SetMatchActive(false)
		TeamService.ClearAssignments()
		BallService.PlaceBall(getKickoffPosition())
		_goalData   = {}
		_passChain  = {}
		_playerStats = {}
		task.wait(2)

		-- Teleport players back to lobby
		teleportToLobby()

		-- Re-enable lobby ball mode
		BallService.SetLobbyMode(true)

		setState("Waiting")
		-- Clear queue
		_queue = {}
		print("[MatchService] Match ended, players returned to lobby.")
	end)
end

-- ─────────────────────────────────────────────
-- Match timer (Heartbeat-based, server-side)
-- ─────────────────────────────────────────────

local function startTimer()
	local lastTick = tick()

	_timerConnection = RunService.Heartbeat:Connect(function()
		if _state ~= "Active" then return end
		-- Clock is frozen during a goal celebration / result screen
		if _celebrating or _ending then return end

		local now = tick()
		local dt  = now - lastTick
		lastTick  = now

		_timeLeft = math.max(0, _timeLeft - dt)

		-- Broadcast every ~1 second (avoid flooding)
		-- We use a simple integer-change check
		local intLeft = math.ceil(_timeLeft)
		local prevInt = math.ceil(_timeLeft + dt)
		if intLeft ~= prevInt or _timeLeft <= 0 then
			broadcastMatchState()
		end

		if _timeLeft <= 0 and not _ending then
			_ending = true
			if _half == 1 then
				task.spawn(runHalfTime)
			else
				task.spawn(endMatch)
			end
		end
	end)
end

-- ─────────────────────────────────────────────
-- Goal handler (called by BallService callback)
-- ─────────────────────────────────────────────

local function onGoalScored(scoringTeam: string, scorerUserId: number?, assisterUserId: number?)
	if _state ~= "Active" then return end
	if _celebrating then return end

	-- ── Validate BEFORE consuming the debounce window ────────────────────
	-- Previously _goalScoredAt was committed first, so an invalid scoringTeam
	-- silently burned the 2 s window and swallowed the next legitimate goal.
	if scoringTeam ~= "TeamA" and scoringTeam ~= "TeamB" then return end

	-- Debounce duplicate triggers (a ball resting in the goal keeps firing Touched)
	local now = tick()
	if (now - _goalScoredAt) < GOAL_DEBOUNCE then return end
	_goalScoredAt = now

	-- ── Own-goal protection ──────────────────────────────────────────────
	-- The scorer is derived from "last player to touch the ball", which any
	-- nearby player can become. Without this check a defender who deflects the
	-- ball into his own net is paid a full goal bonus. Only credit the bonus
	-- when the last touch was by a player on the scoring team.
	local scorerPlayer: Player? = if scorerUserId then Players:GetPlayerByUserId(scorerUserId) else nil
	if scorerPlayer and TeamService then
		local scorerTeam = TeamService.GetTeam(scorerPlayer)
		if scorerTeam and scorerTeam ~= scoringTeam then
			warn(string.format(
				"[MatchService] Own goal by %s (%s) — no scorer reward.",
				scorerPlayer.DisplayName, tostring(scorerTeam)
			))
			scorerUserId   = nil
			assisterUserId = nil
		end
	end
	if assisterUserId and TeamService then
		local assisterPlayer = Players:GetPlayerByUserId(assisterUserId)
		if assisterPlayer and TeamService.GetTeam(assisterPlayer) ~= scoringTeam then
			assisterUserId = nil
		end
	end

	-- Update score
	if scoringTeam == "TeamA" then
		_scoreA += 1
	else
		_scoreB += 1
	end

	-- Track goal data
	if scorerUserId then
		if not _goalData[scorerUserId] then
			_goalData[scorerUserId] = { goals = 0, assists = 0 }
		end
		_goalData[scorerUserId].goals += 1
	end
	if assisterUserId and _goalData[assisterUserId] then
		_goalData[assisterUserId].assists = (_goalData[assisterUserId].assists or 0) + 1
	end

	print(string.format(
		"[MatchService] GOAL! %s scores. Score: TeamA %d – %d TeamB | Scorer: %s | Assist: %s",
		scoringTeam, _scoreA, _scoreB,
		tostring(scorerUserId), tostring(assisterUserId)
	))

	-- Award XP/energy for goal and assist.
	-- This is the ONLY place goal/assist XP is paid — awardEndRewards reads the
	-- tallies below instead of paying again, which previously double-dipped.
	if PlayerService then
		if scorerUserId then
			local scorer = Players:GetPlayerByUserId(scorerUserId)
			if scorer then
				PlayerService.GrantRewards(scorer, {
					XP    = Constants.XP_PER_GOAL,
					Coins = Constants.COIN_PER_GOAL,
				})
				PlayerService.AddEnergy(scorer, Constants.ENERGY_GAIN_GOAL)
				PlayerService.AddAwakeningMeter(scorer, Constants.AWAKEN_GAIN_GOAL)
			end
		end
		if assisterUserId then
			local assister = Players:GetPlayerByUserId(assisterUserId)
			if assister then
				PlayerService.GrantRewards(assister, {
					XP    = Constants.XP_PER_ASSIST,
					Coins = 5,
				})
				PlayerService.AddEnergy(assister, Constants.ENERGY_GAIN_ASSIST)
				PlayerService.AddAwakeningMeter(assister, Constants.AWAKEN_GAIN_ASSIST)
			end
		end
	end

	-- Objectives. Optional so MatchService does not hard-depend on the service.
	if ObjectiveService then
		local scorerObj   = if scorerUserId then Players:GetPlayerByUserId(scorerUserId) else nil
		local assisterObj = if assisterUserId then Players:GetPlayerByUserId(assisterUserId) else nil
		if scorerObj then
			ObjectiveService.Report(scorerObj, "Goal", 1)
			ObjectiveService.Report(scorerObj, "MatchGoal", 1)
		end
		if assisterObj then
			ObjectiveService.Report(assisterObj, "Assist", 1)
			ObjectiveService.Report(assisterObj, "MatchAssist", 1)
		end
	end

	-- Freeze the clock during the celebration. BallService is already stopped
	-- below, but the timer used to keep running for the full reset delay.
	_celebrating = true

	-- Broadcast goal event
	BallService.SetMatchActive(false)

	Remotes.FireAllClients(Constants.Remotes.GoalScored, {
		ScoringTeam    = scoringTeam,
		ScoreA         = _scoreA,
		ScoreB         = _scoreB,
		ScorerUserId   = scorerUserId,
		AssistUserId   = assisterUserId,
		MatchId        = _matchId,
	})

	broadcastScore()

	-- Goal celebration delay then reset
	task.delay(Constants.GOAL_RESET_DELAY, function()
		if _state == "Active" or _state == "Waiting" then
			-- Reset positions
			TeamService.TeleportTeamToSpawn("TeamA")
			TeamService.TeleportTeamToSpawn("TeamB")
			task.wait(0.5)

			-- Kickoff goes to team that conceded
			local nextKickoff = (scoringTeam == "TeamA") and "TeamB" or "TeamA"
			BallService.PlaceBall(getKickoffPosition())
			local kickoffPlayers = TeamService.GetTeamPlayers(nextKickoff)
			if kickoffPlayers[1] then
				BallService.GrantPossessionToPlayer(kickoffPlayers[1])
			end

			BallService.SetMatchActive(true)
			_celebrating = false
			setState("Active")
		else
			_celebrating = false
		end
	end)
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

--- Initialise MatchService with required service references.
function MatchService.Init(ballService, teamService)
	BallService = ballService
	TeamService = teamService

	-- Register goal callback with BallService
	BallService.SetGoalCallback(onGoalScored)

	-- Drop departed players from the queue, roster and team assignments.
	-- Without this a disconnecting player stays in _queue forever and their
	-- ghost entry permanently skews AutoAssign for the rest of the match.
	Players.PlayerRemoving:Connect(function(player)
		for i = #_queue, 1, -1 do
			if _queue[i] == player then
				table.remove(_queue, i)
			end
		end
		_participants[player.UserId] = nil
		_goalData[player.UserId]     = nil
		_playerStats[player.UserId]   = nil
		_passChain[player.UserId]     = nil
		if TeamService.RemovePlayer then
			TeamService.RemovePlayer(player)
		end
	end)

	print("[MatchService] Initialised.")
end

--- Inject PlayerService (avoids circular require at Init time).
function MatchService.SetPlayerService(ps)
	PlayerService = ps
end

--- Inject ObjectiveService so goal/assist/kickoff advance match objectives.
function MatchService.SetObjectiveService(os_)
	ObjectiveService = os_
end

--- Start a new match with the given mode and optional player list.
--- If players is nil, uses all currently connected players.
function MatchService.StartMatch(mode: string?, playerList: { Player }?)
	if _state ~= "Waiting" and _state ~= "Resetting" then
		warn("[MatchService] Cannot start match — current state: " .. _state)
		return
	end

	-- Only modes explicitly marked available may start. 7v7 / 8v8 are
	-- announced as coming-soon content and have no matchmaking behind them.
	local requested = mode or "5v5"
	if not MatchConfig.IsAvailable(requested) then
		warn(string.format("[MatchService] Refusing to start unavailable mode '%s'.", requested))
		return
	end
	mode = requested

	_mode     = mode or "5v5"
	_config   = MatchConfig.Get(_mode)
	_matchId  = generateMatchId()
	_scoreA   = 0
	_scoreB   = 0
	_half     = 1
	_timeLeft = _config.Duration
	_goalData = {}
	_passChain = {}
	_playerStats = {}
	_goalScoredAt = 0
	_celebrating  = false
	_ending       = false

	local participants = playerList or Players:GetPlayers()

	-- Record the roster. Only these users are paid at match end, and only they
	-- count for team balance — a late joiner must not become a phantom player
	-- that skews every subsequent AutoAssign.
	_participants = {}
	for _, player in ipairs(participants) do
		_participants[player.UserId] = true
	end

	-- Assign teams
	TeamService.ClearAssignments()
	for _, player in ipairs(participants) do
		TeamService.AutoAssign(player)
	end

	-- Teleport to spawn
	TeamService.TeleportTeamToSpawn("TeamA")
	TeamService.TeleportTeamToSpawn("TeamB")

	-- Kickoff setup
	_kickoffTeam = "TeamA"
	BallService.PlaceBall(getKickoffPosition())

	setState("Countdown")
	BallService.SetMatchActive(false)
	BallService.SetLobbyMode(false)   -- disable lobby ball while match runs

	-- Countdown then kickoff
	task.spawn(function()
		runCountdown(_config.CountdownSec, function()
			-- Grant possession to first TeamA player
			local kickoffPlayers = TeamService.GetTeamPlayers(_kickoffTeam)
			if kickoffPlayers[1] then
				BallService.GrantPossessionToPlayer(kickoffPlayers[1])
			end

		setState("Active")
		BallService.SetMatchActive(true)
		startTimer()

		-- Roll a fresh set of match objectives for each participant.
		if ObjectiveService then
			for _, p in ipairs(participants) do
				ObjectiveService.OnMatchStart(p)
			end
		end
		-- "Play 1 match" daily objective
		if ObjectiveService then
			for _, p in ipairs(participants) do
				ObjectiveService.Report(p, "MatchPlayed", 1)
			end
		end

		print(string.format(
			"[MatchService] Match %s started! Mode: %s  Half: 1  Duration: %ds",
			_matchId, _mode, _config.Duration
		))
		end)
	end)
end

--- Immediately end the active match (admin / forfeit).
function MatchService.ForceEndMatch()
	if _state == "Active" or _state == "HalfTime" or _state == "Countdown" then
		task.spawn(endMatch)
	end
end

--- Returns current match state string.
function MatchService.GetState(): string
	return _state
end

--- Returns a snapshot of current match data.
function MatchService.GetMatchData()
	return {
		MatchId  = _matchId,
		Mode     = _mode,
		State    = _state,
		ScoreA   = _scoreA,
		ScoreB   = _scoreB,
		Half     = _half,
		TimeLeft = math.ceil(_timeLeft),
	}
end

--- Track a pass chain (called by BallService pass handler via callback injection).
--- When scorer scores, we look up their lastPasser for assist credit.
function MatchService.RecordPass(passerUserId: number, receiverUserId: number)
	if passerUserId ~= receiverUserId then
		_passChain[receiverUserId] = passerUserId
	end
end

--- Returns score as { TeamA, TeamB }.
function MatchService.GetScore(): { TeamA: number, TeamB: number }
	return { TeamA = _scoreA, TeamB = _scoreB }
end

-- ─────────────────────────────────────────────
-- Match queue system
-- ─────────────────────────────────────────────

--- Add a player to the match queue.
function MatchService.QueueJoin(player: Player)
	if _state ~= "Waiting" then
		return false
	end
	-- Remove if already queued
	for i, p in ipairs(_queue) do
		if p == player then
			return true
		end
	end
	table.insert(_queue, player)
	print(string.format("[MatchService] %s joined match queue (%d/%d)",
		player.Name, #_queue, _config.MaxPlayers))
	return true
end

--- Remove a player from the match queue.
function MatchService.QueueLeave(player: Player)
	for i, p in ipairs(_queue) do
		if p == player then
			table.remove(_queue, i)
			return
		end
	end
end

--- Returns the current queue size.
function MatchService.GetQueueSize(): number
	return #_queue
end

--- Returns the list of queued players.
function MatchService.GetQueuedPlayers(): { Player }
	return _queue
end

--- Check if enough players are queued to start.
local MIN_QUEUE = 2
function MatchService.CanStartMatch(): boolean
	return #_queue >= MIN_QUEUE
end

--- Start a match from the current queue.
function MatchService.StartMatchFromQueue()
	if _state ~= "Waiting" and _state ~= "Resetting" then
		return false
	end
	if not MatchService.CanStartMatch() then
		return false
	end

	-- Use queued players as participants
	local participants = {}
	for _, p in ipairs(_queue) do
		table.insert(participants, p)
	end

	MatchService.StartMatch("5v5", participants)
	_queue = {}
	return true
end

-- ─────────────────────────────────────────────
-- Per-player match statistics
-- ─────────────────────────────────────────────

--- Increment a per-player match stat.
function MatchService.RecordPlayerStat(userId: number, statName: string, amount: number?)
	local stats = _playerStats[userId]
	if not stats then
		stats = {
			passes         = 0, passesSuccess = 0,
			dribbles       = 0, dribblesSuccess = 0,
			tackles        = 0, tacklesSuccess = 0,
			blocks         = 0,
			saves          = 0,
			shots          = 0, shotsSuccess = 0,
		}
		_playerStats[userId] = stats
	end
	stats[statName] = (stats[statName] or 0) + (amount or 1)
end

--- Returns the per-player match stats for a player.
function MatchService.GetPlayerStats(player: Player): table?
	return _playerStats[player.UserId]
end

-- ─────────────────────────────────────────────

-- ─────────────────────────────────────────────
-- RemoteFunction: GetMatchData (client can query)
-- ─────────────────────────────────────────────
-- Bound in ServerMain after Init.

return MatchService
