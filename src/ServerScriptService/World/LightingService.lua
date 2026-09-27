--[[
	MythicStrikers — LightingService
	Sole owner of the Lighting service.

	WHY THIS FILE EXISTS
	Three systems used to write to Lighting simultaneously:
	  • WeatherService set ClockTime, sky, atmosphere, fog, bloom, colour grade
	  • StadiumBuilder created StadiumBloom / StadiumColourGrade / StadiumSunRays
	  • the baseplate template shipped its own Sky and Bloom
	They overwrote each other in a race, which is why the atmosphere never
	looked deliberate.

	LightingService is now the only writer. WeatherService drives it through
	SetTimeOfDay() instead of touching Lighting, and StadiumBuilder creates no
	lighting objects at all.

	QUALITY
	Graphics quality is resolved once and applied here, because GlobalShadows
	and post-processing are server-authoritative in Roblox. Low-end devices get
	the same game with less post-processing, never a lesser game.
--]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage.Shared.Config.Palette)

local LightingService = {}

LightingService.quality = "HIGH"
LightingService._timeOfDay = "Evening"

-- ─────────────────────────────────────────────
-- Find-or-create, so a rebuild can never stack duplicate effects.
-- ─────────────────────────────────────────────

local function ensure(class: string, name: string)
	local e = Lighting:FindFirstChild(name)
	if not e then
		local ok, inst = pcall(function()
			return Instance.new(class)
		end)
		if not ok then
			print(string.format("[LightingService] Cannot create %s (%s) on this build: %s",
				name, class, tostring(inst)))
			return nil
		end
		e = inst
		e.Name = name
		e.Parent = Lighting
	end
	return e
end

-- Current engine builds have dropped several members this look was written
-- against: Lighting.GeoScale, Lighting.ShadowQuality, the classic Sky colour
-- members (SkyTint, TopColor, BottomColor, HorizonColor, AngularSize, since
-- the skybox became texture-driven) and ColorCorrectionEffect.TintStrength.
-- Assigning a member that does not exist is a hard error, not a no-op, so one
-- stale line aborts Init halfway and leaves the world with the template sky and
-- no post-processing. Optional writes go through here, so a build that lacks
-- the member is skipped rather than fatal.
local function setIfPresent(obj: any, property: string, value: any)
	if not obj then return end
	local ok, err = pcall(function()
		(obj :: any)[property] = value
	end)
	if not ok then
		print(string.format("[LightingService] Skipped %s.%s: %s",
			obj:GetFullName(), property, err))
	end
end

