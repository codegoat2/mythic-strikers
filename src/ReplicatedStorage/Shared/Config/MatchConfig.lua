--[[
	MythicStrikers — MatchConfig
	Per-mode match configuration tables.
	Consumed by MatchService and MatchmakingService.
--]]

local Constants = require(script.Parent.Constants)

local MatchConfig = {}

-- Each entry is a Types.MatchConfig shape
MatchConfig.Modes = {

	["1v1"] = {
		Mode          = "1v1",
		Duration      = 120,    -- 2 min halves
		HalfTime      = 8,
		MaxPlayers    = 2,
		CountdownSec  = 5,
		TeamSize      = 1,
		AllowedTechs  = { "Basic", "Advanced" },
		EnergyMult    = 1.0,
		StaminaMult   = 1.0,
	},

	["3v3"] = {
		Mode          = "3v3",
		Duration      = 150,
		HalfTime      = 10,
		MaxPlayers    = 6,
		CountdownSec  = 5,
		TeamSize      = 3,
		AllowedTechs  = { "Basic", "Advanced", "Ultimate" },
		EnergyMult    = 1.0,
		StaminaMult   = 1.0,
	},

	["5v5"] = {
		Mode          = "5v5",
		Duration      = Constants.MATCH_HALF_DURATION,  -- 180 seconds
		HalfTime      = Constants.MATCH_HALF_TIME_DUR,
		MaxPlayers    = 10,
		CountdownSec  = Constants.MATCH_COUNTDOWN,
		TeamSize      = 5,
		AllowedTechs  = { "Basic", "Advanced", "Ultimate", "Mythic" },
		EnergyMult    = 1.0,
		StaminaMult   = 1.0,
		-- The only playable mode in Update 1.0.
		Available     = true,
	},

	-- ─────────────────────────────────────────────
	-- Future content.
	-- Announced to the player, never playable. There is deliberately no
	-- half-built matchmaking behind these: Available = false makes
	-- MatchConfig.IsAvailable return false, and StartMatch refuses them.
	-- ─────────────────────────────────────────────
	["7v7"] = {
		Mode          = "7v7",
		Duration      = 210,
		HalfTime      = 15,
		MaxPlayers    = 14,
		CountdownSec  = 5,
		TeamSize      = 7,
		AllowedTechs  = { "Basic", "Advanced", "Ultimate", "Mythic" },
		EnergyMult    = 1.0,
		StaminaMult   = 0.95,
		Available     = false,
		Status        = "COMING SOON",
	},

	["8v8"] = {
		Mode          = "8v8",
		Duration      = 220,
		HalfTime      = 15,
		MaxPlayers    = 16,
		CountdownSec  = 5,
		TeamSize      = 8,
		AllowedTechs  = { "Basic", "Advanced", "Ultimate", "Mythic" },
		EnergyMult    = 1.0,
		StaminaMult   = 0.9,
		Available     = false,
		Status        = "COMING SOON",
	},

	["6v6"] = {
		Mode          = "6v6",
		Duration      = 200,
		HalfTime      = 15,
		MaxPlayers    = 12,
		CountdownSec  = 5,
		TeamSize      = 6,
		AllowedTechs  = { "Basic", "Advanced", "Ultimate", "Mythic" },
		EnergyMult    = 1.1,
		StaminaMult   = 0.9,   -- slightly more stamina pressure in bigger games
	},

	["Training"] = {
		Mode          = "Training",
		Duration      = math.huge,
		HalfTime      = 0,
		MaxPlayers    = 1,
		CountdownSec  = 0,
		TeamSize      = 1,
		AllowedTechs  = { "Basic", "Advanced", "Ultimate", "Mythic" },
		EnergyMult    = 99,   -- effectively unlimited energy
		StaminaMult   = 99,
	},
}

--- Returns the config for a given mode, or 5v5 as fallback.
function MatchConfig.Get(mode: string)
	return MatchConfig.Modes[mode] or MatchConfig.Modes["5v5"]
end

--- Returns true when a mode can actually be started. Modes marked
--- Available = false are announced to the player as future content and must
--- never reach StartMatch. This is the single gate that keeps a half-built
--- mode from being queued by a modified client.
function MatchConfig.IsAvailable(mode: string): boolean
	local entry = MatchConfig.Modes[mode]
	return entry ~= nil and entry.Available == true
end

--- Ordered list for the mode-select UI, including locked entries so the
--- player can see what is coming without any of it being wired up.
--- Each row carries everything the UI needs; no server logic is exposed.
function MatchConfig.GetModeList(): { table }
	local order = { "5v5", "7v7", "8v8" }
	local list = {}
	for _, mode in ipairs(order) do
		local entry = MatchConfig.Modes[mode]
		if entry then
			table.insert(list, {
				Id        = mode,
				Label     = string.format("%d v %d", entry.TeamSize, entry.TeamSize),
				TeamSize  = entry.TeamSize,
				Available = entry.Available == true,
				Status    = (entry.Available == true) and "AVAILABLE" or "COMING SOON",
			})
		end
	end
	return list
end

return MatchConfig
