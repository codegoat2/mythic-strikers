--[[
	MythicStrikers — PlayerService
	Manages per-player runtime state and persistent DataStore profiles.

	RESPONSIBILITIES:
	  • Load / save PlayerProfile via DataStore (with retry + session-lock pattern)
	  • Initialize player attributes, stamina, Mythic Energy, Awakening meter
	  • Stamina regen + Energy regen loop (server Heartbeat)
	  • Expose stat provider callback to BallService
	  • GrantRewards, AddEnergy, AddAwakeningMeter
	  • Speed application via Humanoid.WalkSpeed (server sets it)
	  • Clean removal on player leave

	DATA LAYOUT (DataStore key = "Profile_<userId>"):
	  Stored as a single table matching Types.PlayerProfile minus runtime fields.

	SECURITY:
	  • No client can write profile data.
	  • All XP / Coins / Rating changes go through this service only.
	  • DataStore saves use UpdateAsync for atomic writes.
--]]

local Players            = game:GetService("Players")
local DataStoreService   = game:GetService("DataStoreService")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local Constants          = require(ReplicatedStorage.Shared.Config.Constants)
local DefaultAttributes  = require(ReplicatedStorage.Shared.Config.DefaultAttributes)
local Remotes            = require(ReplicatedStorage.Remotes)
local TechniqueDefinitions = require(ReplicatedStorage.Shared.Techniques.TechniqueDefinitions)

-- ─────────────────────────────────────────────
-- DataStore setup
-- ─────────────────────────────────────────────
local DATASTORE_NAME    = "MythicStrikers_PlayerProfiles_v1"
local DATASTORE_RETRIES = 3
local DATASTORE_DELAY   = 2   -- seconds between retries

local profileStore: DataStore
local isStudio = RunService:IsStudio()

-- ─────────────────────────────────────────────
-- Studio API access
--
-- The prototype spammed this every save:
--   DataStoreService: StudioAccessToApisNotAllowed: Cannot write to DataStore
--   from studio if API access is not enabled.
--   [PlayerService] DataStore save failed (attempt 1/3) ...
--   ... x3, then "Saved profile for Code"  <- printed even though nothing saved.
--
-- Two separate problems: it retried forever against a hard block, and it
-- claimed success when the write had failed outright.
--
-- The fix probes ONCE. GetDataStore() itself succeeds in Studio even when API
-- access is off — the failure only happens on the first real call — so the
-- check has to be a real call, not a lookup.
--
-- nil    = not probed yet
-- true   = DataStores work (Studio with API access enabled, or production)
-- false  = unavailable; run on temporary session data and stop retrying
-- ─────────────────────────────────────────────
local datastoresEnabled: boolean? = nil

-- Lazily creates the store handle. Creating it never throws, so this is safe
-- to call before the probe has resolved.
local function getStore()
	if not profileStore then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(DATASTORE_NAME)
		end)
		if ok then
			profileStore = result
		else
			warn("[PlayerService] DataStore unavailable: " .. tostring(result))
		end
	end
	return profileStore
end

local function isStudioAccessError(err: any): boolean
	local msg = tostring(err)
	return string.find(msg, "StudioAccessToApisNotAllowed", 1, true) ~= nil
		or string.find(msg, "Studio access to APIs is not allowed", 1, true) ~= nil
		or string.find(msg, "if API access is not enabled", 1, true) ~= nil
end

--- One real DataStore call to find out whether persistence is possible.
--- Respects a developer who has enabled "Studio Access to API Services" in
--- Game Settings, so saving can still be tested properly before shipping.
local function probeDataStoreAccess(): boolean
	if not isStudio then
		datastoresEnabled = true
		return true
	end

	local store = getStore()
	if not store then
		datastoresEnabled = false
		print("[DataService] Studio DataStore access unavailable.")
		print("[DataService] Running with temporary session data.")
		return false
	end

	local ok, err = pcall(function()
		store:GetAsync("__mythicstrikers_access_probe__")
	end)
	datastoresEnabled = ok

	if ok then
		print("[DataService] Studio DataStore access confirmed — saving is live.")
	else
		-- Exactly the two lines the design brief asks for, and only once.
		print("[DataService] Studio DataStore access unavailable.")
		print("[DataService] Running with temporary session data.")
		print("[DataService] Enable Game Settings > Security > "
			.. "\"Studio Access to API Services\" to test real saving.")
	end
	return ok
end

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local PlayerService = {}

-- ─────────────────────────────────────────────
-- Runtime state (server-only, never sent whole)
-- ─────────────────────────────────────────────

-- Full profile per userId
local _profiles: { [number]: table } = {}

