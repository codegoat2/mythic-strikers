--[[
	MythicStrikers — ShopService
	Server-authoritative shop catalogue, purchase validation, and inventory management.

	SHOP TYPES:
	  TechniqueShop — unlock technique visual effects / alternate animations
	  GearShop      — cosmetic boots, gloves, ball skins
	  AuraShop      — awakening aura styles and colours
	  LockerRoom    — equip techniques from owned library (free action)

	SECURITY:
	  • All coin deductions happen server-side via PlayerService.
	  • Clients send a purchase request with item ID only.
	  • Server validates: player has enough coins, item exists, not already owned.
	  • Never trust coin count from client.
	  • MarketplaceService integration stub provided for Robux items (Phase 9).

	CATALOGUE FORMAT:
	  Each item: { Id, Name, ShopType, Price, Currency, Description, Tier, Tags }
	  Currency: "Coins" (in-game) | "Robux" (Phase 9 stub)
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants   = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes     = require(ReplicatedStorage.Remotes)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local ShopService = {}

-- Injected at Init
local _playerService = nil

-- ─────────────────────────────────────────────
-- CATALOGUE
-- ─────────────────────────────────────────────
-- Items are pure data — no asset IDs yet (wired in Phase 9).
-- Tags are used by ShopUI to filter by category.

local CATALOGUE = {

	-- ── TECHNIQUE SHOP ──────────────────────────────────────────────
	{
		Id          = "TECH_VFX_SOLAR_GOLD",
		Name        = "Golden Solar Fang",
		ShopType    = "TechniqueShop",
		Price       = 120,
		Currency    = "Coins",
		Description = "Replaces Solar Fang's flame with radiant gold fire.",
		Tier        = "Rare",
		Tags        = { "Technique", "VFX", "Fire" },
		PreviewVFX  = "VFX_SolarFang_Gold",
	},
	{
		Id          = "TECH_VFX_THUNDER_VIOLET",
		Name        = "Violet Thunder Comet",
		ShopType    = "TechniqueShop",
		Price       = 120,
		Currency    = "Coins",
		Description = "Thunder Comet crackles with deep violet lightning.",
		Tier        = "Rare",
		Tags        = { "Technique", "VFX", "Lightning" },
		PreviewVFX  = "VFX_ThunderComet_Violet",
	},
	{
		Id          = "TECH_VFX_VOID_CRIMSON",
		Name        = "Crimson Void Cannon",
		ShopType    = "TechniqueShop",
		Price       = 300,
		Currency    = "Coins",
		Description = "Void Cannon becomes a bloodred singularity.",
		Tier        = "Epic",
		Tags        = { "Technique", "VFX", "Void" },
		PreviewVFX  = "VFX_VoidCannon_Crimson",
	},
	{
		Id          = "TECH_VFX_CELESTIAL_RAINBOW",
		Name        = "Rainbow Celestial Break",
		ShopType    = "TechniqueShop",
		Price       = 500,
		Currency    = "Coins",
		Description = "Celestial Break explodes in a spectrum of prismatic light.",
		Tier        = "Legendary",
		Tags        = { "Technique", "VFX", "Light" },
		PreviewVFX  = "VFX_CelestialBreak_Rainbow",
	},
	{
		Id          = "TECH_VFX_PHANTOM_SHADOW",
		Name        = "Shadow Phantom Dash",
		ShopType    = "TechniqueShop",
		Price       = 80,
		Currency    = "Coins",
		Description = "Phantom Dash leaves a dark smoke trail.",
		Tier        = "Common",
		Tags        = { "Technique", "VFX", "Shadow" },
		PreviewVFX  = "VFX_PhantomDash_Shadow",
	},
	{
		Id          = "TECH_VFX_COSMIC_NOVA",
		Name        = "Cosmic Nova Pack",
		ShopType    = "TechniqueShop",
		Price       = 800,
		Currency    = "Coins",
		Description = "Replaces all Cosmic techniques with a galaxy-effect VFX.",
		Tier        = "Mythic",
		Tags        = { "Technique", "VFX", "Cosmic" },
		PreviewVFX  = "VFX_Cosmic_GalaxyPack",
	},

	-- ── GEAR SHOP ───────────────────────────────────────────────────
	{
		Id          = "GEAR_BOOTS_INFERNO",
		Name        = "Inferno Boots",
		ShopType    = "GearShop",
		Price       = 150,
		Currency    = "Coins",
		Description = "Boots that leave a trail of embers when sprinting.",
		Tier        = "Rare",
		Tags        = { "Gear", "Boots", "Fire" },
	},
	{
		Id          = "GEAR_BOOTS_THUNDER",
		Name        = "Thunder Cleats",
		ShopType    = "GearShop",
		Price       = 150,
		Currency    = "Coins",
		Description = "Electrified cleats that spark with every step.",
		Tier        = "Rare",
		Tags        = { "Gear", "Boots", "Lightning" },
	},
	{
		Id          = "GEAR_BOOTS_VOID",
		Name        = "Void Treads",
		ShopType    = "GearShop",
		Price       = 350,
		Currency    = "Coins",
		Description = "Dark boots that phase between shadows.",
		Tier        = "Epic",
		Tags        = { "Gear", "Boots", "Void" },
	},
	{
		Id          = "GEAR_BALL_SOLAR",
		Name        = "Solar Ball Skin",
		ShopType    = "GearShop",
		Price       = 200,
		Currency    = "Coins",
		Description = "The ball glows like a miniature sun.",
		Tier        = "Rare",
		Tags        = { "Gear", "Ball", "Fire" },
	},
	{
		Id          = "GEAR_BALL_COSMIC",
		Name        = "Cosmic Ball Skin",
		ShopType    = "GearShop",
		Price       = 600,
		Currency    = "Coins",
		Description = "A galaxy swirls inside the ball.",
		Tier        = "Legendary",
		Tags        = { "Gear", "Ball", "Cosmic" },
	},
	{
		Id          = "GEAR_GLOVES_TITAN",
		Name        = "Titan Gloves",
		ShopType    = "GearShop",
		Price       = 120,
		Currency    = "Coins",
		Description = "Stone-reinforced goalkeeper gloves.",
		Tier        = "Common",
		Tags        = { "Gear", "Gloves", "Earth" },
	},
	{
		Id          = "GEAR_GLOVES_CELESTIAL",
		Name        = "Celestial Gloves",
		ShopType    = "GearShop",
		Price       = 450,
		Currency    = "Coins",
		Description = "Radiant light gloves used by legendary goalkeepers.",
		Tier        = "Epic",
		Tags        = { "Gear", "Gloves", "Light" },
	},

	-- ── AURA SHOP ───────────────────────────────────────────────────
	{
		Id          = "AURA_FIRE_STANDARD",
		Name        = "Blaze Aura",
		ShopType    = "AuraShop",
		Price       = 200,
		Currency    = "Coins",
		Description = "Surrounded by rising fire during Awakening.",
		Tier        = "Rare",
		Tags        = { "Aura", "Fire" },
	},
	{
		Id          = "AURA_LIGHTNING_STANDARD",
		Name        = "Storm Aura",
		ShopType    = "AuraShop",
		Price       = 200,
		Currency    = "Coins",
		Description = "Lightning arcs across your body during Awakening.",
		Tier        = "Rare",
		Tags        = { "Aura", "Lightning" },
	},
	{
		Id          = "AURA_SHADOW_DARK",
		Name        = "Shadow Shroud",
		ShopType    = "AuraShop",
		Price       = 300,
		Currency    = "Coins",
		Description = "Dark tendrils wrap around you during Awakening.",
		Tier        = "Epic",
		Tags        = { "Aura", "Shadow" },
	},
	{
		Id          = "AURA_COSMIC_GALAXY",
		Name        = "Galaxy Aura",
		ShopType    = "AuraShop",
		Price       = 750,
		Currency    = "Coins",
		Description = "A nebula of stars orbits you during Awakening.",
		Tier        = "Legendary",
		Tags        = { "Aura", "Cosmic" },
	},
	{
		Id          = "AURA_MYTHIC_RAINBOW",
		Name        = "Prismatic Aura",
		ShopType    = "AuraShop",
		Price       = 1200,
		Currency    = "Coins",
		Description = "All elements merge into a rainbow of power.",
		Tier        = "Mythic",
		Tags        = { "Aura", "Cosmic", "Light" },
	},

	-- ── LOCKER ROOM (free unlocks — EquipAction instead of purchase) ─
	-- These use Price = 0 and are handled as equip actions, not purchases.
	{
		Id          = "LOADOUT_SLOT_EXPAND",
		Name        = "Extra Technique Slot",
		ShopType    = "LockerRoom",
		Price       = 500,
		Currency    = "Coins",
		Description = "Adds a 5th technique slot to your loadout.",
		Tier        = "Epic",
		Tags        = { "Loadout" },
	},

	-- ── GOAL CELEBRATIONS (bonus cosmetic category) ──────────────────
	{
		Id          = "CELE_POWERPOSE",
		Name        = "Power Pose",
		ShopType    = "GearShop",
		Price       = 60,
		Currency    = "Coins",
		Description = "Strike a dramatic pose after scoring.",
		Tier        = "Common",
		Tags        = { "Celebration" },
	},
	{
		Id          = "CELE_THUNDER_DANCE",
		Name        = "Thunder Dance",
		ShopType    = "GearShop",
		Price       = 180,
		Currency    = "Coins",
		Description = "Electrified celebration dance after a goal.",
		Tier        = "Rare",
		Tags        = { "Celebration" },
	},
	{
		Id          = "CELE_COSMIC_BURST",
		Name        = "Cosmic Burst",
		ShopType    = "GearShop",
		Price       = 400,
		Currency    = "Coins",
		Description = "Explode in a supernova of cosmic energy when you score.",
		Tier        = "Epic",
		Tags        = { "Celebration" },
	},
}

-- ─────────────────────────────────────────────
-- Build catalogue lookup
-- ─────────────────────────────────────────────
local _catalogueMap: { [string]: table } = {}
for _, item in ipairs(CATALOGUE) do
	_catalogueMap[item.Id] = item
end

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function getOwnedItems(player: Player): { [string]: boolean }
	local profile = _playerService and _playerService.GetProfile(player)
	if not profile then return {} end
	local owned: { [string]: boolean } = {}
	if profile.Cosmetics then
		for id, _ in pairs(profile.Cosmetics) do
			owned[id] = true
		end
	end
	return owned
end

local function isOwned(player: Player, itemId: string): boolean
	return getOwnedItems(player)[itemId] == true
end

local function getCoinBalance(player: Player): number
	local profile = _playerService and _playerService.GetProfile(player)
	return profile and profile.Coins or 0
end

-- ─────────────────────────────────────────────
-- Remote handlers
-- ─────────────────────────────────────────────

local function onShopPurchase(player: Player, payload: table)
	if typeof(payload) ~= "table" then return end

	local itemId = payload.ItemId
	if typeof(itemId) ~= "string" or #itemId == 0 then
		Remotes.FireClient(Constants.Remotes.ShopPurchaseResult, player, {
			Success = false,
			Reason  = "Invalid item ID.",
		})
		return
	end

	local item = _catalogueMap[itemId]
	if not item then
		Remotes.FireClient(Constants.Remotes.ShopPurchaseResult, player, {
			Success = false,
			Reason  = "Item not found.",
		})
		return
	end

	-- Already owned?
	if isOwned(player, itemId) then
		Remotes.FireClient(Constants.Remotes.ShopPurchaseResult, player, {
			Success = false,
			Reason  = "You already own this item.",
		})
		return
	end

	-- Robux items — stub for Phase 9
	if item.Currency == "Robux" then
		Remotes.FireClient(Constants.Remotes.ShopPurchaseResult, player, {
			Success = false,
			Reason  = "Robux purchases coming in Phase 9.",
		})
		return
	end

	-- Coin check
	local balance = getCoinBalance(player)
	if balance < item.Price then
		Remotes.FireClient(Constants.Remotes.ShopPurchaseResult, player, {
			Success = false,
			Reason  = string.format("Not enough coins. Need %d, have %d.", item.Price, balance),
		})
		return
	end

	-- Deduct coins via PlayerService (server-authoritative)
	if _playerService then
		_playerService.GrantRewards(player, { Coins = -item.Price })

		-- Grant item to cosmetics table in profile
		local profile = _playerService.GetProfile(player)
		if profile then
			profile.Cosmetics = profile.Cosmetics or {}
			profile.Cosmetics[itemId] = item.Name
		end
	end

	print(string.format(
		"[ShopService] %s purchased '%s' for %d coins.",
		player.DisplayName, item.Name, item.Price
	))

	-- Confirm to client
	Remotes.FireClient(Constants.Remotes.ShopPurchaseResult, player, {
		Success    = true,
		ItemId     = itemId,
		ItemName   = item.Name,
		CoinsSpent = item.Price,
		NewBalance = getCoinBalance(player),
	})
end

--- Client opens a shop — server sends them the filtered catalogue.
local function onOpenShop(player: Player, payload: table)
	if typeof(payload) ~= "table" then return end

	local shopType = payload.ShopType
	if typeof(shopType) ~= "string" then return end

	-- Build filtered catalogue with ownership flags
	local owned    = getOwnedItems(player)
	local balance  = getCoinBalance(player)
	local filtered = {}

	for _, item in ipairs(CATALOGUE) do
		if item.ShopType == shopType then
			table.insert(filtered, {
				Id          = item.Id,
				Name        = item.Name,
				Price       = item.Price,
				Currency    = item.Currency,
				Description = item.Description,
				Tier        = item.Tier,
				Tags        = item.Tags,
				Owned       = owned[item.Id] == true,
				CanAfford   = balance >= item.Price,
			})
		end
	end

	Remotes.FireClient(Constants.Remotes.ShopCatalogueUpdate, player, {
		ShopType  = shopType,
		Items     = filtered,
		Balance   = balance,
	})
end

-- ─────────────────────────────────────────────
-- Daily bonus
-- ─────────────────────────────────────────────

local DAILY_KEY = "DailyBonus_"

local function grantDailyBonus(player: Player)
	if not _playerService then return end
	local profile = _playerService.GetProfile(player)
	if not profile then return end

	local today = os.date("%Y-%m-%d")  -- "2026-09-25" style key
	local key   = DAILY_KEY .. today

	-- Check if already claimed today
	if profile.Statistics and profile.Statistics[key] then return end

	-- Grant
	_playerService.GrantRewards(player, { Coins = Constants.DAILY_COIN_BONUS })

	-- Record
	profile.Statistics = profile.Statistics or {}
	profile.Statistics[key] = 1

	Remotes.FireClient(Constants.Remotes.NotifyPlayer, player, {
		Type    = "DailyBonus",
		Message = string.format("Daily bonus: +%d Coins!", Constants.DAILY_COIN_BONUS),
	})

	print(string.format("[ShopService] Daily bonus granted to %s (+%d coins).",
		player.DisplayName, Constants.DAILY_COIN_BONUS))
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function ShopService.Init(playerService)
	_playerService = playerService

	-- Remote listeners
	Remotes.OnServerEvent(Constants.Remotes.ShopPurchase, onShopPurchase)
	Remotes.OnServerEvent(Constants.Remotes.OpenShop,     onOpenShop)

	-- Daily bonus on join (after profile loads)
	Players.PlayerAdded:Connect(function(player)
		-- Wait for profile to be available
		task.delay(3, function()
			grantDailyBonus(player)
		end)
	end)

	-- Also handle players already present (Studio test)
	for _, player in ipairs(Players:GetPlayers()) do
		task.delay(3, function()
			grantDailyBonus(player)
		end)
	end

	print(string.format(
		"[ShopService] Initialised — %d items in catalogue.",
		#CATALOGUE
	))
end

--- Returns the full catalogue (for admin / testing).
function ShopService.GetCatalogue(): { table }
	return CATALOGUE
end

--- Returns a single item definition by ID.
function ShopService.GetItem(itemId: string): table?
	return _catalogueMap[itemId]
end

--- Returns whether a player owns a specific item.
function ShopService.PlayerOwns(player: Player, itemId: string): boolean
	return isOwned(player, itemId)
end

return ShopService
