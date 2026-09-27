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
-- Kept short on purpose: the loading screen must not sit here for 15s. If the
-- remotes are not up by now, we continue and the overlay still comes down.
local function waitForServer(timeout: number): boolean
	local start = tick()
	while tick() - start < timeout do
		local folder = ReplicatedStorage:FindFirstChild("RemoteEvents")
		if folder then return true end
		task.wait(0.2)
	end
	return false
end

local serverReady = waitForServer(6)
if not serverReady then
	warn("[ClientMain] Server remotes did not appear within 6 seconds. Proceeding anyway.")
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

-- Give UIController the camera so goals and saves can shake it.
UIController.SetCameraController(CameraController)

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
		task.wait(8)
		if not dismissed then
			warn("[ClientMain] Loading deadline reached — forcing dismiss.")
		end
		dismiss()
	end)

	-- The overlay comes down NOW. Every controller is already built, so the
	-- player can move, look around and see the HUD. The profile is fetched in
	-- the background and simply fills the card in when it arrives — it must
	-- never be a reason to keep someone staring at a loading screen.
	dismiss()

	-- Wait for the character, but only briefly, and only because the profile
	-- query is more useful once PlayerService has a character to attach to.
	if not LocalPlayer.Character then
		local spawnDeadline = tick() + 8
		while not LocalPlayer.Character and tick() < spawnDeadline do
			task.wait(0.25)
		end
	end

	-- Poll for the profile. PlayerService retries the DataStore up to 3 times,
	-- so a slow or unavailable store (common in Studio) means the profile is
	-- briefly nil. Retry a few times rather than giving up after one miss.
	local profile = nil
	for attempt = 1, 8 do
		local ok, result = pcall(function()
			return Remotes.InvokeServer("GetPlayerProfile")
		end)
		if ok and result then
			profile = result
			break
		end
		task.wait(1.5)
	end

	if profile then
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
		warn("[ClientMain] Profile unavailable after 8 attempts — continuing without it.")
	end
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
		-- Seed the UI. We must NOT call Remotes.Get(...).OnClientEvent:Fire(...)
		-- here: OnClientEvent is a signal the server owns, and :Fire on it
		-- throws "Fire is not a valid member of RBXScriptSignal".
		UIController.ApplyMatchState(matchData)
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