function LightingService.Init(quality: string?)
	LightingService.quality = quality or "HIGH"
	local q = Palette.Quality[LightingService.quality] or Palette.Quality.HIGH

	-- ── Base environment ────────────────────────────────────────────────
	-- Mid-afternoon overcast is the honest default for a football ground:
	-- enough contrast for the pitch to read, not so much that the lower bowl
	-- disappears into shadow. Dusk is a separate preset, applied below.
	Lighting.ClockTime = 15.5
	Lighting.Brightness = 2.6
	Lighting.Ambient = Color3.fromRGB(118, 126, 142)
	Lighting.OutdoorAmbient = Color3.fromRGB(142, 150, 166)
	Lighting.ColorShift_Top = Color3.fromRGB(206, 218, 236)
	Lighting.ColorShift_Bottom = Color3.fromRGB(72, 78, 92)
	Lighting.ExposureCompensation = 0.05
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.2

	-- ── Sky ──────────────────────────────────────────────────────────────
	-- Brighter, more saturated football-stadium sky. The horizon stays warm
	-- so the pitch reads as sunlit; the upper sky is a richer blue rather
	-- than the old desaturated slate.
	local sky = ensure("Sky", "MythicSky")
	setIfPresent(sky, "SkyTint", Color3.fromRGB(210, 225, 245))
	setIfPresent(sky, "HorizonColor", Color3.fromRGB(240, 220, 200))
	setIfPresent(sky, "TopColor", Color3.fromRGB(80, 130, 210))
	setIfPresent(sky, "BottomColor", Color3.fromRGB(180, 210, 240))
	setIfPresent(sky, "AngularSize", 10)
	sky.CelestialBodiesShown = true

	-- Remove anything the template or an old builder left behind, so it cannot
	-- fight the presets set here.
	for _, legacy in ipairs({
		"StadiumBloom", "StadiumColourGrade", "StadiumSunRays",
		"Atmosphere", "Sky", "BloomEffect", "ColorCorrectionEffect", "SunRaysEffect",
		"Clouds",
	}) do
		local e = Lighting:FindFirstChild(legacy)
		if e then e:Destroy() end
	end

	-- ── Clouds ─────────────────────────────────────────────────────────────
	-- Clouds only render when the instance is parented to workspace.Terrain.
	-- One left under Lighting — which is where the baseplate template puts it
	-- — logs "Cloud instance must exist under Terrain node in workspace to be
	-- visible" every time the place loads and then draws nothing at all.
	local clouds = workspace.Terrain:FindFirstChild("MythicClouds") :: Clouds?
	if not clouds then
		clouds = Instance.new("Clouds")
		clouds.Name = "MythicClouds"
	end
	clouds.Parent = workspace.Terrain
	-- Current engine builds expose Cover; older ones spelled it Coverage, and
	-- referencing a member that does not exist is a hard error here, so each is
	-- attempted separately.
	pcall(function() clouds.Cover = 0.5 end)
	pcall(function() clouds.Coverage = 0.5 end)
	clouds.Density = 0.35
	clouds.Color = Color3.fromRGB(228, 232, 240)


	-- ── Atmosphere ──────────────────────────────────────────────────────
	local atmo = ensure("Atmosphere", "MythicAtmosphere")
	atmo.Density = 0.25
	atmo.Offset = 0.15
	atmo.Color = Color3.fromRGB(220, 230, 245)
	atmo.Decay = Color3.fromRGB(80, 110, 160)
	atmo.Glare = 0.18
	atmo.Haze = 1.2

	-- ── Post-processing ─────────────────────────────────────────────────
	-- Bloom exists to make the big screens and technique VFX feel emissive.
	-- It is not a global smear.
	local bloom = ensure("BloomEffect", "MythicBloom")
	bloom.Intensity = 0.35
	bloom.Size = 22
	bloom.Threshold = 1.05

	local cc = ensure("ColorCorrectionEffect", "MythicGrade")
	cc.Brightness = 0.01
	cc.Contrast = 0.10
	cc.Saturation = 0.06
	cc.TintColor = Color3.fromRGB(246, 249, 255)
	setIfPresent(cc, "TintStrength", 0.06)

	if q.PostFX then
		local rays = ensure("SunRaysEffect", "MythicRays")
		if rays then
			rays.Intensity = 0.12
			rays.Spread = 0.6
		end
	else
		local rays = Lighting:FindFirstChild("MythicRays")
		if rays then rays:Destroy() end
	end

	-- Depth of field is deliberately never created: it blurred the stands and
	-- made the stadium read as a tabletop miniature.

	-- ── Sun ─────────────────────────────────────────────────────────────
	-- Explicit, so the shadow direction matches the sky instead of inheriting
	-- whatever the template happened to leave.
	local sun = ensure("DirectionalLight", "MythicSun")
	if sun and sun:IsA("DirectionalLight") then
		sun.Brightness = 2.4
		sun.Shadows = true
		sun.ShadowSoftness = 0.18
		sun.CFrame = CFrame.new(0, 140, 0) * CFrame.Angles(
			math.rad(-58), math.rad(24), 0)
	end

	print(string.format("[LightingService] Initialised. Quality=%s ClockTime=%.1f",
		LightingService.quality, Lighting.ClockTime))
end

-- ─────────────────────────────────────────────
-- Time of day presets
--
-- WeatherService previously wrote Lighting directly. It now calls this, so
-- there is exactly one code path that can change the time and exactly one
-- place that has to be correct.
-- ─────────────────────────────────────────────

