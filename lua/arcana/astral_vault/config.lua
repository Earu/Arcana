-- Astral Vault shared configuration — single source of truth for cost constants.
-- Included by both astral_vault.lua (server) and astral_vault_ui.lua (client).
Arcana = Arcana or {}

Arcana.VaultConfig = {
	MAX_SLOTS = 6,
	STORE_COINS = 250000,
	STORE_SHARDS = 60,
	SUMMON_COINS = 10000,
	SUMMON_SHARDS = 5,
}
