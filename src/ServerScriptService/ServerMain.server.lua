--[[
	MythicStrikers — ServerMain
	The single server Script that boots every service in dependency order.

	EXECUTION ORDER:
	  1.  Remotes.Init()           — create all RemoteEvent/Function instances
	  2.  TeamService.Init()       — create Team objects
	  3.  PlayerService.Init()     — hook PlayerAdded / DataStore
	  4.  ShopService.Init()       — catalogue, purchase validation, daily bonus
	  5.  BallService.Init()       — find ball Part, register goal callback placeholder
	  6.  MatchService.Init()      — wire BallService + TeamService, set goal callback
	  7.  TechniqueService.Init()  — technique execution framework
	  8.  AntiExploitService.Init()— inject all service refs
	  9.  Cross-inject callbacks   — BallService stat provider, energy callback, action callback
	 10.  RemoteFunction bindings  — GetMatchData, GetPlayerProfile
	 11.  BindToClose              — safe DataStore flush on shutdown
	 12.  WaitForStadium+Lobby     — defer game systems until world is built
	 13.  Lobby ball setup         — create practice ball in lobby
	 14.  Match queue handling     — players join queue from lobby, match starts when ready

	Match flow (Update 1.0):
	  Player joins → spawns in lobby → explores → enters MatchPortal →
	  joins queue → when enough players, match starts → teleport to stadium →
	  countdown → match → result → teleport back to lobby.
--]]

-- ── Guard: server only ───────────────────────────────────────────────────────
local RunService = game:GetService("RunService")
assert(RunService:IsServer(), "ServerMain must run on the server.")

-- ── Services ─────────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared
local Constants  = require(ReplicatedStorage.Shared.Config.Constants)
local Palette    = require(ReplicatedStorage.Shared.Config.Palette)
local Remotes    = require(ReplicatedStorage.Remotes)

-- Server services
local ServerScriptService = game:GetService("ServerScriptService")
local ServicesFolder      = ServerScriptService:WaitForChild("Services", 10)

local TeamService        = require(ServicesFolder:WaitForChild("TeamService"))
local PlayerService      = require(ServicesFolder:WaitForChild("PlayerService"))
local ShopService        = require(ServicesFolder:WaitForChild("ShopService"))
local BallService        = require(ServicesFolder:WaitForChild("BallService"))
local MatchService       = require(ServicesFolder:WaitForChild("MatchService"))
local TechniqueService   = require(ServicesFolder:WaitForChild("TechniqueService"))
local AntiExploitService = require(ServicesFolder:WaitForChild("AntiExploitService"))
local ObjectiveService   = require(ServicesFolder:WaitForChild("ObjectiveService"))
local TrainingBuilder    = require(ServicesFolder:WaitForChild("TrainingBuilder"))

-- World layer. LightingService and NPCService live in the World folder, not
-- Services, because they are presentation, not game systems.
local WorldFolder        = ServerScriptService:WaitForChild("World", 10)
local LightingService    = require(WorldFolder:WaitForChild("LightingService"))
local NPCService         = require(WorldFolder:WaitForChild("NPCService"))

-- Rate-limit bookkeeping for the queue-join remote
local _lastQueueJoin: { [number]: number } = {}

-- ─────────────────────────────────────────────
-- Step 0 — Guarantee a spawn point exists
-- ─────────────────────────────────────────────
-- The lobby/stadium SpawnLocations are created by LobbyBuilder and
-- StadiumBuilder, which are sibling Scripts — their execution order relative
-- to the first player joining is not guaranteed. If Roblox attempts a spawn
-- while Workspace has zero SpawnLocations, the character never spawns and the
-- client sits on the loading screen forever.
--
-- Create one synchronously, before anything can yield, so there is always a
-- valid spawn. It is named SpawnLobby_0 so it joins the same family as the
-- lobby ring and is reused by MatchService.getLobbySpawnPositions().
if not workspace:FindFirstChild("SpawnLobby_0", true) then
	local bootstrapSpawn = Instance.new("SpawnLocation")
	bootstrapSpawn.Name          = "SpawnLobby_0"
	bootstrapSpawn.Size          = Vector3.new(6, 1, 6)
	bootstrapSpawn.CFrame        = CFrame.new(
		Constants.TOWN_ORIGIN + Vector3.new(0, 1.2, 0)
	)
	bootstrapSpawn.Anchored     = true
	bootstrapSpawn.CanCollide   = true
	bootstrapSpawn.CanTouch     = true
	bootstrapSpawn.Neutral      = true
	bootstrapSpawn.Enabled      = true
	bootstrapSpawn.Duration     = 0
	bootstrapSpawn.Color        = Color3.fromRGB(90, 96, 104)
	bootstrapSpawn.Material     = Enum.Material.SmoothPlastic
	bootstrapSpawn.Transparency = 0.5
	bootstrapSpawn.Parent       = workspace
	print("[ServerMain] Bootstrap SpawnLocation created (SpawnLobby_0).")