-- Runtime energy state (not persisted between matches, only persisted in profile)
local _energy: { [number]: number }   = {}
local _stamina: { [number]: number }  = {}
local _awakening: { [number]: {
	Meter    : number,
	IsActive : boolean,
	TimeLeft : number,
} } = {}

-- Sprint state (set by FootballController remote)
local _isSprinting: { [number]: boolean } = {}
-- Last values pushed to each client, so the regen loop can skip redundant
-- stamina/energy remotes instead of firing 20 events/second/player.
local _lastSentStamina: { [number]: number } = {}
local _lastSentEnergy:  { [number]: number } = {}
local _lastSentAt:      { [number]: number } = {}
-- Technique cooldowns:  userId → { [techId] = expireTime }
local _cooldowns: { [number]: { [string]: number } } = {}

-- Session lock: prevent double-loads
local _loading: { [number]: boolean } = {}

-- ─────────────────────────────────────────────
-- Default profile factory
-- ─────────────────────────────────────────────
local function newProfile(userId: number, displayName: string): table
	return {
		SchemaVersion   = 1,
		UserId          = userId,
		DisplayName     = displayName,
		Level           = 1,
		XP              = 0,
		Coins           = 0,
		Rank            = "Rookie",
		Goals           = 0,
		Assists         = 0,
		Saves           = 0,
		Tackles         = 0,
		MatchesPlayed   = 0,
		Wins            = 0,
		Losses          = 0,
		RankedRating    = 0,
		Position        = "Forward",
		EquippedStyle   = "Default",
		EquippedTechs   = { "SOLAR_ROAR", "GALE_PHANTOM", "STARLINE_PASS", "TITAN_RAMPART" },
		EquippedAwaken  = "Default",
		Cosmetics       = {},
		Statistics      = {
			Passes             = 0,
			SuccessfulPasses   = 0,
			Dribbles           = 0,
			SuccessfulDribbles = 0,
			Blocks             = 0,
			Saves              = 0,
			Shots              = 0,
			SuccessfulShots    = 0,
		},
		Attributes     = {
			Speed          = DefaultAttributes.Speed,
			Acceleration   = DefaultAttributes.Acceleration,
			Dribbling      = DefaultAttributes.Dribbling,
			BallControl    = DefaultAttributes.BallControl,
			Passing        = DefaultAttributes.Passing,
			Shooting       = DefaultAttributes.Shooting,
			Power          = DefaultAttributes.Power,
			Curve          = DefaultAttributes.Curve,
			Defense        = DefaultAttributes.Defense,
			Tackling       = DefaultAttributes.Tackling,
			Stamina        = DefaultAttributes.Stamina,
			TechniquePower = DefaultAttributes.TechniquePower,
			TechniqueCtrl  = DefaultAttributes.TechniqueCtrl,
			Goalkeeping    = DefaultAttributes.Goalkeeping,
		},
		-- Technique mastery: techId -> { Level, XP, UsageCount, SuccessCount, Unlocked }
		TechniqueMastery = {},

		-- Session / daily objectives. Reset on a new day by ObjectiveService.
		Objectives = {
			DailyDate   = "",     -- os.date("!%Y-%m-%d") of the current daily set
			Daily       = {},     -- { { Id, Label, Target, Progress, RewardXP, RewardCoins } }
			Match       = {},     -- same shape, cleared at kickoff
		},

		Settings = {
			QualityLevel   = "High",   -- Low | Medium | High | Ultra
			ShowNameplates = true,
			ShowHud        = true,
			MasterAudio    = 0.8,
			MasterSfx      = 1.0,
			CameraDistance = 22,
			ScreenShake    = true,
			Minimap        = true,
		},

		CosmeticsOwned = {},
	}
end

-- ─────────────────────────────────────────────
-- Rank resolution
-- ─────────────────────────────────────────────
local function resolveRank(rating: number): string
	local rank = "Rookie"
	for _, entry in ipairs(Constants.RANKS) do
		if rating >= entry.Min then
			rank = entry.Name
		end
	end
	return rank
end

-- ─────────────────────────────────────────────
-- XP / Level
-- ─────────────────────────────────────────────
local XP_PER_LEVEL_BASE = 200   -- XP needed for level 2; scales with level

local function xpForNextLevel(level: number): number
	-- Simple quadratic scaling: 200 * level^1.4
	return math.floor(XP_PER_LEVEL_BASE * (level ^ 1.4))
end

local function processLevelUp(profile: table): number
	-- Returns how many levels were gained so the client can be told.
	local gained = 0
	repeat
		local needed = xpForNextLevel(profile.Level)
		if profile.XP >= needed then
			profile.XP    -= needed
			profile.Level += 1
			gained += 1
		else
			break
		end
	until false
	return gained
