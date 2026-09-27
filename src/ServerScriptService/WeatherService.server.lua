--[[
	MythicStrikers — WeatherService
	Owns WHICH weather the world is in. Owns nothing about how it looks.

	THE REWRITE
	This script used to create the Sky, the Atmosphere, the Clouds and to
	lerp ClockTime / Brightness / Ambient / OutdoorAmbient on a 90-second cycle.
	LightingService does all of that now. With both running, the two systems
	overwrote each other every frame of every transition, which is why the
	atmosphere never looked deliberate — it was a tug of war, not a look.

	So: this file decides the weather NAME and publishes it. LightingService
	turns that name into a complete, coherent lighting preset.

	Update 1.0 ships ONE polished default (Evening — late-afternoon light on a
	football ground, which flatters the pitch and the stands at the same time).
	The cycle is retained but disabled, because section 16 of the design brief
	asks for the architecture to support day/evening/night/event lighting later
	without implementing several unfinished environments now.
--]]

local Lighting   = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

assert(RunService:IsServer(), "WeatherService must run on the server.")

-- LightingService lives in ServerScriptService.World. Required, not created,
-- so there is exactly one lighting owner.
local LightingService = require(
	ServerScriptService:WaitForChild("World"):WaitForChild("LightingService")
)

-- ─────────────────────────────────────────────
-- Configuration
-- ─────────────────────────────────────────────

--- The one shipped look. Deliberate, not a random draw.
local DEFAULT_STATE = "Evening"

--- Auto-cycling is off for Update 1.0. Flip to true to see the full range.
local CYCLE_ENABLED = false
local CYCLE_SECONDS = 420
local BOOT_DELAY    = 3

--- Weighted transitions, so when cycling is enabled storms read as occasional
--- rather than constant.
local NEXT_STATE = {
	Clear   = { Cloudy = 0.65, Fog = 0.35 },
	Cloudy  = { Clear = 0.45, Rain = 0.30, Evening = 0.25 },
	Evening = { Clear = 0.50, Cloudy = 0.30, Rain = 0.20 },
	Rain    = { Cloudy = 0.60, Storm = 0.40 },
	Storm   = { Rain = 0.80, Cloudy = 0.20 },
	Fog     = { Clear = 0.60, Evening = 0.40 },
}

-- ─────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────

local currentState: string = DEFAULT_STATE

--- Publish the weather and hand the actual look to LightingService.
--- The Lighting.WeatherState attribute is retained because the client reads it
--- for rain particles, thunder flashes and rain ambience. Renaming it would
--- break that hook, so it stays exactly as it was.
local function apply(name: string, announce: boolean?)
	if not LightingService.TIMES[name] then
		warn("[WeatherService] Unknown weather state: " .. tostring(name))
		return
	end

	currentState = name
	Lighting:SetAttribute("WeatherState", name)
	LightingService.SetTimeOfDay(name)

	if announce ~= false then
		print("[WeatherService] Weather: " .. name
			.. string.format(" (ClockTime %.1f)", Lighting.ClockTime))
	end
end

local function pickNext(from: string): string
	local weights = NEXT_STATE[from]
	if not weights then return DEFAULT_STATE end
	local roll = math.random()
	local acc = 0
	for state, weight in pairs(weights) do
		acc += weight
		if roll <= acc then return state end
	end
	return DEFAULT_STATE
end

-- ─────────────────────────────────────────────
-- Run
-- ─────────────────────────────────────────────

task.spawn(function()
	-- Let the world builders and LightingService.Init finish first.
	task.wait(BOOT_DELAY)

	-- Delete anything this script used to own. LightingService creates its own
	-- MythicSky / MythicAtmosphere; a leftover WeatherSky or WeatherAtmosphere
	-- would render as a second, conflicting dome.
	for _, legacy in ipairs({ "WeatherSky", "WeatherAtmosphere", "WeatherClouds" }) do
		local e = Lighting:FindFirstChild(legacy)
		if e then e:Destroy() end
	end
	local legacyClouds = workspace.Terrain:FindFirstChild("WeatherClouds")
	if legacyClouds then legacyClouds:Destroy() end

	apply(DEFAULT_STATE)

	if not CYCLE_ENABLED then
		print("[WeatherService] Cycling disabled. Shipped look: " .. DEFAULT_STATE
			.. ". Enable CYCLE_ENABLED in this file to preview other states.")
		return
	end

	while true do
		task.wait(CYCLE_SECONDS)
		local nextState = pickNext(currentState)
		if nextState ~= currentState then
			apply(nextState)
		end
	end
end)

print("[WeatherService] Initialised. Default state: " .. DEFAULT_STATE)