end

-- ─────────────────────────────────────────────
-- Configuration
-- ─────────────────────────────────────────────
local DEFAULT_MATCH_MODE    = "5v5"
local MIN_PLAYERS_TO_START  = 2     -- minimum players to start a 5v5 match

-- Graphics tier. TODO(launch): read the player's saved preference from their
-- profile once Settings ships. Until then this is the server default, and the
-- client can request a lower tier at any time via LightingService.SetQuality.
local QUALITY_TIER = "HIGH"

-- ── Enforce max server size (Studio: set MaxPlayers in Players service) ──────
-- We can't set MaxPlayers from a script, but we can kick excess players.
local function enforceMaxPlayers()
	local max = Constants.MAX_SERVER_SIZE   -- 40
	Players.PlayerAdded:Connect(function(player)
		if #Players:GetPlayers() > max then
			player:Kick("Server is full (max " .. max .. " players).")
		end
	end)
end
enforceMaxPlayers()

-- ─────────────────────────────────────────────
-- Step 1 — Remotes
-- ─────────────────────────────────────────────
Remotes.Init()
print("[ServerMain] Remotes ready.")

-- ─────────────────────────────────────────────
-- Step 1b — Lighting
--
-- Must run before any world builder, because the builders read nothing from
-- Lighting but WeatherService and the old StadiumBuilder both used to write
-- to it. LightingService is now the only writer.
-- ─────────────────────────────────────────────
LightingService.Init(QUALITY_TIER)
print("[ServerMain] LightingService ready.")

-- ─────────────────────────────────────────────
-- Step 2 — TeamService
-- ─────────────────────────────────────────────
TeamService.Init()
print("[ServerMain] TeamService ready.")

-- ─────────────────────────────────────────────
-- Step 3 — PlayerService
-- ─────────────────────────────────────────────
PlayerService.Init()
print("[ServerMain] PlayerService ready.")

-- ─────────────────────────────────────────────
-- Step 4 — ShopService
-- ─────────────────────────────────────────────
ShopService.Init(PlayerService)
print("[ServerMain] ShopService ready.")

-- ─────────────────────────────────────────────
-- Step 4a — ObjectiveService
-- ─────────────────────────────────────────────
-- Needs PlayerService, so it initialises after the profile system.
ObjectiveService.Init(PlayerService)
print("[ServerMain] ObjectiveService ready.")

-- ─────────────────────────────────────────────
-- Step 4b — RemoteFunction bindings
-- ─────────────────────────────────────────────
-- Bound HERE, before the stadium wait below, so a client can never invoke an
-- unbound function. Both handlers only read module state that is valid before
-- MatchService.Init() runs:
--   • MatchService.GetMatchData() returns the "Waiting" default snapshot
--   • PlayerService.GetProfile() returns nil until the DataStore load lands
-- Both are safe to call at any point during boot.

-- Clients can query current match state
Remotes.BindFunction("GetMatchData", function(player: Player)
	return MatchService.GetMatchData()
end)

-- Clients can query the technique library, including which entries are still
-- undiscovered so the UI can render them as "???" instead of naming them.
Remotes.BindFunction("GetTechniques", function(player: Player)
	return TechniqueService.GetTechniqueListFor(player)
end)

