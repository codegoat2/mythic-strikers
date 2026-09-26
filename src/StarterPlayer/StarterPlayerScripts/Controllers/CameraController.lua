--[[
	MythicStrikers — CameraController
	Football-style third-person camera with ball awareness.

	FEATURES:
	  • Smooth third-person follow camera locked behind player
	  • Ball-aware: camera softly tilts toward the ball when possessed
	    or nearby to keep play context visible
	  • Configurable distance, height, sensitivity
	  • Cinematic mode: takes manual control during technique sequences
	  • Goalkeeper mode: slightly wider, lower angle facing field
	  • Mouse lock toggle (right-click drag to orbit)
	  • Mobile: one-finger drag to orbit
	  • Smooth lerp for all transitions — no jarring cuts

	DESIGN:
	  Uses Roblox's Custom camera type.
	  All updates happen in RenderStepped (before Roblox renders the frame).
	  Never sets CFrame in Heartbeat (physics step) — only RenderStepped.
--]]

local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
-- Resolved lazily: workspace.CurrentCamera can be nil at require time, which
-- previously threw "attempt to index nil with 'CameraType'" on first Play.
local function getCamera(): Camera?
	return workspace.CurrentCamera
end

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local CameraController = {}

-- ─────────────────────────────────────────────
-- Configuration (tunable)
-- ─────────────────────────────────────────────
local Config = {
	-- Normal play
	Distance         = 22,      -- studs behind player
	Height           = 10,      -- studs above player root
	PitchAngle       = 18,      -- degrees downward tilt
	LerpSpeed        = 8,       -- positional lerp alpha multiplier
	RotLerpSpeed     = 10,      -- rotational lerp alpha multiplier
	MouseSensitivity = 0.35,    -- degrees per pixel
	TouchSensitivity = 0.25,

	-- Ball pull (when ball is in view ahead of player)
	BallPullStrength = 0.18,    -- 0 = ignore ball, 1 = fully look at ball
	BallPullMaxAngle = 20,      -- degrees max extra pitch/yaw toward ball

	-- Goalkeeper
	GKDistance       = 28,
	GKHeight         = 12,
	GKPitchAngle     = 14,

	-- Cinematic (technique sequences)
	CinDistance      = 15,
	CinHeight        = 6,
	CinFOV           = 70,
	NormalFOV        = 70,

	-- Field-of-view
	DefaultFOV       = 70,
	SprintFOV        = 74,      -- slight FOV boost while sprinting for speed feel
	FOVLerpSpeed     = 5,
}

-- ─────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────
local _initialized      = false
local _isGoalkeeper     = false
local _isCinematic      = false
local _cinematicCFrame: CFrame? = nil
local _cinematicFOV     = Config.NormalFOV

-- Orbit angles (radians)
local _yaw   = 0   -- horizontal rotation (around world Y)
local _pitch = math.rad(-Config.PitchAngle)  -- vertical tilt (negative = look down)

-- Target and current camera state (lerped each frame)
local _targetCFrame  = CFrame.identity
local _currentCFrame = CFrame.identity
local _targetFOV     = Config.DefaultFOV
local _currentFOV    = Config.DefaultFOV

-- Ball reference (set via SetBall)
local _ball: BasePart? = nil

-- Input dragging state
local _isDragging      = false
local _lastMousePos    = Vector2.zero
local _isMobile        = false

-- Sprint FOV state (set by FootballController)
local _isSprinting     = false

-- Spectator mode
local _isSpectator     = false
local _spectatorTargetPos: Vector3 = Vector3.new(0, 0, 600)
local _spectatorZoom   = 35.0

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function getPlayerRoot(): BasePart?
	local char = LocalPlayer.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function lerpCFrame(a: CFrame, b: CFrame, t: number): CFrame
	return a:Lerp(b, t)
end

local function clamp(v: number, min: number, max: number): number
	return math.max(min, math.min(max, v))
end

-- ─────────────────────────────────────────────
-- Orbit input handling
-- ─────────────────────────────────────────────

--- Returns true when the given screen position lands on an interactive UI
--- element. Without this check every touch on the mobile joystick or an action
--- button also started a camera orbit, and lifting that finger killed it.
local function isTouchOverUI(pos: Vector2): boolean
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	if not pg then return false end
	local ok, objects = pcall(function()
		return pg:GetGuiObjectsAtPosition(pos)
	end)
	if not ok or not objects then return false end
	for _, obj in ipairs(objects) do
		if obj:IsA("GuiButton") or obj:IsA("TextButton") or obj:IsA("TextBox") then
			return true
		end
		if obj:IsA("GuiObject") and obj.Active and obj.Selectable then
			return true
		end
	end
	return false