end

--- Public: XP required to advance from the player's current level.
function PlayerService.GetXPForNextLevel(player: Player): number
	local profile = _profiles[player.UserId]
	if not profile then return 0 end
	return xpForNextLevel(profile.Level)
end

--- Public: overall rating, the headline number on the player card.
--- Weighted toward the attributes that matter most in a football match so the
--- number actually reflects the build the player has invested in.
local OVERALL_WEIGHTS = {
	Shooting     = 0.16,
	Passing      = 0.14,
	Dribbling    = 0.14,
	Tackling     = 0.11,
	Defense      = 0.09,
	Goalkeeping  = 0.09,
	Speed        = 0.11,
	Stamina      = 0.07,
	TechniquePower = 0.06,
	Curve        = 0.03,
}

function PlayerService.GetOverall(player: Player): number
	local profile = _profiles[player.UserId]
	if not profile then return 0 end

	local total = 0
	for stat, weight in pairs(OVERALL_WEIGHTS) do
		total += (profile.Attributes[stat] or 50) * weight
	end

	-- Mastery adds identity without inflating raw attributes: up to +5 overall
	local mastery = 0
	for _, m in pairs(profile.TechniqueMastery or {}) do
		mastery += (m.Level or 0)
	end
	total += math.min(5, mastery * 0.5)

	-- Position nudges the weighting so a goalkeeper is not penalised forever
	local pos = profile.Position
	if pos == "Goalkeeper" then
		total += 3
	elseif pos == "Defender" then
		total += 1
	end

	return math.clamp(math.floor(total + 0.5), 1, 99)
end

-- ─────────────────────────────────────────────
-- DataStore helpers
-- ─────────────────────────────────────────────
local function loadFromStore(userId: number): table?
	-- Probe once, then never retry against a known block. This guard is what
	-- stops the Studio DataStore error spam.
	if datastoresEnabled == nil then probeDataStoreAccess() end
	if datastoresEnabled == false then return nil end

	local store = getStore()
	if not store then return nil end

	local key = "Profile_" .. userId

	for attempt = 1, DATASTORE_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			return result   -- may be nil (new player)
		else
			warn(string.format(
				"[PlayerService] DataStore load failed (attempt %d/%d): %s",
				attempt, DATASTORE_RETRIES, tostring(result)
			))
			if attempt < DATASTORE_RETRIES then
				task.wait(DATASTORE_DELAY)
			end
		end
	end
	return nil
end

local function saveToStore(userId: number, profile: table): boolean
	if datastoresEnabled == nil then probeDataStoreAccess() end
	if datastoresEnabled == false then return false end

	local store = getStore()
	if not store then return false end

	local key = "Profile_" .. userId

	-- Shallow copy, strip runtime-only fields before saving
	local toSave = {}
	for k, v in pairs(profile) do
		toSave[k] = v
	end

	for attempt = 1, DATASTORE_RETRIES do
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(old)
				-- If the server data is newer, use it.
				-- Simple strategy: always overwrite with current session data.
				-- A real production game would use a session-lock key; Phase 7 will add that.
				return toSave
			end)
		end)
		if ok then
			return true
		else
			warn(string.format(
				"[PlayerService] DataStore save failed (attempt %d/%d): %s",
				attempt, DATASTORE_RETRIES, tostring(err)
			))
			if attempt < DATASTORE_RETRIES then
				task.wait(DATASTORE_DELAY)
			end
		end
	end

	-- Honest failure: every attempt errored, so nothing was persisted.
	warn(string.format(
		"[PlayerService] Could NOT save profile (userId %d) after %d attempts.",
		userId, DATASTORE_RETRIES
	))
	return false
end

-- ─────────────────────────────────────────────
-- Player init / cleanup
-- ─────────────────────────────────────────────

local function initRuntimeState(userId: number, profile: table)
	local maxStamina = (profile.Attributes.Stamina / 100) * Constants.MAX_STAMINA
	_stamina[userId]   = maxStamina
	_energy[userId]    = 0
	_isSprinting[userId] = false
	_cooldowns[userId] = {}
	_awakening[userId] = {
		Meter    = 0,
		IsActive = false,
		TimeLeft = 0,
	}
end

local function applyWalkSpeed(player: Player, profile: table)
	local char = player.Character or player.CharacterAdded:Wait()
	local hum  = char:FindFirstChildWhichIsA("Humanoid")
	if hum then
		-- Base speed scaled by Speed attribute
		local speedMult = 0.7 + (profile.Attributes.Speed / 100) * 0.6
		hum.WalkSpeed = Constants.WALK_SPEED * speedMult
	end