-- Leaderboard. This RemoteFunction was declared in Constants and created by
-- Remotes.Init(), but nothing ever bound it, so every leaderboard call would
-- have returned nil. It now returns live server standings, which is honest:
-- a global, DataStore-backed ranking needs published API access and is a
-- later step, so the UI is told that rather than being fed a fake ranking.
Remotes.BindFunction("GetLeaderboard", function(player: Player)
	local entries = {}
	for _, other in ipairs(Players:GetPlayers()) do
		local profile = PlayerService.GetProfile(other)
		if profile then
			table.insert(entries, {
				UserId      = other.UserId,
				DisplayName = profile.DisplayName,
				Level       = profile.Level,
				Rank        = profile.Rank,
				Rating      = profile.RankedRating,
				Overall     = PlayerService.GetOverall(other),
			})
		end
	end
	table.sort(entries, function(a, b)
		if a.Rating ~= b.Rating then return a.Rating > b.Rating end
		return a.DisplayName < b.DisplayName
	end)
	return {
		Scope      = "Server",
		Persistent = false,
		Entries    = entries,
	}
end)

-- Clients can query their own profile (read-only snapshot)
Remotes.BindFunction("GetPlayerProfile", function(player: Player)
	local profile = PlayerService.GetProfile(player)
	if not profile then return nil end
	-- Return safe read-only copy — strip internal fields if any
	local mastery = {}
	for techId, m in pairs(profile.TechniqueMastery or {}) do
		mastery[techId] = {
			Level        = m.Level,
			XP           = m.XP,
			UsageCount   = m.UsageCount,
			SuccessCount = m.SuccessCount,
			Unlocked     = m.Unlocked,
		}
	end
	return {
		SchemaVersion    = profile.SchemaVersion,
		DisplayName      = profile.DisplayName,
		Level            = profile.Level,
		XP               = profile.XP,
		XPNeeded         = PlayerService.GetXPForNextLevel(player),
		Overall          = PlayerService.GetOverall(player),
		Coins            = profile.Coins,
		Rank             = profile.Rank,
		Position         = profile.Position,
		Goals            = profile.Goals,
		Assists          = profile.Assists,
		Saves            = profile.Saves,
		Tackles          = profile.Tackles,
		MatchesPlayed    = profile.MatchesPlayed,
		Wins             = profile.Wins,
		Losses           = profile.Losses,
		RankedRating     = profile.RankedRating,
		EquippedTechs    = profile.EquippedTechs,
		Attributes       = profile.Attributes,
		Statistics       = profile.Statistics,
		TechniqueMastery = mastery,
	}
end)
print("[ServerMain] RemoteFunction bindings ready.")

-- ─────────────────────────────────────────────
-- Step 5 — Wait for stadium, then BallService
-- ─────────────────────────────────────────────

-- The stadium model is expected at Workspace.Stadium.
-- If it's a streamed or deferred model it may not be present immediately.
local function waitForStadium(timeout: number): Model?
	local start = tick()
	while tick() - start < timeout do
		local stadium = workspace:FindFirstChild("Stadium")
		if stadium then return stadium :: Model end
		task.wait(0.5)
	end
	return nil
end

local function findBall(): BasePart?
	-- Expected location: Workspace.Stadium.Ball  OR  Workspace.Ball
	local stadium = workspace:FindFirstChild("Stadium")
	if stadium then
		local b = stadium:FindFirstChild("Ball", true)
		if b and b:IsA("BasePart") then return b :: BasePart end
	end
	local topLevel = workspace:FindFirstChild("Ball")
	if topLevel and topLevel:IsA("BasePart") then return topLevel :: BasePart end
	return nil
end

-- ─────────────────────────────────────────────
-- Step 5 — MatchService
-- ─────────────────────────────────────────────
-- BallService.Init() needs the ball Part and a goal callback.
-- MatchService.Init() injects itself as the goal callback.
-- We defer both until the stadium exists.

