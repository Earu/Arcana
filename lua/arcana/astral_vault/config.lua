-- Astral Vault shared configuration: single source of truth for cost constants.
-- Included by both vault.lua (server) and ui.lua (client).
Arcana = Arcana or {}

Arcana.VaultConfig = {
	MAX_SLOTS = 6,
	STORE_COINS = 250000,
	STORE_SHARDS = 60,
	SUMMON_COINS = 10000,
	SUMMON_SHARDS = 5,
}