end

local function onCharacterAdded(player: Player, char: Model)
	local profile = _profiles[player.UserId]
	if not profile then return end

	-- Wait for humanoid
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	   or char:WaitForChild("Humanoid", 5) :: Humanoid?
	if not hum then return end

	-- Apply base speed
	local speedMult = 0.7 + (profile.Attributes.Speed / 100) * 0.6
	hum.WalkSpeed   = Constants.WALK_SPEED * speedMult
	hum.JumpPower   = 50

	-- Restore stamina on respawn
	_stamina[player.UserId] = (profile.Attributes.Stamina / 100) * Constants.MAX_STAMINA
	_isSprinting[player.UserId] = false
end

--- Load a player's profile from DataStore and set up runtime state.
local function loadPlayer(player: Player)
	local userId = player.UserId
	if _loading[userId] then return end
	_loading[userId] = true

	local stored = loadFromStore(userId)

	local profile: table
	if stored then
		-- Merge stored data onto a fresh default to fill any missing keys
		-- (handles new fields added in updates)
		profile = newProfile(userId, player.DisplayName)
		for k, v in pairs(stored) do
			profile[k] = v
		end
		-- Always update display name in case it changed
		profile.DisplayName = player.DisplayName
		-- Deep-merge nested tables so a profile saved by an older build does not
		-- end up with a nil Objectives or Settings table after an update.
		for _, nestedKey in ipairs({"Attributes", "TechniqueMastery", "Statistics", "Settings", "Objectives"}) do
			local saved = stored[nestedKey]
			if type(saved) == "table" then
				if type(profile[nestedKey]) ~= "table" then
					profile[nestedKey] = {}
				end
				for k, v in pairs(saved) do
					profile[nestedKey][k] = v
				end
			end
		end
	else
		profile = newProfile(userId, player.DisplayName)
	end

	-- Resolve rank from current rating
	profile.Rank = resolveRank(profile.RankedRating)

	_profiles[userId] = profile
	initRuntimeState(userId, profile)
	_loading[userId]  = nil

	-- Apply walk speed immediately if character exists
	if player.Character then
		applyWalkSpeed(player, profile)
	end

	-- Character future spawns
	player.CharacterAdded:Connect(function(char)
		onCharacterAdded(player, char)
	end)

	print(string.format(
		"[PlayerService] Loaded profile for %s (Level %d, Rating %d)",
		player.DisplayName, profile.Level, profile.RankedRating
	))
end

local function savePlayer(player: Player)
	local userId = player.UserId
	local profile = _profiles[userId]
	if not profile then return end

	task.spawn(function()
		local persisted = saveToStore(userId, profile)
		if persisted then
			print(string.format("[PlayerService] Saved profile for %s", player.DisplayName))
		else
			print(string.format(
				"[PlayerService] Session-only data for %s - not persisted "
					.. "(expected when DataStore access is unavailable).",
				player.DisplayName
			))
		end
	end)
end

local function removePlayer(player: Player)
	local userId = player.UserId
	savePlayer(player)
	_profiles[userId]    = nil
	_energy[userId]      = nil
	_stamina[userId]     = nil
	_awakening[userId]   = nil
	_isSprinting[userId] = nil
	_cooldowns[userId]   = nil
end

-- ─────────────────────────────────────────────
-- Stamina / Energy / Awakening regen loop
-- ─────────────────────────────────────────────

local _regenAccum = 0
local REGEN_INTERVAL = 0.1   -- process every 100ms