local function bootGameSystems()
	print("[ServerMain] Booting game systems...")

	-- Locate ball
	local ball = findBall()
	if not ball then
		warn("[ServerMain] Ball Part not found in Workspace. "
			.. "Create a Part named 'Ball' under Workspace.Stadium.")
		-- Create a placeholder ball so the server doesn't crash
		ball = Instance.new("Part")
		ball.Name    = "Ball"
		ball.Shape   = Enum.PartType.Ball
		ball.Size    = Vector3.new(2.4, 2.4, 2.4)
		ball.BrickColor = BrickColor.new("White")
		ball.Material   = Enum.Material.SmoothPlastic
		ball.CFrame     = CFrame.new(0, 5, 0)
		ball.Parent     = workspace
		print("[ServerMain] Placeholder Ball created at origin.")
	end

	-- BallService
	BallService.Init(ball, nil)   -- goal callback set by MatchService below
	print("[ServerMain] BallService ready.")

	-- MatchService
	MatchService.Init(BallService, TeamService)
	MatchService.SetPlayerService(PlayerService)
	MatchService.SetObjectiveService(ObjectiveService)
	print("[ServerMain] MatchService ready.")

	-- TechniqueService
	TechniqueService.Init(BallService, PlayerService, AntiExploitService, MatchService)
	print("[ServerMain] TechniqueService ready.")

	-- ─────────────────────────────────────────
	-- Step 6 — AntiExploitService
	-- ─────────────────────────────────────────
	AntiExploitService.Init({
		PlayerService = PlayerService,
		BallService   = BallService,
		MatchService  = MatchService,
		TeamService   = TeamService,
	})
	print("[ServerMain] AntiExploitService ready.")

	-- ─────────────────────────────────────────
	-- Step 8 — Training grounds
	-- ─────────────────────────────────────────
	-- Needs BallService (drill balls), TechniqueService (training mode) and
	-- ObjectiveService (training objectives), so it runs after Step 7.
	TrainingBuilder.Init(PlayerService, TechniqueService, ObjectiveService, BallService)
	print("[ServerMain] Training grounds ready.")

	-- ─────────────────────────────────────────
	-- Step 9 — Cross-inject callbacks
	-- ─────────────────────────────────────────

	-- BallService needs TeamService for goalkeeper save detection and for the
	-- own-team tackle check. This was never injected, so TeamService was
	-- permanently nil inside BallService: saves never fired and team-mates
	-- could tackle each other.
	BallService.SetTeamService(TeamService)

	-- BallService needs AntiExploitService so pass / shoot / tackle requests
	-- are actually validated. Without this the entire AntiExploitService is
	-- dead code and any client can spoof ball actions.
	BallService.SetAntiExploitService(AntiExploitService)

	-- BallService needs player stats for shot/pass power calculations
	BallService.SetStatProvider(function(player: Player)
		return PlayerService.GetAttributes(player)
	end)

	-- BallService needs to award energy on ball events
	BallService.SetEnergyCallback(function(player: Player, amount: number)
		PlayerService.AddEnergy(player, amount)
		-- Also add awakening meter for ball events
		local awakeningGain = math.floor(amount * 0.5)
		if awakeningGain > 0 then
			PlayerService.AddAwakeningMeter(player, awakeningGain)
		end
	end)

	-- BallService action callback — track match statistics
	BallService.SetActionCallback(function(action: string, player: Player, targetPlayer: Player?)
		if action == "pass" then
			PlayerService.IncrementStat(player, "pass")
			PlayerService.IncrementStat(player, "passSuccess")
			MatchService.RecordPlayerStat(player.UserId, "passesSuccess", 1)
			PlayerService.AddTechniqueMasteryXP(player, "STARLINE_PASS", 10, false)
			ObjectiveService.Report(player, "Pass", 1)
			ObjectiveService.Report(player, "MatchPass", 1)
			if targetPlayer then
				PlayerService.IncrementStat(targetPlayer, "pass")
				MatchService.RecordPass(player.UserId, targetPlayer.UserId)
			end
		elseif action == "shot" then
			PlayerService.IncrementStat(player, "shot")
			MatchService.RecordPlayerStat(player.UserId, "shots", 1)
			PlayerService.AddTechniqueMasteryXP(player, "SOLAR_ROAR", 5, false)
		elseif action == "shotOnTarget" then
			-- Credited by BallService when a shot reaches the goal volume.
			PlayerService.IncrementStat(player, "shotSuccess")
			MatchService.RecordPlayerStat(player.UserId, "shotsSuccess", 1)
			-- A shot on target is a real success: this is the mastery XP that
			-- cannot be farmed by simply activating the technique.
			PlayerService.AddTechniqueMasteryXP(player, "SOLAR_ROAR", 25, true)
			PlayerService.AddTechniqueMasteryXP(player, "THUNDER_FANG", 25, true)
		elseif action == "tackle" then
			PlayerService.IncrementStat(player, "tackle")
			PlayerService.IncrementStat(player, "tackleSuccess")
			MatchService.RecordPlayerStat(player.UserId, "tacklesSuccess", 1)
			PlayerService.AddTechniqueMasteryXP(player, "THUNDER_FANG", 8, false)
			-- A won challenge is a genuine defensive success.
			PlayerService.AddTechniqueMasteryXP(player, "TITAN_RAMPART", 15, true)
			ObjectiveService.Report(player, "Tackle", 1)
			ObjectiveService.Report(player, "MatchTackle", 1)
			ObjectiveService.Report(player, "MatchBlock", 1)
			if targetPlayer then
				PlayerService.IncrementStat(targetPlayer, "dribble")
				ObjectiveService.Report(targetPlayer, "Dribble", 1)
			end
		end
	end)

	-- Track saves (when goalkeeper makes a save)
	BallService.SetSaveCallback(function(keeper: Player, shooter: Player?)
		PlayerService.IncrementStat(keeper, "save")
		PlayerService.IncrementStat(keeper, "saveSuccess")
		MatchService.RecordPlayerStat(keeper.UserId, "savesSuccess", 1)
		PlayerService.AddTechniqueMasteryXP(keeper, "ASTRAL_SHIELD", 12, false)
		-- A registered save is the real success for a goalkeeper technique.
		PlayerService.AddTechniqueMasteryXP(keeper, "ASTRAL_SHIELD", 20, true)
		Remotes.FireClient(Constants.Remotes.NotifyPlayer, keeper, {
			Type     = "Save",
			KeeperId = keeper.UserId,
			ShooterId = shooter and shooter.UserId or nil,
		})
		-- Award energy for save
		PlayerService.AddEnergy(keeper, Constants.ENERGY_GAIN_SAVE)
		PlayerService.AddAwakeningMeter(keeper, Constants.AWAKEN_GAIN_SAVE)
		ObjectiveService.Report(keeper, "Save", 1)
		ObjectiveService.Report(keeper, "MatchSave", 1)
	end)

	print("[ServerMain] Cross-service callbacks wired.")

	-- ─────────────────────────────────────────
	-- Step 8 — RemoteFunctions
	-- ─────────────────────────────────────────
	-- Already bound in Step 4b, before the stadium wait, so that clients never
	-- invoke an unbound function during the ~20 s the stadium takes to build.

	-- Refresh spawn points now that stadium is loaded
	TeamService.RefreshSpawnPoints()

	-- Create lobby ball for town practice
	createLobbyBall()

	print("[ServerMain] All systems online. Players spawn in lobby.")
