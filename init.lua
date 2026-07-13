-- Multiplayer DevTools: a standalone SMODS mod, separate from MultiplayerAPI
-- itself, that holds dev-only account impersonation. It is NOT distributed
-- with API mod releases (see .github/workflows/strip-dev.yml) -- install/
-- enable this mod deliberately to get dev capability; the API mod is
-- otherwise identical for every user.
--
-- Load-order note: this mod declares a dependency on MultiplayerAPI above,
-- and MultiplayerAPI.json sets priority -1000000 so it loads essentially
-- first; SMODS loads mods in ascending-priority order, so by the time this
-- file runs (default priority 0), MultiplayerAPI's own core.lua --
-- including ui/main_menu.lua's MPAPI.account_button -- has already fully
-- loaded. That reproduces the timing the old dev/init.lua relied on (it ran
-- synchronously, in-mod, right after MPAPI.load_mpapi_dir('ui', true) in
-- core.lua) rather than the later, deferred MPAPI.on_loaded seam (which only
-- fires on a post-boot game Event) -- unneeded here since no game-runtime
-- state is required, just that the API mod's globals already exist.
DEVTOOLS = SMODS.current_mod

function DEVTOOLS.sendDebugMessage(msg)
	sendDebugMessage(msg, DEVTOOLS.id)
end

function DEVTOOLS.sendWarnMessage(msg)
	sendWarnMessage(msg, DEVTOOLS.id)
end

-- Mirrors MPAPI.load_mpapi_file (core.lua), scoped to this mod's own id/path
-- so files here load relative to devtools/, not the API mod's directory.
function DEVTOOLS.load_file(path)
	local chunk, err = SMODS.load_file(path, DEVTOOLS.id)
	if not chunk then
		DEVTOOLS.sendWarnMessage('Failed to find or compile file: ' .. tostring(err))
		return nil
	end
	local ok, result = pcall(chunk)
	if not ok then
		DEVTOOLS.sendWarnMessage('Failed to process file: ' .. tostring(result))
		return nil
	end
	return result
end

local connection = MPAPI.networking.connection

-- Logs in via an ephemeral dev/temp account (random in-memory player id, not
-- persisted to the DB). A temp account can never queue matchmaking or appear
-- on the leaderboard (no players row), so this is commented out to fall back
-- to real Steam auth. Uncomment to use a throwaway dev account instead.
-- function connection._do_auth(self)
-- 	self:_try_dev_auth()
-- end

-- Impersonation: log in as an EXISTING player (real players row), so it can
-- queue matchmaking and appear on the leaderboard. This lets a second game
-- instance act as a different real account without a second Steam login --
-- useful for testing matchmaking locally. Enable per-instance by setting one
-- of these env vars before launching that instance (the other instance, with
-- neither set, uses real Steam):
--   BMP_IMPERSONATE_ID=<players.id uuid>
--   BMP_IMPERSONATE_NAME=<steamName>      e.g. a seeded "Runner001"
local imp_id = os.getenv('BMP_IMPERSONATE_ID')
local imp_name = os.getenv('BMP_IMPERSONATE_NAME')
if imp_id or imp_name then
	local target = imp_id and { playerId = imp_id } or { steamName = imp_name }
	function connection._do_auth(self)
		self:_try_impersonate_auth(target)
	end
	MPAPI.sendDebugMessage('Dev impersonation auth enabled for ' .. tostring(imp_id or imp_name))
end

MPAPI.sendDebugMessage('DevTools auth overrides applied')

-- In-client runtime impersonation picker: lets a running instance switch which
-- account it's authenticated as from a menu, instead of only at boot via the
-- env vars above. The picker supersedes whatever the env vars set once used.
DEVTOOLS.load_file('impersonation_ui.lua')