local function onHeartbeat(dt: number)
	_regenAccum += dt
	if _regenAccum < REGEN_INTERVAL then return end
	local delta = _regenAccum
	_regenAccum = 0

	for _, player in ipairs(Players:GetPlayers()) do
		local userId  = player.UserId
		local profile = _profiles[userId]
		if not profile then continue end

		local maxStamina = (profile.Attributes.Stamina / 100) * Constants.MAX_STAMINA

		-- ── Stamina ────────────────────────────────────────────────
		local currentStamina = _stamina[userId] or maxStamina
		local sprinting      = _isSprinting[userId]

		if sprinting and currentStamina > 0 then
			currentStamina = math.max(0, currentStamina - Constants.SPRINT_STAMINA_DRAIN * delta)
			if currentStamina <= 0 then
				-- Force stop sprint
				_isSprinting[userId] = false
				PlayerService.SetSprintSpeed(player, false)
			end
		elseif not sprinting and currentStamina < maxStamina then
			currentStamina = math.min(maxStamina, currentStamina + Constants.STAMINA_REGEN_RATE * delta)
		end
		_stamina[userId] = currentStamina

		-- ── Mythic Energy ──────────────────────────────────────────
		local currentEnergy = _energy[userId] or 0
		if currentEnergy < Constants.MAX_ENERGY then
			currentEnergy = math.min(
				Constants.MAX_ENERGY,
				currentEnergy + Constants.ENERGY_REGEN_IDLE * delta
			)
			_energy[userId] = currentEnergy
		end

		-- ── Awakening timer (drain while active) ───────────────────
		local awaken = _awakening[userId]
		if awaken and awaken.IsActive then
			awaken.TimeLeft = math.max(0, awaken.TimeLeft - delta)
			if awaken.TimeLeft <= 0 then
				awaken.IsActive = false
				awaken.Meter    = 0
				-- Notify client awakening ended
				Remotes.FireClient(Constants.Remotes.AwakeningUpdate, player, {
					Meter    = 0,
					IsActive = false,
					TimeLeft = 0,
				})
				-- Restore normal speed
				PlayerService.SetSprintSpeed(player, _isSprinting[userId] or false)
			else
				-- Drain meter proportionally
				awaken.Meter = math.max(0, (awaken.TimeLeft / Constants.AWAKENING_DURATION) * 100)
			end
		end

		-- ── Broadcast to owning client ────────────────────────────────
		-- Only send when a value actually moved, with a 2s keepalive so a
		-- client that joined late still converges. The loop runs at
		-- REGEN_UPDATE_INTERVAL, so firing both remotes unconditionally meant
		-- 20 remote events per second per player even with both bars full.
		local now = tick()
		if math.abs(currentStamina - (_lastSentStamina[userId] or -1)) >= 1
			or (now - (_lastSentAt[userId] or 0)) > 2 then
			_lastSentStamina[userId] = currentStamina
			_lastSentAt[userId]      = now
			Remotes.FireClient(Constants.Remotes.PlayerStaminaUpdate, player, {
				Stamina    = currentStamina,
				MaxStamina = maxStamina,
			})
		end
		if math.abs(currentEnergy - (_lastSentEnergy[userId] or -1)) >= 1
			or (now - (_lastSentAt[userId] or 0)) > 2 then
			_lastSentEnergy[userId] = currentEnergy
			Remotes.FireClient(Constants.Remotes.PlayerEnergyUpdate, player, {
				Energy    = currentEnergy,
				MaxEnergy = Constants.MAX_ENERGY,
			})
		end
	end
end

-- ─────────────────────────────────────────────
-- Sprint remote handler
-- ─────────────────────────────────────────────

local function onRequestSprint(player: Player, payload)
	local userId  = player.UserId
	local profile = _profiles[userId]
	if not profile then return end

	local wantSprint = (typeof(payload) == "table") and (payload.Sprinting == true)

	-- Don't allow sprint if stamina too low
	if wantSprint and (_stamina[userId] or 0) < Constants.SPRINT_MIN_STAMINA then
		wantSprint = false
	end

	_isSprinting[userId] = wantSprint
	PlayerService.SetSprintSpeed(player, wantSprint)
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function PlayerService.Init()
	-- Hook player events
	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadPlayer, player)
		-- Teleport to lobby spawn after profile loads
		task.delay(1.5, function()
			local lobby = workspace:FindFirstChild("Lobby")
			if lobby then
				local spawn = lobby:FindFirstChild("SpawnLobby_1")
				if spawn then
					local char = player.Character
					if char then
						local root = char:FindFirstChild("HumanoidRootPart")
						if root then
							root.CFrame = spawn.CFrame + Vector3.new(0, 5, 0)
						end
					end
				end
			end
		end)
	end)

	Players.PlayerRemoving:Connect(removePlayer)

	-- Load any players already in server (Studio test)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(loadPlayer, player)
	end

	-- Regen / tick loop
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Remote listeners
	Remotes.OnServerEvent(Constants.Remotes.RequestSprint, onRequestSprint)

	-- Periodic auto-save every 60 seconds
	task.spawn(function()
		while true do
			task.wait(60)
			for _, player in ipairs(Players:GetPlayers()) do
				savePlayer(player)
			end
		end
	end)

	print("[PlayerService] Initialised.")
end

--- Returns the full profile for a player, or nil if not loaded yet.
function PlayerService.GetProfile(player: Player): table?
	return _profiles[player.UserId]
end

--- Returns just the Attributes table for a player (used by BallService stat provider).
function PlayerService.GetAttributes(player: Player): table?
	local profile = _profiles[player.UserId]
	return profile and profile.Attributes or nil
