-- Multi-window instance slots for local dev.
--
-- Each running game instance claims the first free slot by binding a
-- localhost TCP port (base_port + slot - 1) and holding it for the process
-- lifetime: a port can only be bound once machine-wide, so concurrently
-- running windows always get distinct slots, and the OS releases the port
-- the moment the process exits or crashes -- no stale lock files.
--
-- devtools/init.lua maps the slot to a default impersonation identity
-- (slot 1 -> Player001, slot 2 -> Player002, ...) so launching two windows
-- just logs them in as two different seeded players with zero setup.
--
-- The decision logic is pure and the bind effect is injected, so everything
-- here is unit-testable without sockets -- see test_instance_slot.lua.

local M = {}

-- Which identity a freshly-acquired slot logs in as. `defaults` maps
-- slot -> steamName; a slot past the end of the list (a 5th window) or a
-- blank name means no default (fall through to real Steam auth). Explicit
-- BMP_IMPERSONATE_* env vars beat the slot default -- that precedence is
-- decided in devtools/init.lua, not here.
function M.pick_default(slot, defaults)
	if not slot or not defaults then
		return nil
	end
	local name = defaults[slot]
	if name == nil or name == '' then
		return nil
	end
	return name
end

-- Claim the first free slot in [1, max_slots]. `bind(host, port)` performs
-- the real port bind: it must return a handle on success or nil on failure,
-- and MUST NOT set SO_REUSEADDR (luasocket's socket.bind convenience helper
-- does, and on Windows that lets two processes bind the same port -- both
-- windows would get slot 1; use a raw socket.tcp() instead, see init.lua).
-- The winning handle is kept in M.held so the port stays claimed for the
-- process lifetime. Returns the slot number, or nil if every slot is taken.
function M.acquire(base_port, max_slots, bind)
	for slot = 1, max_slots do
		local ok, handle = pcall(bind, '127.0.0.1', base_port + slot - 1)
		if ok and handle then
			M.held = handle
			return slot
		end
	end
	return nil
end

return M
