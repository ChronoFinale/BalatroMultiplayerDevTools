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

-- Impersonation logs this instance in as an EXISTING player (real players
-- row), so it can queue matchmaking and appear on the leaderboard -- the way
-- a second game window acts as a different account without a second Steam
-- login. The identity is chosen by precedence:
--
--   1. BMP_IMPERSONATE_ID / BMP_IMPERSONATE_NAME env vars -- explicit
--      per-instance override, set before launching that instance.
--   2. The instance slot default below -- the first window launched claims
--      slot 1 and logs in as slot_defaults[1], the second window slot 2, ...
--      so two windows are two different players with zero setup.
--   3. Neither -> real Steam auth.
--
-- The in-client picker (impersonation_ui.lua) supersedes all of this at
-- runtime once used.
DEVTOOLS.slot_defaults = { 'Player001', 'Player002', 'Player003', 'Player004' }

local instance_slot = DEVTOOLS.load_file('instance_slot.lua')
-- Anchor the module -- and the bound socket it keeps in .held -- in the
-- global DEVTOOLS table. As a chunk-local it would be garbage-collected
-- once boot completes, and luasocket CLOSES a collected socket: the port
-- frees, and the next window launched claims the same slot again (both
-- windows logged in as Player001).
DEVTOOLS.instance_slot_lib = instance_slot
local socket_ok, socket = pcall(require, 'socket')
if socket_ok and socket then
	-- Raw socket.tcp(), NOT the socket.bind helper: the helper sets
	-- SO_REUSEADDR, which on Windows lets a second process bind an
	-- already-claimed port -- both windows would get slot 1.
	DEVTOOLS.instance_slot = instance_slot.acquire(45601, #DEVTOOLS.slot_defaults, function(host, port)
		local s = socket.tcp()
		local bound = s:bind(host, port)
		if not bound then
			s:close()
			return nil
		end
		s:listen(1)
		return s
	end)
end
DEVTOOLS.slot_default_name = instance_slot.pick_default(DEVTOOLS.instance_slot, DEVTOOLS.slot_defaults)

local imp_id = os.getenv('BMP_IMPERSONATE_ID')
local imp_name = os.getenv('BMP_IMPERSONATE_NAME')
local target = (imp_id and { playerId = imp_id })
	or (imp_name and { steamName = imp_name })
	or (DEVTOOLS.slot_default_name and { steamName = DEVTOOLS.slot_default_name })
if target then
	function connection._do_auth(self)
		self:_try_impersonate_auth(target)
	end
	MPAPI.sendDebugMessage(
		'Dev impersonation auth enabled for '
			.. tostring(imp_id or imp_name or DEVTOOLS.slot_default_name)
			.. (DEVTOOLS.instance_slot and (' (instance slot ' .. DEVTOOLS.instance_slot .. ')') or '')
	)
end

MPAPI.sendDebugMessage('DevTools auth overrides applied')

-- In-client runtime impersonation picker: lets a running instance switch which
-- account it's authenticated as from a menu, instead of only at boot via the
-- env vars above. The picker supersedes whatever the env vars set once used.
DEVTOOLS.load_file('impersonation_ui.lua')