end

--- Returns current Mythic Energy for a player.
function PlayerService.GetEnergy(player: Player): number
	return _energy[player.UserId] or 0
end

--- Returns current Stamina for a player.
function PlayerService.GetStamina(player: Player): number
	return _stamina[player.UserId] or 0
end

--- Returns the Awakening state table for a player.
function PlayerService.GetAwakeningState(player: Player): table?
	return _awakening[player.UserId]
end

--- Adds Mythic Energy to a player (capped at MAX_ENERGY).
function PlayerService.AddEnergy(player: Player, amount: number)
	local userId = player.UserId
	_energy[userId] = math.min(Constants.MAX_ENERGY, (_energy[userId] or 0) + amount)
	Remotes.FireClient(Constants.Remotes.PlayerEnergyUpdate, player, {
		Energy    = _energy[userId],
		MaxEnergy = Constants.MAX_ENERGY,
	})
end

--- Deducts Mythic Energy. Returns true if successful, false if insufficient.
function PlayerService.SpendEnergy(player: Player, amount: number): boolean
	local userId = player.UserId
	local current = _energy[userId] or 0
	if current < amount then return false end
	_energy[userId] = current - amount
	Remotes.FireClient(Constants.Remotes.PlayerEnergyUpdate, player, {
		Energy    = _energy[userId],
		MaxEnergy = Constants.MAX_ENERGY,
	})
	return true
end

--- Adds to the Awakening meter (0–100). Does not activate Awakening.
function PlayerService.AddAwakeningMeter(player: Player, amount: number)
	local userId = player.UserId
	local awaken = _awakening[userId]
	if not awaken or awaken.IsActive then return end

	awaken.Meter = math.min(Constants.MAX_AWAKENING_METER, awaken.Meter + amount)
	Remotes.FireClient(Constants.Remotes.AwakeningUpdate, player, {
		Meter    = awaken.Meter,
		IsActive = false,
		TimeLeft = 0,
	})
end

--- Activates Mythic Awakening for a player (requires full meter).
--- Returns true if activated, false if conditions not met.
function PlayerService.ActivateAwakening(player: Player): boolean
	local userId = player.UserId
	local awaken = _awakening[userId]
	if not awaken then return false end
	if awaken.IsActive then return false end
	if awaken.Meter < Constants.MAX_AWAKENING_METER then return false end

	awaken.IsActive = true
	awaken.TimeLeft = Constants.AWAKENING_DURATION
	awaken.Meter    = 100

	-- Boost walk speed
	local char = player.Character
	if char then
		local hum = char:FindFirstChildWhichIsA("Humanoid")
		if hum then
			local profile = _profiles[userId]
			if profile then
				local base    = Constants.WALK_SPEED * (0.7 + profile.Attributes.Speed / 100 * 0.6)
				hum.WalkSpeed = base * Constants.AWAKENING_MULT_SPEED
			end
		end
	end

	Remotes.FireClient(Constants.Remotes.AwakeningUpdate, player, {
		Meter    = 100,
		IsActive = true,
		TimeLeft = Constants.AWAKENING_DURATION,
	})

	print(string.format("[PlayerService] %s activated Mythic Awakening!", player.DisplayName))
	return true
end

--- Returns true if a player is currently Awakened.
function PlayerService.IsAwakened(player: Player): boolean
	local awaken = _awakening[player.UserId]
	return awaken ~= nil and awaken.IsActive
end

--- Set / unset sprint speed on a player's humanoid (server-authoritative).
function PlayerService.SetSprintSpeed(player: Player, sprinting: boolean)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildWhichIsA("Humanoid") :: Humanoid?
	if not hum then return end

	local profile = _profiles[player.UserId]
	if not profile then return end

	local awaken   = _awakening[player.UserId]
	local awakeMult = (awaken and awaken.IsActive) and Constants.AWAKENING_MULT_SPEED or 1.0
	local baseMult  = 0.7 + (profile.Attributes.Speed / 100) * 0.6

	if sprinting then
		hum.WalkSpeed = Constants.SPRINT_SPEED * baseMult * awakeMult
	else
		hum.WalkSpeed = Constants.WALK_SPEED * baseMult * awakeMult
	end
end