end

local function onInputBegan(input: InputObject, gp: boolean)
	if gp then return end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		-- Right-click drag to orbit (PC)
		_isDragging   = true
		_lastMousePos = Vector2.new(input.Position.X, input.Position.Y)
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	elseif input.UserInputType == Enum.UserInputType.Touch then
		-- Mobile: orbit with any finger that is not on a UI control.
		if isTouchOverUI(Vector2.new(input.Position.X, input.Position.Y)) then
			return
		end
		_isDragging   = true
		_lastMousePos = Vector2.new(input.Position.X, input.Position.Y)
	end
end

local function onInputEnded(input: InputObject, gp: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2
	or input.UserInputType == Enum.UserInputType.Touch then
		_isDragging = false
		if not _isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end
end

local function onInputChanged(input: InputObject, gp: boolean)
	if not _isDragging then return end
	if _isCinematic then return end

	local pos  = Vector2.new(input.Position.X, input.Position.Y)
	local delta = pos - _lastMousePos
	_lastMousePos = pos

	local sens = _isMobile and Config.TouchSensitivity or Config.MouseSensitivity
	_yaw   = _yaw   - math.rad(delta.X * sens)
	_pitch = clamp(
		_pitch - math.rad(delta.Y * sens),
		math.rad(-70),   -- max look-up
		math.rad(-5)     -- max look-down
	)
end

-- ─────────────────────────────────────────────
-- Camera computation
-- ─────────────────────────────────────────────

local function computeNormalCamera(root: BasePart, dt: number): CFrame
	local dist   = _isGoalkeeper and Config.GKDistance   or Config.Distance
	local height = _isGoalkeeper and Config.GKHeight      or Config.Height

	-- Base rotation from yaw + pitch
	local rotCF = CFrame.Angles(0, _yaw, 0) * CFrame.Angles(_pitch, 0, 0)

	-- Camera position: behind + above the player root
	local offset   = rotCF:VectorToWorldSpace(Vector3.new(0, height, dist))
	local camPos   = root.Position + offset

	-- Look-at target: player's root + small forward offset so camera looks
	-- slightly ahead of player rather than dead-center
	local lookTarget = root.Position + Vector3.new(0, 2, 0)

	-- Ball pull: softly angle toward ball when it's ahead of player
	if _ball and not _isGoalkeeper then
		local ballPos = _ball.Position
		local toCam   = (camPos - root.Position)
		local toBall  = (ballPos - root.Position)
		if toBall.Magnitude > 2 then
			local dot = toCam.Unit:Dot(toBall.Unit)
			-- Only pull when ball is roughly in front (not behind camera)
			if dot > -0.3 then
				local pullStrength = Config.BallPullStrength * math.clamp(
					toBall.Magnitude / 60, 0, 1
				)
				lookTarget = lookTarget:Lerp(ballPos, pullStrength)
			end
		end
	end

	return CFrame.lookAt(camPos, lookTarget)
end

-- ─────────────────────────────────────────────
-- RenderStepped
-- ─────────────────────────────────────────────

local function onRenderStepped(dt: number)
	if not _initialized then return end

	local root = getPlayerRoot()
	if not root and not _isSpectator then return end

	-- Ensure camera type is Custom
	local Camera = getCamera()
	if not Camera then return end
	if Camera.CameraType ~= Enum.CameraType.Custom then
		Camera.CameraType = Enum.CameraType.Custom
	end

	local targetFOV: number
	local targetCF:  CFrame

	if _isCinematic and _cinematicCFrame then
		-- Cinematic override
		targetCF  = _cinematicCFrame
		targetFOV = _cinematicFOV
	elseif _isSpectator then
		-- Free spectator camera: orbit around a target point
		local rotCF = CFrame.Angles(0, _yaw, 0) * CFrame.Angles(_pitch, 0, 0)
		local camPos = _spectatorTargetPos + rotCF:VectorToWorldSpace(Vector3.new(0, _spectatorZoom * 0.5, _spectatorZoom))
		targetCF = CFrame.lookAt(camPos, _spectatorTargetPos)
		targetFOV = Config.DefaultFOV
	else
		targetCF  = computeNormalCamera(root, dt)
		targetFOV = _isSprinting and Config.SprintFOV or Config.DefaultFOV
	end

	-- Lerp toward targets
	local alpha = math.min(1, dt * Config.LerpSpeed)
	_currentCFrame = lerpCFrame(_currentCFrame, targetCF, alpha)

	local fovAlpha = math.min(1, dt * Config.FOVLerpSpeed)
	_currentFOV    = lerp(_currentFOV, targetFOV, fovAlpha)

	Camera.CFrame      = _currentCFrame
	Camera.FieldOfView = _currentFOV
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function CameraController.Init()
	if _initialized then return end
	_initialized = true

	_isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	-- Take camera control
	local Camera = getCamera()
	if Camera then
		Camera.CameraType = Enum.CameraType.Custom
	end

	-- Seed yaw from player's current facing direction if possible
	local root = getPlayerRoot()
	if root then
		_yaw = math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
	end
	_pitch = math.rad(-Config.PitchAngle)

	-- Seed the lerp start at the correct camera pose. Without this the camera
	-- lerps in from the world origin and the view swings across the map on spawn.
	if root then
		_currentCFrame = computeNormalCamera(root, 0)
	else
		task.defer(function()
			local r = getPlayerRoot()
			if r and _currentCFrame == CFrame.identity then
				_currentCFrame = computeNormalCamera(r, 0)
			end
		end)
	end

	-- Input listeners
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.InputChanged:Connect(onInputChanged)

	-- Render step
	RunService.RenderStepped:Connect(onRenderStepped)

	print("[CameraController] Initialised.")
end

--- Provide the ball Part reference so camera can track it.
function CameraController.SetBall(ball: BasePart?)
	_ball = ball
end

--- Switch to / from goalkeeper camera preset.
function CameraController.SetGoalkeeperMode(enabled: boolean)
	_isGoalkeeper = enabled
end

--- Set sprint state (affects FOV breathing).
function CameraController.SetSprinting(sprinting: boolean)
	_isSprinting = sprinting
end

--- Activate cinematic camera mode for a technique sequence.
--- targetCFrame: desired camera CFrame during cinematic
--- fov: optional custom FOV (defaults to CinFOV)
--- duration: seconds before auto-returning to normal (0 = manual)
function CameraController.StartCinematic(targetCFrame: CFrame, fov: number?, duration: number?)
	_isCinematic    = true
	_cinematicCFrame = targetCFrame
	_cinematicFOV   = fov or Config.CinFOV

	if duration and duration > 0 then
		task.delay(duration, function()
			CameraController.EndCinematic()
		end)
	end
end

--- Return camera to normal gameplay mode.
function CameraController.EndCinematic()
	_isCinematic     = false
	_cinematicCFrame = nil
	_cinematicFOV    = Config.NormalFOV
end

--- Instantly snap yaw to face a world-space direction (used after team teleport).
function CameraController.SnapToDirection(direction: Vector3)
	_yaw = math.atan2(-direction.X, -direction.Z)
end

--- Returns the camera's current horizontal yaw in radians.
function CameraController.GetYaw(): number
	return _yaw
end

--- Returns the forward direction the camera is currently facing (XZ plane).
--- The camera sits at root + (0, height, dist) rotated by _yaw, so it looks
--- back along -Z of that rotation. The previous version returned the opposite
--- Z, which made every pass, shot, tackle and technique fire behind the player.
function CameraController.GetForwardDirection(): Vector3
	return Vector3.new(
		-math.sin(_yaw),
		0,
		-math.cos(_yaw)
	).Unit
end

--- Returns the right direction perpendicular to camera forward (XZ plane).
function CameraController.GetRightDirection(): Vector3
	return Vector3.new(
		math.cos(_yaw),
		0,
		-math.sin(_yaw)
	).Unit
end

--- Update config values at runtime (e.g. from settings menu).
function CameraController.SetConfig(key: string, value: number)
	if Config[key] ~= nil then
		Config[key] = value
	end
end

--- Toggle spectator mode (free camera to watch match).
function CameraController.SetSpectator(enabled: boolean, targetPos: Vector3?)
	_isSpectator = enabled
	if targetPos then
		_spectatorTargetPos = targetPos
	end
	local Camera = getCamera()
	if not Camera then return end
	if enabled then
		Camera.CameraType = Enum.CameraType.Custom
	else
		-- Snap straight back behind the player instead of lerping across the
		-- map from wherever the spectator camera happened to be.
		Camera.CameraType = Enum.CameraType.Custom
		local root = getPlayerRoot()
		if root then
			_yaw = math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
			_currentCFrame = computeNormalCamera(root, 0)
		end
		_pitch = math.rad(-Config.PitchAngle)
	end
end

--- Set the spectator camera target position.
function CameraController.SetSpectatorTarget(pos: Vector3)
	_spectatorTargetPos = pos
end

--- Set the spectator camera zoom distance.
function CameraController.SetSpectatorZoom(zoom: number)
	_spectatorZoom = math.clamp(zoom, 10, 200)
end

return CameraController
