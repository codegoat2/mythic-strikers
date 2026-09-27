--[[
	MythicStrikers — ClientAssetRegistry
	Client-side wrapper for AssetRegistry functions.

	Provides SpawnVFX and PlaySFX from a client-accessible module so
	controllers do not need to know the shared config path.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetRegistry = require(ReplicatedStorage.Shared.Config.AssetRegistry)

local ClientAssetRegistry = {}

function ClientAssetRegistry.SpawnVFX(key: string, position: Vector3, parent: Instance?): Instance?
	return AssetRegistry.SpawnVFX(key, position, parent)
end

function ClientAssetRegistry.PlaySFX(key: string, position: Vector3, volume: number?): Sound?
	return AssetRegistry.PlaySFX(key, position, volume)
end

return ClientAssetRegistry