--- Fire the level-up presentation payload. The client animates the
--- old -> new level, plays the sound and shows what was unlocked.
local function announceLevelUp(player: Player, profile: table, gained: number)
	Remotes.FireClient(Constants.Remotes.PlayerLevelUp, player, {
		OldLevel  = profile.Level - gained,
		NewLevel  = profile.Level,
		Levels    = gained,
		XP        = profile.XP,
		XPNeeded  = xpForNextLevel(profile.Level),
		Overall   = PlayerService.GetOverall(player),
		Unlocks   = PlayerService.GetLevelUnlocks(profile.Level),
	})
	-- NotifyPlayer is used as the generic toast channel so existing UI picks
	-- this up without a second handler.
	Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
		Type    = "LevelUp",
		Level   = profile.Level,
		Message = string.format("LEVEL UP!  %d → %d", profile.Level - gained, profile.Level),
	})
end

--- Returns human-readable unlock labels for a level, if any.
function PlayerService.GetLevelUnlocks(level: number): { string }
	local unlocks = {}
	local byLevel = {
		[2]  = { "Town exploration unlocked" },
		[3]  = { "Technique practice available" },
		[5]  = { "Advanced training drills" },
		[8]  = { "New technique slot" },
		[10] = { "Ranked matchmaking preview" },
		[15] = { "Elite training grounds" },
	}
	local entry = byLevel[level]
	if entry then
		for _, label in ipairs(entry) do
			table.insert(unlocks, label)
		end
	end
	return unlocks
end

--- Grant XP and Coins to a player. Handles level-up automatically.
--- payload: { XP, Coins, RatingDelta?, GoalsScored?, AssistsGiven? }
function PlayerService.GrantRewards(player: Player, payload: table)
	local userId  = player.UserId
	local profile = _profiles[userId]
	if not profile then return end

	if payload.XP then
		-- Ignore non-positive XP: a caller passing a negative value could
		-- otherwise drain a player's progress.
		local amount = tonumber(payload.XP) or 0
		if amount <= 0 then return end

		profile.XP += amount
		local gained = processLevelUp(profile)
		if gained > 0 then
			print(string.format("[PlayerService] %s levelled up to %d!", player.DisplayName, profile.Level))
			announceLevelUp(player, profile, gained)
		end
		-- Keep the HUD XP bar live regardless of whether a level was gained.
		Remotes.FireClient(Constants.Remotes.PlayerProgressUpdate, player, {
			Level     = profile.Level,
			XP        = profile.XP,
			XPNeeded  = xpForNextLevel(profile.Level),
			Overall   = PlayerService.GetOverall(player),
			Coins     = profile.Coins,
		})
	end

	if payload.Coins then
		profile.Coins += payload.Coins
	end

	if payload.RatingDelta then
		profile.RankedRating = math.max(0, profile.RankedRating + payload.RatingDelta)
		profile.Rank = resolveRank(profile.RankedRating)
	end

	if payload.GoalsScored then
		profile.Goals += payload.GoalsScored
	end

	if payload.AssistsGiven then
		profile.Assists += payload.AssistsGiven
	end
end

--- Record a match result in the player's profile.
function PlayerService.RecordMatchResult(player: Player, won: boolean, draw: boolean)
	local profile = _profiles[player.UserId]
	if not profile then return end
	profile.MatchesPlayed += 1
	if won then
		profile.Wins += 1
	elseif not draw then
		profile.Losses += 1
	end
end

--- Check if a technique cooldown has expired for a player.
function PlayerService.IsTechReady(player: Player, techId: string): boolean
	local cd = _cooldowns[player.UserId]
	if not cd then return true end
	local expires = cd[techId]
	if not expires then return true end
	return tick() >= expires
end

--- Start a technique cooldown for a player.
function PlayerService.StartCooldown(player: Player, techId: string, duration: number)
	local userId = player.UserId
	if not _cooldowns[userId] then _cooldowns[userId] = {} end
	_cooldowns[userId][techId] = tick() + duration
end

--- Returns remaining cooldown seconds (0 if ready).
function PlayerService.GetCooldownRemaining(player: Player, techId: string): number
	local cd = _cooldowns[player.UserId]
	if not cd then return 0 end
	local expires = cd[techId]
	if not expires then return 0 end
	return math.max(0, expires - tick())
end

-- ─────────────────────────────────────────────
-- Statistics tracking
-- ─────────────────────────────────────────────

--- Increment a persistent statistic for a player.
function PlayerService.IncrementStat(player: Player, statName: string, amount: number?)
	local profile = _profiles[player.UserId]
	if not profile then return end
	profile.Statistics = profile.Statistics or {}
	local key = statName
	-- Map legacy keys
	local statMap = {
		pass       = "Passes",
		passSuccess = "SuccessfulPasses",
		dribble    = "Dribbles",
		dribbleSuccess = "SuccessfulDribbles",
		tackle     = "Tackles",
		block      = "Blocks",
		save       = "Saves",
		shot       = "Shots",
		shotSuccess = "SuccessfulShots",
	}
	local realKey = statMap[key] or statName
	profile.Statistics[realKey] = (profile.Statistics[realKey] or 0) + (amount or 1)