end

-- ─────────────────────────────────────────────
-- Lobby ball creation
-- ─────────────────────────────────────────────

function createLobbyBall()
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then
		warn("[ServerMain] Lobby not found — cannot create practice ball.")
		return
	end

	-- Check if ball already exists
	if lobby:FindFirstChild("LobbyBall") then return end

	local template = ServerStorage.WorldAssets.Balls.TexturedSoccerBall
	if not template then
		warn("[ServerMain] TexturedSoccerBall not found in ServerStorage.WorldAssets.Balls")
		return
	end

	local ball = template:Clone()
	ball.Name = "LobbyBall"
	local meshPart = ball:FindFirstChild("Model"):FindFirstChild("MeshPart")
	if meshPart then
		ball.PrimaryPart = meshPart
		ball:PivotTo(CFrame.new(Constants.TOWN_ORIGIN + Vector3.new(0, 3, 0)))
	else
		ball.Position = Constants.TOWN_ORIGIN + Vector3.new(0, 3, 0)
	end
	ball.Parent = workspace

	-- Register with BallService for lobby mode
	BallService.SetLobbyBall(ball)
	BallService.SetLobbyMode(true)
	print("[ServerMain] Lobby practice ball created.")
end

-- ─────────────────────────────────────────────
-- Step 9 — BindToClose (safe DataStore flush)
-- ─────────────────────────────────────────────
game:BindToClose(function()
	print("[ServerMain] Server shutting down — saving all player data...")
	PlayerService.SaveAll()
	-- Give DataStore calls time to complete before process exits
	task.wait(3)
	print("[ServerMain] Save complete.")
end)

