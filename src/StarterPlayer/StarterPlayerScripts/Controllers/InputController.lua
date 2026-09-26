--[[
	MythicStrikers — InputController
	Unified input layer for PC (keyboard/mouse) and Mobile (touch).

	RESPONSIBILITIES:
	  • Poll keyboard / gamepad / touch state each frame
	  • Emit clean action signals that FootballController and other
	    controllers listen to — no game logic here
	  • Provide virtual joystick for mobile
	  • Maintain a keybind registry so bindings can be remapped
	  • Never fire RemoteEvents directly — only raise signals

	SIGNALS (module-level):
	  InputController.Signals.MoveDirection   → Vector2  (updated each frame)
	  InputController.Signals.SprintChanged   → bool
	  InputController.Signals.PassPressed     → ()
	  InputController.Signals.ShootPressed    → ()
	  InputController.Signals.ShootHeld       → number   (hold duration seconds)
	  InputController.Signals.ShootReleased   → ()
	  InputController.Signals.TacklePressed   → ()
	  InputController.Signals.Technique1      → ()
	  InputController.Signals.Technique2      → ()
	  InputController.Signals.Technique3      → ()
	  InputController.Signals.Technique4      → ()
	  InputController.Signals.AwakeningPressed→ ()
	  InputController.Signals.CelebrationPressed → ()

	SIGNAL PATTERN:
	  Each signal is a simple table { Connect, Fire }.
	  No external signal library required.
--]]

local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

-- ─────────────────────────────────────────────
-- Minimal signal implementation
-- ─────────────────────────────────────────────
local function newSignal()
	local cbs: { (...any) -> () } = {}
	return {
		Connect = function(_, cb: (...any) -> ())
			table.insert(cbs, cb)
			-- Return disconnect handle
			return {
				Disconnect = function()
					for i, c in ipairs(cbs) do
						if c == cb then table.remove(cbs, i) break end
					end
				end
			}
		end,
		Fire = function(_, ...)
			for _, cb in ipairs(cbs) do
				task.spawn(cb, ...)
			end
		end,
	}
end

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local InputController = {}

-- ─────────────────────────────────────────────
-- Signals
-- ─────────────────────────────────────────────
InputController.Signals = {
	MoveDirection      = newSignal(),
	SprintChanged      = newSignal(),
	PassPressed        = newSignal(),
	ShootPressed       = newSignal(),
	ShootHeld          = newSignal(),
	ShootReleased      = newSignal(),
	TacklePressed      = newSignal(),
	Technique1         = newSignal(),
	Technique2         = newSignal(),
	Technique3         = newSignal(),
	Technique4         = newSignal(),
	AwakeningPressed   = newSignal(),
	CelebrationPressed = newSignal(),
}

-- ─────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────
local _initialized     = false
local _isMobile        = false
local _isSprinting     = false
local _shootHoldStart: number? = nil
local _shootIsHeld     = false

-- Virtual joystick state (mobile)
local _vjActive        = false
local _vjOrigin        = Vector2.zero
local _vjCurrent       = Vector2.zero
local _vjThumbId: number? = nil   -- touch InputObject.Fingerprint

-- Current move direction (world-space XZ as Vector2)
local _moveDir         = Vector2.zero

-- ─────────────────────────────────────────────
-- Keybind registry
-- ─────────────────────────────────────────────
-- Default PC bindings. Players can override via Settings in Phase 8.
local Bindings = {
	Pass        = Enum.KeyCode.F,
	Shoot       = Enum.UserInputType.MouseButton1,   -- LMB
	Tackle      = Enum.KeyCode.G,
	Sprint      = Enum.KeyCode.LeftShift,
	Technique1  = Enum.KeyCode.Q,
	Technique2  = Enum.KeyCode.E,
	Technique3  = Enum.KeyCode.R,
	Technique4  = Enum.KeyCode.T,
	Awakening   = Enum.KeyCode.Z,
	Celebration = Enum.KeyCode.V,
}

-- Allow remapping
function InputController.SetBinding(action: string, keyCode)
	Bindings[action] = keyCode
end

-- ─────────────────────────────────────────────
-- Platform detection
-- ─────────────────────────────────────────────
local function detectPlatform()
	-- Roblox: touch device if TouchEnabled and not keyboard+mouse
	_isMobile = UserInputService.TouchEnabled
		and not UserInputService.KeyboardEnabled
end

-- ─────────────────────────────────────────────
-- PC keyboard input
-- ─────────────────────────────────────────────