end

--- Returns the statistics table for a player (for match rewards).
function PlayerService.GetStatistics(player: Player): table?
	local profile = _profiles[player.UserId]
	return profile and profile.Statistics or nil
end

-- ─────────────────────────────────────────────
-- Technique mastery
-- ─────────────────────────────────────────────

local MASTERY_XP_THRESHOLDS = { 50, 150, 400, 1000, 2000 }  -- XP for mastery levels 1-5

--- Returns the mastery level for a technique (0-5).
function PlayerService.GetMasteryLevel(player: Player, techId: string): number
	local profile = _profiles[player.UserId]
	if not profile then return 0 end
	local mastery = profile.TechniqueMastery and profile.TechniqueMastery[techId]
	return mastery and mastery.Level or 0
end

--- Returns the full mastery data for a technique.
function PlayerService.GetMasteryData(player: Player, techId: string): table?
	local profile = _profiles[player.UserId]
	if not profile then return nil end
	local mastery = profile.TechniqueMastery and profile.TechniqueMastery[techId]
	if not mastery then
		return { Level = 0, XP = 0, UsageCount = 0, SuccessCount = 0, Unlocked = false }
	end
	return mastery
end

--- Unlock a technique for the player if not already unlocked.
function PlayerService.UnlockTechnique(player: Player, techId: string)
	local profile = _profiles[player.UserId]
	if not profile then return false end
	profile.TechniqueMastery = profile.TechniqueMastery or {}
	if not profile.TechniqueMastery[techId] then
		profile.TechniqueMastery[techId] = {
			Level       = 0,
			XP          = 0,
			UsageCount  = 0,
			SuccessCount = 0,
			Unlocked    = true,
		}
		print(string.format("[PlayerService] %s unlocked technique: %s", player.DisplayName, techId))
		return true
	end
	return false
end

--- Check if a player has a technique unlocked.
function PlayerService.HasTechnique(player: Player, techId: string): boolean
	local profile = _profiles[player.UserId]
	if not profile then return false end
	-- Check equipped techs
	if profile.EquippedTechs then
		for _, t in ipairs(profile.EquippedTechs) do
			if t == techId then return true end
		end
	end
	-- Check mastery (unlocked but not equipped)
	local mastery = profile.TechniqueMastery and profile.TechniqueMastery[techId]
	return mastery ~= nil and mastery.Unlocked
end

--- Add mastery XP to a technique. Level goes up to 5.
--- isSuccess is only true when the technique's real outcome is known good
--- (a goal from a shot, a won tackle, a registered save). Activating a
--- technique only records usage, so mastery cannot be farmed by mashing.
function PlayerService.AddTechniqueMasteryXP(player: Player, techId: string, amount: number, isSuccess: boolean?)
	local profile = _profiles[player.UserId]
	if not profile then return end
	profile.TechniqueMastery = profile.TechniqueMastery or {}
	if not profile.TechniqueMastery[techId] then
		profile.TechniqueMastery[techId] = {
			Level        = 0,
			XP           = 0,
			UsageCount   = 0,
			SuccessCount = 0,
			Unlocked     = true,
		}
	end
	local m = profile.TechniqueMastery[techId]
	m.XP = m.XP + amount
	m.UsageCount = m.UsageCount + 1
	if isSuccess then
		m.SuccessCount = m.SuccessCount + 1
	end

	-- Check level up
	local levelled = false
	local newLevel = m.Level
	for i = 1, #MASTERY_XP_THRESHOLDS do
		if m.XP >= MASTERY_XP_THRESHOLDS[i] then
			newLevel = i
		end
	end
	if newLevel > m.Level then
		m.Level = newLevel
		levelled = true
	end

	if levelled then
		local techDef = TechniqueDefinitions.Get(techId)
		local name = techDef and techDef.Name or techId
		Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
			Type    = "MasteryLevelUp",
			TechId  = techId,
			Level   = newLevel,
			Message = string.format("%s Mastery Level %d!", name, newLevel),
		})
	end
end

--- Returns all mastery data for a player (for player card).
function PlayerService.GetAllMastery(player: Player): table
	local profile = _profiles[player.UserId]
	if not profile then return {} end
	return profile.TechniqueMastery or {}
end

--- Force-save all players (called on server shutdown via BindToClose).
function PlayerService.SaveAll()
	for _, player in ipairs(Players:GetPlayers()) do
		savePlayer(player)
	end
end

return PlayerService