-- ─────────────────────────────────────────────
-- Step 10 — Wait for stadium then boot
-- ─────────────────────────────────────────────
task.spawn(function()
	-- ── Remove the editor baseplate ────────────────────────────────────
	-- A place created from the Baseplate template keeps a 2048x16x2048 grey
	-- Plastic slab in Workspace. default.project.json declares Workspace as a
	-- bare container, so Rojo removes it on a clean sync — but until that
	-- happens the slab shows through under the town and the training grounds
	-- and reads as unfinished ground. Removing it at boot makes the world look
	-- right whether or not Rojo is currently connected.
	task.wait(1)
	local removed = 0
	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "Baseplate" then
			child:Destroy()
			removed += 1
		end
	end
	if removed > 0 then
		print(string.format("[ServerMain] Removed %d editor baseplate(s).", removed))
	end

	-- Wait for the three world models. Each builder parents its model
	-- immediately and fills it, so existence is not enough — wait for the
	-- Ready attribute, or services will bind to a half-built stadium.
	local function waitForModel(name: string, timeout: number): Model?
		local start = tick()
		local deadline = start + timeout
		while tick() < deadline do
			local m = workspace:FindFirstChild(name)
			if m then
				while tick() < deadline and m:GetAttribute("Ready") ~= true do
					task.wait(0.2)
				end
				if m:GetAttribute("Ready") == true then
					return m :: Model
				end
				warn(string.format("[ServerMain] %s never reported Ready.", name))
				return m :: Model
			end
			task.wait(0.5)
		end
		warn(string.format("[ServerMain] Workspace.%s not found after %ds.", name, timeout))
		return nil
	end

	local stadium = waitForModel("Stadium", 60)
	if stadium then
		print("[ServerMain] Stadium ready.")
	end

	local lobby = waitForModel("Lobby", 60)
	if lobby then
		print("[ServerMain] Town centre ready.")
	end

	local world = waitForModel("World", 60)
	if world then
		print("[ServerMain] Town ready.")
	end

	-- Town population, once there is a town to populate.
	if lobby then
		local okNpc, errNpc = pcall(function()
			NPCService.Init(QUALITY_TIER)
		end)
		if not okNpc then
			warn("[ServerMain] NPCService failed to initialise: " .. tostring(errNpc))
		end
	end

	bootGameSystems()

	-- ─────────────────────────────────────────
	-- Step 11 — Match queue handling
	-- ─────────────────────────────────────────
	-- Players join the match queue from the lobby via MatchPortal.
	-- ServerMain listens for PlayerInput "JoinQueue" requests.
	Remotes.OnServerEvent(Constants.Remotes.PlayerInput, function(player: Player, payload)
		if typeof(payload) ~= "table" then return end

		if payload.Action == "JoinQueue" then
			-- Rate limit queue joins. Without this a client can occupy a
			-- scheduler thread for 2 s per fire by spamming this remote.
			local now = tick()
			if (now - (_lastQueueJoin[player.UserId] or 0)) < 5 then return end
			_lastQueueJoin[player.UserId] = now

			if MatchService.QueueJoin(player) then
				-- Try to start match after a brief delay for more players
				task.wait(2)
				if MatchService.CanStartMatch() then
					MatchService.StartMatchFromQueue()
				end
			end

		elseif payload.Action == "ChargeStart" then
			-- Client is holding the shoot button. The server owns the charge
			-- timer; the client's own ChargeTime value is never trusted.
			BallService.BeginCharge(player)

		elseif payload.Action == "ChargeEnd" then
			BallService.CancelCharge()
		end
	end)

	-- ─────────────────────────────────────────
	-- Step 12 — Mythic Awakening
	-- ─────────────────────────────────────────
	-- FootballController fires RequestAwakening but nothing listened for it, so
	-- awakening could never be activated by a player.
	Remotes.OnServerEvent(Constants.Remotes.RequestAwakening, function(player: Player)
		if AntiExploitService then
			local check = AntiExploitService.ValidateAwakening(player)
			if not check.ok then return end
		end
		if PlayerService.ActivateAwakening(player) then
			Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
				Type    = "Awakening",
				Message = "MYTHIC AWAKENING!",
			})
		else
			Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
				Type    = "AwakeningDenied",
				Message = "Your Mythic Energy isn't full yet.",
			})
		end
	end)

	-- Periodic check for match start
	task.spawn(function()
		while true do
			task.wait(3)
			if MatchService.GetState() == "Waiting" and MatchService.CanStartMatch() then
				MatchService.StartMatchFromQueue()
			end
		end
	end)

	print("[ServerMain] Waiting for players to join the match queue...")
end)

print("[ServerMain] Boot sequence initiated.")