local function handleKeyDown(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end

	local kc = input.KeyCode
	local ut = input.UserInputType

	if kc == Bindings.Sprint then
		if not _isSprinting then
			_isSprinting = true
			InputController.Signals.SprintChanged:Fire(true)
		end

	elseif kc == Bindings.Pass then
		InputController.Signals.PassPressed:Fire()

	elseif kc == Bindings.Tackle then
		InputController.Signals.TacklePressed:Fire()

	elseif kc == Bindings.Technique1 then
		InputController.Signals.Technique1:Fire()

	elseif kc == Bindings.Technique2 then
		InputController.Signals.Technique2:Fire()

	elseif kc == Bindings.Technique3 then
		InputController.Signals.Technique3:Fire()

	elseif kc == Bindings.Technique4 then
		InputController.Signals.Technique4:Fire()

	elseif kc == Bindings.Awakening then
		InputController.Signals.AwakeningPressed:Fire()

	elseif kc == Bindings.Celebration then
		InputController.Signals.CelebrationPressed:Fire()
	end

	-- Shoot — mouse button (check UserInputType)
	if ut == Bindings.Shoot then
		_shootIsHeld     = true
		_shootHoldStart  = tick()
		InputController.Signals.ShootPressed:Fire()
	end
end

local function handleKeyUp(input: InputObject, gameProcessed: boolean)
	local kc = input.KeyCode
	local ut = input.UserInputType

	if kc == Bindings.Sprint then
		if _isSprinting then
			_isSprinting = false
			InputController.Signals.SprintChanged:Fire(false)
		end
	end

	if ut == Bindings.Shoot and _shootIsHeld then
		local held = _shootHoldStart and (tick() - _shootHoldStart) or 0
		_shootIsHeld    = false
		_shootHoldStart = nil
		InputController.Signals.ShootHeld:Fire(held)
		InputController.Signals.ShootReleased:Fire()
	end
end

-- ─────────────────────────────────────────────
-- Mobile virtual joystick
-- ─────────────────────────────────────────────
local VJ_RADIUS     = 60   -- pixels
local VJ_DEAD_ZONE  = 8    -- pixels

-- The VJ GUI elements are created by UIController (Phase 13).
-- InputController just reads from the module-level VJ state that
-- UIController writes via InputController.SetVJState().

function InputController.SetVJState(active: boolean, origin: Vector2, current: Vector2, thumbId: number?)
	_vjActive   = active
	_vjOrigin   = origin
	_vjCurrent  = current
	_vjThumbId  = thumbId
end

function InputController.IsVJActive(): boolean
	return _vjActive
end

-- ─────────────────────────────────────────────
-- Movement direction computation
-- ─────────────────────────────────────────────

local function computeMoveDirection(): Vector2
	-- Mobile: use virtual joystick
	if _isMobile and _vjActive then
		local delta = _vjCurrent - _vjOrigin
		if delta.Magnitude < VJ_DEAD_ZONE then return Vector2.zero end
		local clamped = delta.Magnitude > VJ_RADIUS
			and (delta.Unit * VJ_RADIUS) or delta
		return clamped / VJ_RADIUS   -- normalised -1..1
	end

	-- PC: WASD
	local x = 0
	local y = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up)    then y += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down)  then y -= 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left)  then x -= 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then x += 1 end

	if x == 0 and y == 0 then return Vector2.zero end
	return Vector2.new(x, y).Unit
end

-- ─────────────────────────────────────────────
-- Shoot hold polling (emit ShootHeld each frame while held)
-- ─────────────────────────────────────────────
local _lastHeldEmit = 0
local HELD_EMIT_RATE = 0.1   -- seconds

-- ─────────────────────────────────────────────
-- Heartbeat loop
-- ─────────────────────────────────────────────
local function onRenderStep()
	-- Movement direction
	local dir = computeMoveDirection()
	if dir ~= _moveDir then
		_moveDir = dir
		InputController.Signals.MoveDirection:Fire(dir)
	end

	-- Shoot hold emission
	if _shootIsHeld and _shootHoldStart then
		local now  = tick()
		local held = now - _shootHoldStart
		if now - _lastHeldEmit >= HELD_EMIT_RATE then
			_lastHeldEmit = now
			InputController.Signals.ShootHeld:Fire(held)
		end
	end
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function InputController.GetMoveDirection(): Vector2
	return _moveDir
end

function InputController.IsSprinting(): boolean
	return _isSprinting
end

function InputController.IsShootHeld(): boolean
	return _shootIsHeld
end

function InputController.GetShootHoldTime(): number
	if not _shootIsHeld or not _shootHoldStart then return 0 end
	return tick() - _shootHoldStart
end

-- Mobile action triggers (called by UIController buttons)
function InputController.TriggerPass()
	InputController.Signals.PassPressed:Fire()
end

function InputController.TriggerShootStart()
	if not _shootIsHeld then
		_shootIsHeld    = true
		_shootHoldStart = tick()
		InputController.Signals.ShootPressed:Fire()
	end
end

function InputController.TriggerShootEnd()
	if _shootIsHeld then
		local held = _shootHoldStart and (tick() - _shootHoldStart) or 0
		_shootIsHeld    = false
		_shootHoldStart = nil
		InputController.Signals.ShootHeld:Fire(held)
		InputController.Signals.ShootReleased:Fire()
	end
end

function InputController.TriggerTackle()
	InputController.Signals.TacklePressed:Fire()
end

function InputController.TriggerTechnique(slot: number)
	local sig = InputController.Signals["Technique" .. tostring(slot)]
	if sig then sig:Fire() end
end

function InputController.TriggerAwakening()
	InputController.Signals.AwakeningPressed:Fire()
end

function InputController.TriggerSprintStart()
	if not _isSprinting then
		_isSprinting = true
		InputController.Signals.SprintChanged:Fire(true)
	end
end

function InputController.TriggerSprintEnd()
	if _isSprinting then
		_isSprinting = false
		InputController.Signals.SprintChanged:Fire(false)
	end
end

-- ─────────────────────────────────────────────
-- Init
-- ─────────────────────────────────────────────
function InputController.Init()
	if _initialized then return end
	_initialized = true

	detectPlatform()

	-- PC input
	UserInputService.InputBegan:Connect(handleKeyDown)
	UserInputService.InputEnded:Connect(handleKeyUp)

	-- Render step for movement + hold polling
	RunService.RenderStepped:Connect(onRenderStep)

	print(string.format(
		"[InputController] Initialised. Platform: %s",
		_isMobile and "Mobile" or "PC"
	))
end

return InputController