LightingService.TIMES = {
	Clear = {
		clock = 13.5, brightness = 3.0,
		ambient = Color3.fromRGB(132, 140, 156),
		outdoor = Color3.fromRGB(160, 168, 184),
		bloom = 0.30, contrast = 0.04, rays = 0.14,
		skyTint = Color3.fromRGB(200, 220, 245),
		fog = nil,
	},
	Cloudy = {
		clock = 14.5, brightness = 2.5,
		ambient = Color3.fromRGB(126, 132, 146),
		outdoor = Color3.fromRGB(146, 152, 166),
		bloom = 0.32, contrast = 0.08, rays = 0.06,
		skyTint = Color3.fromRGB(175, 190, 210),
		fog = nil,
	},
	Evening = {
		clock = 18.2, brightness = 2.1,
		ambient = Color3.fromRGB(104, 104, 128),
		outdoor = Color3.fromRGB(126, 118, 126),
		bloom = 0.55, contrast = 0.14, rays = 0.22,
		skyTint = Color3.fromRGB(230, 190, 160),
		fog = nil,
	},
	Rain = {
		clock = 14.0, brightness = 1.9,
		ambient = Color3.fromRGB(96, 104, 118),
		outdoor = Color3.fromRGB(112, 120, 134),
		bloom = 0.45, contrast = 0.10, rays = 0.0,
		skyTint = Color3.fromRGB(140, 155, 175),
		fog = { 4, 90 },
	},
	Storm = {
		clock = 16.5, brightness = 1.3,
		ambient = Color3.fromRGB(70, 76, 96),
		outdoor = Color3.fromRGB(84, 90, 108),
		bloom = 0.60, contrast = 0.16, rays = 0.0,
		skyTint = Color3.fromRGB(100, 115, 140),
		fog = { 6, 70 },
	},
	Fog = {
		clock = 8.5, brightness = 2.2,
		ambient = Color3.fromRGB(150, 154, 160),
		outdoor = Color3.fromRGB(164, 168, 174),
		bloom = 0.40, contrast = 0.06, rays = 0.08,
		skyTint = Color3.fromRGB(195, 200, 210),
		fog = { 10, 40 },
	},
}

--- Point the sun at a plausible angle for the given hour and keep shadows long
--- enough to give the world depth without going night-dark.
local function applySunAngle(clock: number)
	local sun = Lighting:FindFirstChild("MythicSun")
	if not sun or not sun:IsA("DirectionalLight") then return end
	local hourAngle = (clock - 12) / 12 * math.pi
	sun.CFrame = CFrame.new(0, 140, 0) * CFrame.Angles(
		math.rad(-58) + hourAngle * 0.22,
		math.rad(24 + hourAngle * 18),
		0
	)
	sun.Brightness = math.clamp(2.6 - math.abs(hourAngle) * 0.7, 0.8, 2.6)
end
LightingService._applySunAngle = applySunAngle

function LightingService.SetTimeOfDay(name: string)
	local t = LightingService.TIMES[name]
	if not t then
		warn("[LightingService] Unknown time of day: " .. tostring(name))
		return
	end
	LightingService._timeOfDay = name

	Lighting.ClockTime = t.clock
	Lighting.Brightness = t.brightness
	Lighting.Ambient = t.ambient
	Lighting.OutdoorAmbient = t.outdoor

	local cc = Lighting:FindFirstChild("MythicGrade")
	if cc then cc.Contrast = t.contrast end
	local bloom = Lighting:FindFirstChild("MythicBloom")
	if bloom then bloom.Intensity = t.bloom end
	local rays = Lighting:FindFirstChild("MythicRays")
	if rays then rays.Intensity = t.rays end
	local sky = Lighting:FindFirstChild("MythicSky")
	if sky and sky:IsA("Sky") then setIfPresent(sky, "SkyTint", t.skyTint) end

	if t.fog then
		Lighting.FogStart = t.fog[1]
		Lighting.FogEnd = t.fog[2]
		Lighting.FogColor = Color3.fromRGB(150, 158, 172)
	else
		Lighting.FogStart = 6000
		Lighting.FogEnd = 100000
	end

	applySunAngle(t.clock)
end

function LightingService.GetTimeOfDay(): string
	return LightingService._timeOfDay
end

-- ─────────────────────────────────────────────
-- Quality
-- ─────────────────────────────────────────────

function LightingService.SetQuality(quality: string)
	local q = Palette.Quality[quality]
	if not q then
		warn("[LightingService] Unknown quality tier: " .. tostring(quality))
		return
	end
	LightingService.quality = quality
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = quality == "ULTRA" and 0.08 or 0.2
	local sun = Lighting:FindFirstChild("MythicSun")
	if sun then sun.Shadows = true end
	if not q.PostFX then
		local rays = Lighting:FindFirstChild("MythicRays")
		if rays then rays:Destroy() end
	end
	print("[LightingService] Quality set to " .. quality)
end

return LightingService

