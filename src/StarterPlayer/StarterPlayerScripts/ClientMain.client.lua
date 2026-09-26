--[[
	MythicStrikers — ClientMain
	The single LocalScript that boots all client controllers.

	EXECUTION ORDER:
	  1. Wait for RemoteEvents folder (server must be ready)
	  2. InputController.Init()
	  3. CameraController.Init()
	  4. UIController.Init()
	  5. FootballController.Init()      ← depends on Input + Camera + UI
	  6. ShopUI.Init()                  ← shop / lobby screen builder
	  7. LobbyController.Init()         ← proximity prompts, NPC interaction
	  8. Load equipped techniques from server profile
	  9. Request initial match state

	NOTES:
	  This is a LocalScript under StarterPlayerScripts.
	  It runs once per client session (persists across respawns).
	  All game logic is server-authoritative; this is presentation + input only.
--]]

-- ── Guard: client only ───────────────────────────────────────────────────────
local RunService = game:GetService("RunService")
assert(RunService:IsClient(), "ClientMain must run on the client.")

-- ── Services ─────────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- ── Shared ───────────────────────────────────────────────────────────────────
local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes   = require(ReplicatedStorage.Remotes)

-- ── Controllers (resolve from StarterPlayerScripts sibling folder) ───────────
local ControllersFolder = script.Parent:WaitForChild("Controllers", 10)
assert(ControllersFolder, "[ClientMain] Controllers folder not found.")

local InputController    = require(ControllersFolder:WaitForChild("InputController"))
local CameraController   = require(ControllersFolder:WaitForChild("CameraController"))
local UIController       = require(ControllersFolder:WaitForChild("UIController"))
local FootballController = require(ControllersFolder:WaitForChild("FootballController"))
local LobbyController    = require(ControllersFolder:WaitForChild("LobbyController"))

-- ── StarterGui UI modules ─────────────────────────────────────────────────────
-- ShopUI is a ModuleScript under StarterGui/UI.
-- In Studio it is accessible directly from StarterGui (not cloned to PlayerGui).
local ShopUI = require(
	game:GetService("StarterGui")
		:WaitForChild("UI", 10)
		:WaitForChild("ShopUI", 10)
)

-- ─────────────────────────────────────────────
-- Loading screen
-- ─────────────────────────────────────────────
local function showLoadingScreen()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "LoadingScreen"
	screen.ResetOnSpawn = false
	screen.Parent = playerGui

	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(10, 10, 26)
	bg.BorderSizePixel = 0
	bg.Parent = screen

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "MYTHIC STRIKERS"
	label.TextSize = 60
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = Color3.fromRGB(255, 215, 0)
	label.TextStrokeTransparency = 0.7
	label.Parent = screen

	local sub = Instance.new("TextLabel")
	sub.Size = UDim2.new(1, 0, 0, 30)
	sub.Position = UDim2.new(0, 0, 1, -50)
	sub.BackgroundTransparency = 1
	sub.Text = "Loading..."
	sub.TextSize = 16
	sub.Font = Enum.Font.Gotham
	sub.TextColor3 = Color3.fromRGB(200, 200, 220)
	sub.Parent = screen

	return screen
end

local function hideLoadingScreen(screen)
	if screen and screen.Parent then
		screen:Destroy()
	end
end

local _loadingScreen = showLoadingScreen()

-- Store last profile for lobby display
local _lastProfile = {}

-- ─────────────────────────────────────────────
-- Step 1 — Wait for server remotes
-- ─────────────────────────────────────────────
-- Remotes.Get() already has internal WaitForChild logic,
-- but we do an explicit wait here to make boot sequencing clear.
local function waitForServer(timeout: number): boolean
	local start = tick()
	while tick() - start < timeout do
		local folder = ReplicatedStorage:FindFirstChild("RemoteEvents")
		if folder then return true end
		task.wait(0.2)
	end
	return false
end

local serverReady = waitForServer(15)
if not serverReady then
	warn("[ClientMain] Server remotes did not appear within 15 seconds. Proceeding anyway.")
end

print("[ClientMain] Server remotes available. Booting controllers...")

