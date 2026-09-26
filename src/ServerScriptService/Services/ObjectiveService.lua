--[[
	MythicStrikers — ObjectiveService
	Short-term goals that give players a reason to log in and a reason to keep
	playing. Two independent tracks:

		DAILY  — a small rotating set that resets once per day.
		MATCH  — per-match football objectives that reward teamwork, chosen at
		         kickoff and cleared when the match ends.

	OBJECTIVES NEVER GATE PROGRESS. They are an extra reward on top of normal
	XP, never the only source of it, and missing them costs the player nothing
	beyond the bonus.

	DATA FLOW:
		• Progress lives on profile.Objectives (persisted with the profile).
		• The server is the only writer. Clients receive a snapshot through the
		  ObjectiveUpdate remote and render it; they never report progress.

	ANTI-SPAM:
		Every bump goes through bump(), which is rate limited per player and
		only ever called from server-side gameplay events (goal, tackle, save,
		successful pass, technique landing). A client cannot advance an
		objective directly.
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes   = require(ReplicatedStorage.Remotes)

local ObjectiveService = {}

local PlayerService: any

-- ─────────────────────────────────────────────
-- Objective definitions
-- ─────────────────────────────────────────────

-- Daily pool. The player receives DAILY_SLOTS of these each day, chosen
-- deterministically from the date so every account in the world gets the same
-- set and it is not re-rolled by rejoining.
local DAILY_POOL = {
	{ Id = "daily_pass",    Label = "Complete 10 successful passes",     Target = 10, XP = 120, Coins = 25 },
	{ Id = "daily_shot",    Label = "Take 5 shots on target",             Target = 5,  XP = 100, Coins = 20 },
	{ Id = "daily_tackle",  Label = "Win 3 tackles",                      Target = 3,  XP = 90,  Coins = 18 },
	{ Id = "daily_tech",    Label = "Land 5 techniques",                  Target = 5,  XP = 110, Coins = 22 },
	{ Id = "daily_dribble", Label = "Complete 15 dribbles",               Target = 15, XP = 90,  Coins = 18 },
	{ Id = "daily_save",    Label = "Make 2 saves",                       Target = 2,  XP = 130, Coins = 26 },
	{ Id = "daily_match",   Label = "Play 1 match",                       Target = 1,  XP = 150, Coins = 30 },
	{ Id = "daily_goal",    Label = "Score 1 goal",                       Target = 1,  XP = 160, Coins = 32 },
	{ Id = "daily_assist",  Label = "Provide 1 assist",                   Target = 1,  XP = 140, Coins = 28 },
	{ Id = "daily_train",   Label = "Complete 1 training session",        Target = 1,  XP = 80,  Coins = 15 },
}

-- Match pool. Weighted toward teamwork and varied roles so two players on the
-- same team are not pushed toward identical behaviour.
local MATCH_POOL = {
	{ Id = "m_assist",  Label = "Provide an assist",            Target = 1, XP = 120, Coins = 20 },
	{ Id = "m_goal",    Label = "Score a goal",                  Target = 1, XP = 130, Coins = 22 },
	{ Id = "m_pass5",   Label = "Complete 5 passes",             Target = 5, XP = 90,  Coins = 15 },
	{ Id = "m_tackle2", Label = "Make 2 tackles",                Target = 2, XP = 90,  Coins = 15 },
	{ Id = "m_save3",   Label = "Make 3 saves",                  Target = 3, XP = 110, Coins = 18 },
	{ Id = "m_tech1",   Label = "Land a technique successfully", Target = 1, XP = 100, Coins = 16 },
	{ Id = "m_block",   Label = "Win 4 challenges",              Target = 4, XP = 85,  Coins = 14 },
}

local DAILY_SLOTS = 3
local MATCH_SLOTS = 2

-- ─────────────────────────────────────────────
-- Runtime state
-- ─────────────────────────────────────────────

-- Rate limiting: max one bump per objective per player per this many seconds.
local BUMP_COOLDOWN = 0.5

-- Cooldown guard stops a burst of passes from completing "5 passes" in one
-- frame. Chosen to be shorter than any realistic chain of real actions.
local _bumpCooldown: { [number]: { [string]: number } } = {}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function todayKey(): string
	return os.date("!%Y-%m-%d")
end

--- Deterministic pick: same date + same slot index always yields the same
--- objective, so a player cannot reroll their dailies by rejoining.
local function pickDeterministic(pool, dateKey: string, slot: number)
	local h = 5381
	for i = 1, #dateKey do
		h = (h * 33 + dateKey:byte(i)) % 4294967296
	end
	h = (h + slot * 2654435761) % 4294967296
	return pool[(h % #pool) + 1]
end

local function clone(def: table): table
	return {
		Id       = def.Id,
		Label    = def.Label,
		Target   = def.Target,
		Progress = 0,
		RewardXP = def.XP,
		RewardCoins = def.Coins,
		Complete = false,
		Claimed  = false,
	}
end

--- Send the current objective state to a single client.
local function push(player: Player)
	local profile = PlayerService and PlayerService.GetProfile(player)
	if not profile then return end
	local objs = profile.Objectives
	Remotes.FireClient(Constants.Remotes.ObjectiveUpdate, player, {
		Daily = objs.Daily,
		Match = objs.Match,
	})
end

--- Reset the daily set if the date rolled over. Called on join and before any
--- daily read, so a player returning the next day gets a fresh set.
local function ensureDaily(player: Player)
	local profile = PlayerService and PlayerService.GetProfile(player)
	if not profile or not profile.Objectives then return end

	local objs = profile.Objectives
	local today = todayKey()
	if objs.DailyDate == today and #objs.Daily > 0 then
		return
	end

	objs.DailyDate = today
	objs.Daily = {}
	for slot = 1, DAILY_SLOTS do
		local def = pickDeterministic(DAILY_POOL, today, slot)
		table.insert(objs.Daily, clone(def))
	end
end

--- Roll a fresh set of match objectives. Called at kickoff.
local function rollMatchObjectives(player: Player)
	local profile = PlayerService and PlayerService.GetProfile(player)
	if not profile or not profile.Objectives then return end

	local objs = profile.Objectives
	objs.Match = {}
	for slot = 1, MATCH_SLOTS do
		-- Seed from the userId so two players on one team get different asks.
		local def = pickDeterministic(MATCH_POOL, tostring(player.UserId), slot)
		table.insert(objs.Match, clone(def))
	end
end

--- Advance a named objective and pay out on completion.
--- Safe to call for objectives the player does not have — it just returns.
local function bump(player: Player, objectiveId: string, amount: number?)
	local profile = PlayerService and PlayerService.GetProfile(player)
	if not profile or not profile.Objectives then return end

	local guard = _bumpCooldown[player.UserId]
	if not guard then
		guard = {}
		_bumpCooldown[player.UserId] = guard
	end
	local last = guard[objectiveId]
	if last and (tick() - last) < BUMP_COOLDOWN then return end
	guard[objectiveId] = tick()

	local step = amount or 1

	-- Check both tracks so a single event can advance either.
	for _, track in ipairs({"Daily", "Match"}) do
		local list = profile.Objectives[track]
		if list then
			for _, obj in ipairs(list) do
				if obj.Id == objectiveId and not obj.Complete then
					obj.Progress = math.min(obj.Target, obj.Progress + step)
					if obj.Progress >= obj.Target then
						obj.Complete = true
						PlayerService.GrantRewards(player, {
							XP    = obj.RewardXP,
							Coins = obj.RewardCoins,
						})
						Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
							Type    = "ObjectiveComplete",
							Label   = obj.Label,
							RewardXP = obj.RewardXP,
							RewardCoins = obj.RewardCoins,
							Message = "OBJECTIVE COMPLETE — " .. obj.Label,
						})
						print(string.format(
							"[ObjectiveService] %s completed '%s'",
							player.DisplayName, obj.Id
						))
					end
				end
			end
		end
	end

	push(player)
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

--- Report a gameplay event. Every objective in the game is driven through
--- here, from server-side events only.
function ObjectiveService.Report(player: Player, event: string, amount: number?)
	local map = {
		Pass        = "daily_pass",
		ShotOnTarget = "daily_shot",
		Tackle      = "daily_tackle",
		Technique   = "daily_tech",
		Dribble     = "daily_dribble",
		Save        = "daily_save",
		MatchPlayed = "daily_match",
		Goal        = "daily_goal",
		Assist      = "daily_assist",
		Training    = "daily_train",
		MatchPass   = "m_pass5",
		MatchGoal   = "m_goal",
		MatchAssist = "m_assist",
		MatchTackle = "m_tackle2",
		MatchSave   = "m_save3",
		MatchTech   = "m_tech1",
		MatchBlock  = "m_block",
	}
	local id = map[event]
	if not id then return end
	bump(player, id, amount)
end

--- Call at kickoff. Clears the previous match set and rolls a new one.
function ObjectiveService.OnMatchStart(player: Player)
	rollMatchObjectives(player)
	push(player)
end

--- Call when a match finishes. Clears the match track so it does not linger
--- in the town UI.
function ObjectiveService.OnMatchEnd(player: Player)
	local profile = PlayerService and PlayerService.GetProfile(player)
	if not profile or not profile.Objectives then return end
	profile.Objectives.Match = {}
	push(player)
end

--- Returns a snapshot of a player's objectives (server-side use).
function ObjectiveService.GetObjectives(player: Player)
	local profile = PlayerService and PlayerService.GetProfile(player)
	if not profile or not profile.Objectives then return { Daily = {}, Match = {} } end
	return profile.Objectives
end

--- Initialise. Call after PlayerService.Init().
function ObjectiveService.Init(playerService: any)
	PlayerService = playerService

	Players.PlayerAdded:Connect(function(player)
		task.defer(function()
			ensureDaily(player)
			push(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		_bumpCooldown[player.UserId] = nil
	end)

	-- Players already in the server (Studio test)
	for _, player in ipairs(Players:GetPlayers()) do
		task.defer(function()
			ensureDaily(player)
			push(player)
		end)
	end

	print("[ObjectiveService] Initialised.")
end

return ObjectiveService
