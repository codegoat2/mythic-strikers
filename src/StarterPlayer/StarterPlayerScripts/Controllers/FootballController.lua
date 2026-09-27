--[[
	MythicStrikers — FootballController
	Client-side football gameplay logic.

	RESPONSIBILITIES:
	  • Listen to InputController signals and translate them into
	    server RemoteEvent calls
	  • Apply local character movement (direction + camera-relative)
	  • Visual possession indicator (local ball highlight)
	  • Local ball interpolation from BallStateUpdate
	  • Technique slot management (equip / activate)
	  • Awakening activation request
	  • Goalkeeper mode detection

	IMPORTANT SECURITY NOTE:
	  This controller REQUESTS actions from the server.
	  It NEVER assumes an action succeeded until the server confirms it.
	  Visual prediction (e.g. ball movement) is presentational only.
--]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local Constants              = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes                = require(ReplicatedStorage.Remotes)
local TechniqueDefinitions   = require(ReplicatedStorage.Shared.Techniques.TechniqueDefinitions)
local ClientAssetRegistry    = require(script.Parent.Parent.ClientAssetRegistry)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local FootballController = {}

-- ─────────────────────────────────────────────
-- Injected controllers (set in Init)
-- ─────────────────────────────────────────────
local InputController:  table
local CameraController: table
local UIController:     table    -- optional, for technique feedback

-- ─────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────
local _hasPossession    = false
local _isGoalkeeper     = false
local _teamId: string?  = nil
local _matchActive      = false
local _lobbyMode        = false
local _playerStats      = nil

-- Ball visual state (received from server)
local _ballPart: BasePart? = nil
local _serverBallPos   = Vector3.zero
local _serverBallVel   = Vector3.zero
local _lastBallUpdate  = 0

-- Equipped technique slots  (1–4)
local _equippedTechs: { string } = {}

-- Local technique cooldown display (server is authoritative, this is for UI feedback)
local _localCooldowns: { [number]: number } = {}   -- slot → expire tick

-- Character movement
local _moveDir          = Vector2.zero
local _isSprinting      = false
local _isMoving         = false

-- Shot charge state
local _chargeRatio      = 0
local _chargeActive     = false

-- Possession highlight
local _possessionHighlight: SelectionBox? = nil

local _initialized = false

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function getRoot(): BasePart?
	local char = LocalPlayer.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHumanoid(): Humanoid?
	local char = LocalPlayer.Character
	if not char then return nil end
	return char:FindFirstChildWhichIsA("Humanoid")
end

--- Convert a 2D input direction (camera-relative XZ) into world Vector3.
local function inputToWorld(dir2D: Vector2): Vector3
	if dir2D.Magnitude < 0.01 then return Vector3.zero end

	local fwd   = CameraController.GetForwardDirection()
	local right = CameraController.GetRightDirection()

	return (fwd * dir2D.Y + right * dir2D.X).Unit
end

--- Aim direction from player toward goal (simple heuristic for shoot default).
local function defaultShootDirection(): Vector3
	local root = getRoot()
	if not root then return Vector3.new(0, 0, -1) end

	-- Use camera forward as shot direction, elevated slightly
	local camFwd = CameraController.GetForwardDirection()
	return (camFwd + Vector3.new(0, 0.1, 0)).Unit
end

--- Find the ball Part in workspace if not yet cached.
local function findBall(): BasePart?
	if _ballPart and _ballPart.Parent then return _ballPart end
	local stadium = workspace:FindFirstChild("Stadium")
	if stadium then
		local b = stadium:FindFirstChild("Ball", true)
		if b and b:IsA("BasePart") then
			_ballPart = b :: BasePart
			CameraController.SetBall(_ballPart)
			return _ballPart
		end
	end
	local top = workspace:FindFirstChild("Ball")
	if top and top:IsA("BasePart") then
		_ballPart = top :: BasePart
		CameraController.SetBall(_ballPart)
		return _ballPart
	end
	return nil
end

--- Update the possession visual highlight.
local function setPossessionHighlight(hasPossession: boolean)
	if hasPossession then
		if not _possessionHighlight then
			local ball = findBall()
			if ball then
				local sb = Instance.new("SelectionBox")
				sb.Adornee        = ball
				sb.Color3         = Color3.fromRGB(255, 220, 50)
				sb.LineThickness  = 0.04
				sb.SurfaceTransparency = 0.8
				sb.SurfaceColor3  = Color3.fromRGB(255, 220, 50)
				sb.Parent         = LocalPlayer.PlayerGui
				_possessionHighlight = sb
			end
		end
	else
		if _possessionHighlight then
			_possessionHighlight:Destroy()
			_possessionHighlight = nil
		end
	end
end

--- Check local cooldown (display only — server enforces real cooldown).
local function isSlotReady(slot: number): boolean
	local expires = _localCooldowns[slot]
	if not expires then return true end
	return tick() >= expires
end

local function startLocalCooldown(slot: number, duration: number)
	_localCooldowns[slot] = tick() + duration
	if UIController then
		UIController.StartCooldownDisplay(slot, duration)
	end
end

-- ─────────────────────────────────────────────
-- Movement (RenderStepped)
-- ─────────────────────────────────────────────

local function applyMovement()
	local hum = getHumanoid()
	if not hum or hum.Health <= 0 then return end

	if _moveDir.Magnitude < 0.01 then
		-- Release movement. Without this the last direction sticks and the
		-- player keeps walking after letting go of the key / joystick.
		if _isMoving then
			_isMoving = false
			hum:Move(Vector3.zero, false)
		end
		return
	end

	-- Convert 2D input to world direction
	local worldDir = inputToWorld(_moveDir)

	-- Move character by setting MoveDirection
	-- Roblox's Humanoid uses MoveDirection when not using default controls
	hum:Move(worldDir, false)
	_isMoving = true
end

-- ─────────────────────────────────────────────
-- Input Signal Handlers
-- ─────────────────────────────────────────────

local function onMoveDirection(dir: Vector2)
	_moveDir = dir
end

local function onSprintChanged(sprinting: boolean)
	_isSprinting = sprinting
	CameraController.SetSprinting(sprinting)

	-- Request sprint from server
	Remotes.FireServer(Constants.Remotes.RequestSprint, {
		Sprinting = sprinting,
	})
end

local function onPassPressed()
	if not _hasPossession then return end

	-- Direction: toward nearest teammate (simplified — aimed via input dir)
	local root  = getRoot()
	if not root then return end

	local passDir = inputToWorld(_moveDir)
	if passDir.Magnitude < 0.01 then
		passDir = CameraController.GetForwardDirection()
	end

	Remotes.FireServer(Constants.Remotes.RequestPass, {
		Direction = passDir,
		IsLob     = false,
	})
end

local function onShootPressed()
	_chargeActive = true
	_chargeRatio  = 0
	-- Tell server we started charging
	Remotes.FireServer(Constants.Remotes.PlayerInput, {
		Action    = "ChargeStart",
		Timestamp = tick(),
	})
end

local function onShootHeld(holdTime: number)
	_chargeRatio = math.clamp(holdTime / Constants.CHARGED_SHOT_TIME, 0, 1)
end

local function onShootReleased()
	if not _hasPossession then
		_chargeActive = false
		_chargeRatio  = 0
		return
	end

	local root = getRoot()
	if not root then return end

	-- Determine shot direction
	local shootDir = inputToWorld(_moveDir)
	if shootDir.Magnitude < 0.01 then
		shootDir = defaultShootDirection()
	end

	-- Determine if charged
	local isCharged = _chargeRatio >= 0.15

	Remotes.FireServer(Constants.Remotes.RequestShoot, {
		Direction  = shootDir,
		IsCharged  = isCharged,
		ChargeTime = _chargeRatio * Constants.CHARGED_SHOT_TIME,
		Timestamp  = tick(),
	})

	_chargeActive = false
	_chargeRatio  = 0
end

local function onTacklePressed()
	if _hasPossession then return end   -- can't tackle while you have the ball

	local root = getRoot()
	if not root then return end

	local tackleDir = inputToWorld(_moveDir)
	if tackleDir.Magnitude < 0.01 then
		tackleDir = CameraController.GetForwardDirection()
	end

	Remotes.FireServer(Constants.Remotes.RequestTackle, {
		Direction = tackleDir,
		Timestamp = tick(),
	})
end

local function onTechniqueSlot(slot: number)
	local techId = _equippedTechs[slot]
	if not techId then return end

	-- Local cooldown gate
	if not isSlotReady(slot) then return end

	local def = TechniqueDefinitions.Get(techId)
	if not def then return end

	-- Determine direction
	local root = getRoot()
	if not root then return end
	local techDir = inputToWorld(_moveDir)
	if techDir.Magnitude < 0.01 then
		techDir = CameraController.GetForwardDirection()
	end

	Remotes.FireServer(Constants.Remotes.RequestTechnique, {
		TechId    = techId,
		Direction = techDir,
		Timestamp = tick(),
	})

	-- Start local cooldown for feedback (server will also enforce)
	startLocalCooldown(slot, def.Cooldown)
end

local function onAwakeningPressed()
	Remotes.FireServer(Constants.Remotes.RequestAwakening, {
		Timestamp = tick(),
	})
end

-- ─────────────────────────────────────────────
-- Remote Handlers (Server → Client)
-- ─────────────────────────────────────────────

local function onBallStateUpdate(payload: table)
	if typeof(payload) ~= "table" then return end

	-- There are two balls: the stadium match ball and the town practice ball.
	-- The server now broadcasts exactly one per tick, tagged with IsLobby.
	-- Previously this handler ignored the tag, so in town the client treated
	-- stadium-ball packets as practice-ball packets.
	_lobbyMode = (payload.IsLobby == true)

	-- Update server-authoritative ball state (rendered via replication)
	if payload.Position then
		_serverBallPos  = payload.Position
		_serverBallVel  = payload.Velocity or Vector3.zero
		_lastBallUpdate = tick()
	end

	-- Possession status
	local hasPoss = (payload.Possessor == LocalPlayer.UserId)
	if hasPoss ~= _hasPossession then
		_hasPossession = hasPoss
		setPossessionHighlight(hasPoss)
	end
end

local function onTeamAssigned(payload: table)
	if typeof(payload) ~= "table" then return end
	_teamId = payload.TeamId

	-- Detect goalkeeper: set by first joining with GK role or
	-- assigned explicitly (Phase 5+ will have role selection).
	-- For now, no automatic GK detection; players can set via /gk command.

	-- Handle spectator mode
	if _teamId == "Spectator" then
		CameraController.SetSpectator(true)
		-- Start the spectator camera on the pitch rather than the hardcoded
		-- lobby origin the camera used to be stuck at.
		local ball = findBall()
		CameraController.SetSpectatorTarget(
			(ball and ball.Position) or (Vector3.new(0, 6, 0))
		)
		CameraController.SetSpectatorZoom(70)
	else
		CameraController.SetSpectator(false)
	end

	print(string.format("[FootballController] Assigned to %s", tostring(_teamId)))
end

local function onMatchStateUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	_matchActive = (payload.State == "Active")
	-- Detect lobby mode (lobby states)
	if payload.IsLobby ~= nil then
		_lobbyMode = payload.IsLobby
	end

	-- ── Spectator camera target ───────────────────────────────────────
	-- The spectator camera previously stayed parked at a hardcoded position
	-- following nothing. It now tracks the ball while a match is running and
	-- points at the centre circle between matches.
	if _teamId == "Spectator" then
		local ball = findBall()
		if _matchActive and ball then
			CameraController.SetSpectatorTarget(ball.Position)
		else
			CameraController.SetSpectatorTarget(
				Vector3.new(0, 6, 0)
			)
		end
	end

	-- Leaving spectator mode must reset the camera, not wait for the next
	-- TeamAssigned event.
	if payload.State == "Ended" and _teamId == "Spectator" then
		_lobbyMode = true
	end
end

local function onNotifyPlayer(payload: table)
	if typeof(payload) ~= "table" then return end
	if payload.Type == "Save" then
		-- Visual feedback for goalkeeper save
		if UIController then
			UIController.PlaySaveEffect(payload.KeeperId == LocalPlayer.UserId)
		end
	elseif payload.Type == "Tackle" then
		-- Visual feedback
		if UIController then
			UIController.PlayTackleEffect(payload.TacklerId == LocalPlayer.UserId)
		end
	end
end

local function onTechniqueResult(payload: table)
	-- Server confirmed (or denied) a technique.
	if typeof(payload) ~= "table" then return end
	if not payload.Success then return end

	local position = payload.Position or Vector3.zero

	if payload.VFX then
		ClientAssetRegistry.SpawnVFX(payload.VFX, position)
	end
	if payload.SFX then
		ClientAssetRegistry.PlaySFX(payload.SFX, position)
	end
end

-- ─────────────────────────────────────────────
-- Ball interpolation (RenderStepped)
-- ─────────────────────────────────────────────

local function updateBallInterpolation(_dt: number)
	-- The ball is server-owned: BallService calls SetNetworkOwner(nil), so the
	-- server replicates its transform to us. Writing ball.CFrame here fought
	-- the server's ownership every frame and, before the first BallStateUpdate
	-- arrived, dragged the ball to the world origin. The client renders the
	-- replicated transform and predicts nothing.
end

-- ─────────────────────────────────────────────
-- RenderStepped
-- ─────────────────────────────────────────────

local function onRenderStepped(dt: number)
	applyMovement()
	updateBallInterpolation(dt)
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function FootballController.Init(inputCtrl: table, cameraCtrl: table, uiCtrl: table?)
	-- Without this guard a second Init() double-connects every input signal and
	-- every remote fires twice.
	if _initialized then return end
	_initialized = true

	InputController  = inputCtrl
	CameraController = cameraCtrl
	UIController     = uiCtrl

	-- Wire input signals
	local S = InputController.Signals
	S.MoveDirection:Connect(onMoveDirection)
	S.SprintChanged:Connect(onSprintChanged)
	S.PassPressed:Connect(onPassPressed)
	S.ShootPressed:Connect(onShootPressed)
	S.ShootHeld:Connect(onShootHeld)
	S.ShootReleased:Connect(onShootReleased)
	S.TacklePressed:Connect(onTacklePressed)
	S.Technique1:Connect(function() onTechniqueSlot(1) end)
	S.Technique2:Connect(function() onTechniqueSlot(2) end)
	S.Technique3:Connect(function() onTechniqueSlot(3) end)
	S.Technique4:Connect(function() onTechniqueSlot(4) end)
	S.AwakeningPressed:Connect(onAwakeningPressed)

	-- Wire server remotes
	Remotes.OnClientEvent(Constants.Remotes.BallStateUpdate,   onBallStateUpdate)
	Remotes.OnClientEvent(Constants.Remotes.TeamAssigned,      onTeamAssigned)
	Remotes.OnClientEvent(Constants.Remotes.MatchStateUpdate,  onMatchStateUpdate)
	Remotes.OnClientEvent(Constants.Remotes.TechniqueResult,   onTechniqueResult)
	Remotes.OnClientEvent(Constants.Remotes.NotifyPlayer,      onNotifyPlayer)

	-- RenderStepped
	RunService.RenderStepped:Connect(onRenderStepped)

	-- Initial ball find
	task.spawn(function()
		task.wait(1)
		findBall()
	end)

	print("[FootballController] Initialised.")
end

--- Set equipped technique slots from profile data.
--- techs: array of up to 4 technique IDs
function FootballController.SetEquippedTechniques(techs: { string })
	_equippedTechs = {}
	for i = 1, math.min(4, #techs) do
		_equippedTechs[i] = techs[i]
	end
end

--- Manually set goalkeeper mode (called by UIController or role-select).
function FootballController.SetGoalkeeperMode(isGK: boolean)
	_isGoalkeeper = isGK
	CameraController.SetGoalkeeperMode(isGK)
end

--- Set lobby mode state (ball practice in town).
function FootballController.SetLobbyMode(active: boolean)
	_lobbyMode = active
end

--- Set player stats for local calculations.
function FootballController.SetPlayerStats(stats: table?)
	_playerStats = stats
end

--- Returns whether local player currently has possession.
function FootballController.HasPossession(): boolean
	return _hasPossession
end

--- Returns local player's team ID.
function FootballController.GetTeamId(): string?
	return _teamId
end

--- Returns current charge ratio (0–1) for UI feedback.
function FootballController.GetChargeRatio(): number
	return _chargeRatio
end

return FootballController