-- ─────────────────────────────────────────────
-- Step 2 — InputController
-- ─────────────────────────────────────────────
-- Each controller is initialised defensively. Previously a single throw in one
-- of them aborted the whole boot, so a failure in, say, buildHUD() silently
-- removed the entire HUD with no visible error beyond one red line.
local function bootController(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn(string.format("[ClientMain] %s failed to initialise: %s", name, tostring(err)))
	end
	return ok
end

bootController("InputController",  function() InputController.Init() end)

-- ─────────────────────────────────────────────
-- Step 3 — CameraController
-- ─────────────────────────────────────────────
bootController("CameraController", function() CameraController.Init() end)

-- ─────────────────────────────────────────────
-- Step 4 — UIController
-- Must come before FootballController so the UI reference is ready.
-- ─────────────────────────────────────────────
bootController("UIController",     function() UIController.Init(InputController, nil) end)

-- ─────────────────────────────────────────────
-- Step 5 — FootballController
-- ─────────────────────────────────────────────
bootController("FootballController", function()
	FootballController.Init(InputController, CameraController, UIController)
end)

-- Back-inject FootballController into UIController now it exists
-- (UIController uses it for charge ratio display)
UIController._footballController = FootballController  -- direct field injection

-- ─────────────────────────────────────────────
-- Step 6 — ShopUI
-- Builds the ScreenGui for shop / lobby screens programmatically.
-- ─────────────────────────────────────────────
bootController("ShopUI",          function() ShopUI.Init() end)

-- ─────────────────────────────────────────────
-- Step 7 — LobbyController
-- Scans Workspace.Lobby for interactive objects, wires ProximityPrompts,
-- routes interactions to ShopUI. Runs after ShopUI so screens are ready.
-- ─────────────────────────────────────────────
bootController("LobbyController",  function() LobbyController.Init(ShopUI, UIController) end)

-- Disable lobby prompts if we join mid-match
Remotes.OnClientEvent(Constants.Remotes.MatchStateUpdate, function(payload)
	if typeof(payload) ~= "table" then return end
	local inMatch = (payload.State == "Active" or payload.State == "Countdown"
		or payload.State == "HalfTime")
	LobbyController.SetLobbyActive(not inMatch)
	-- Show/hide player card based on lobby vs match
	if inMatch then
		UIController.HidePlayerCard()
		UIController.HideObjectives()
	elseif payload.State == "Waiting" or payload.State == "Ended" then
		-- In lobby, show the player card. Objectives are NOT faked here — the
		-- server pushes the real daily / match set through ObjectiveUpdate.
		UIController.ShowPlayerCard(_lastProfile or {})
	end
end)
-- ─────────────────────────────────────────────
-- Step 8 — Load player profile from server
-- ─────────────────────────────────────────────
task.spawn(function()
	-- Dismiss the loading screen on a hard deadline, independent of everything
	-- below. The character wait and the DataStore-backed remote call can each
	-- stall; neither may keep the overlay on screen for the whole session.
	local dismissed = false
	local function dismiss()
		if dismissed then return end
		dismissed = true
		hideLoadingScreen(_loadingScreen)
	end
	task.spawn(function()
		task.wait(12)
		if not dismissed then
			warn("[ClientMain] Loading deadline reached — forcing dismiss.")
		end
		dismiss()
	end)

	-- Wait for character to be present before querying.
	-- Bounded: if no character ever spawns we continue with a null profile
	-- rather than blocking the session behind the overlay.
	if not LocalPlayer.Character then
		local spawnDeadline = tick() + 10
		while not LocalPlayer.Character and tick() < spawnDeadline do
			task.wait(0.25)
		end
		if not LocalPlayer.Character then
			warn("[ClientMain] No character after 10s — continuing without profile.")
		end
	end
	task.wait(1)   -- give PlayerService time to load profile

	-- Fetch profile via RemoteFunction
	local ok, profile = pcall(function()
		return Remotes.InvokeServer("GetPlayerProfile")
	end)

	if ok and profile then
		-- Apply equipped techniques to Football and UI controllers
		local techs = profile.EquippedTechs or {}
		FootballController.SetEquippedTechniques(techs)

		-- Update technique slot labels in HUD
		local TechDefs = require(ReplicatedStorage.Shared.Techniques.TechniqueDefinitions)
		for i, techId in ipairs(techs) do
			if i > 4 then break end
			local def = TechDefs.Get(techId)
			if def then
				UIController.SetTechSlotName(i, def.Name)
			end
		end

		-- Show player card in lobby
		UIController.ShowPlayerCard(profile)
		FootballController.SetPlayerStats(profile.Attributes or {})

		_lastProfile = profile

		print(string.format(
			"[ClientMain] Profile loaded — Level %d | Rank %s | %d techs equipped",
			profile.Level or 1,
			profile.Rank or "Rookie",
			#techs
		))
	else
		warn("[ClientMain] Failed to load profile: " .. tostring(profile))
	end

	-- Hide loading screen once everything is loaded
	dismiss()
end)

-- ─────────────────────────────────────────────
-- Step 9 — Request initial match state
-- ─────────────────────────────────────────────
task.spawn(function()
	task.wait(1.5)
	local ok, matchData = pcall(function()
		return Remotes.InvokeServer("GetMatchData")
	end)
	if ok and matchData then
		-- Synthesize a MatchStateUpdate so UIController sets itself up
		Remotes.Get(Constants.Remotes.MatchStateUpdate).OnClientEvent:Fire(matchData)
		print(string.format(
			"[ClientMain] Initial match state: %s  Score: %d–%d",
			matchData.State or "?",
			matchData.ScoreA or 0,
			matchData.ScoreB or 0
		))
	end
end)

-- ─────────────────────────────────────────────
-- Respawn handling
-- ─────────────────────────────────────────────
-- Camera and movement state reset when character respawns.
LocalPlayer.CharacterAdded:Connect(function(char)
	-- Give the character physics a frame to settle
	task.wait(0.1)

	-- Re-snap camera to face forward
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		CameraController.SnapToDirection(root.CFrame.LookVector)
	end

	print("[ClientMain] Character respawned — camera reset.")
end)

print("[ClientMain] Boot complete.")
