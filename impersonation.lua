-- Pure decision functions for the DevTools in-client impersonation picker
-- (devtools/impersonation_ui.lua). Zero dependencies on MPAPI/G/love/network
-- so these can be unit-tested standalone -- see devtools/test_impersonation.lua.
--
-- devtools/ is a standalone SMODS mod, separate from the MultiplayerAPI mod,
-- and is not distributed with API releases -- see .github/workflows/strip-dev.yml.

local M = {}

-- UUID shape check: 8-4-4-4-12 hex, matching the players.id uuid column.
-- Anything else is treated as a steamName lookup.
local UUID_PATTERN = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'

-- Builds the { playerId = ... } / { steamName = ... } target table expected by
-- connection:_try_impersonate_auth / api_client:authenticate_impersonate from
-- raw picker input (typed text or a quick-select seed name). Returns nil plus
-- an error message for blank input, so the caller can show a message instead
-- of firing a request with an empty body.
function M.parse_target(raw_input)
	local trimmed = (raw_input or ''):match('^%s*(.-)%s*$') or ''
	if trimmed == '' then
		return nil, 'Enter a player name or ID'
	end
	if trimmed:match(UUID_PATTERN) then
		return { playerId = trimmed }, nil
	end
	return { steamName = trimmed }, nil
end

-- Priority for the text input's initial value: whatever was last typed/used
-- this client session > the BMP_IMPERSONATE_* env var devtools/init.lua
-- applied at boot (id takes precedence over name, mirroring devtools/init.lua's
-- own precedence) > empty. An empty string is treated the same as nil/absent.
function M.resolve_prefill(session_last, env_id, env_name)
	if session_last and session_last ~= '' then
		return session_last
	end
	if env_id and env_id ~= '' then
		return env_id
	end
	if env_name and env_name ~= '' then
		return env_name
	end
	return ''
end

-- State machine for the picker's feedback banner. `status` is
-- { pending = bool, message = string|nil, ok = bool|nil }. `event` is one of:
--   { kind = 'login_started' }
--   { kind = 'connected', identity = string }
--   { kind = 'disconnected', error = string|nil }
-- Connection-lifecycle churn the picker didn't itself initiate (e.g. the
-- initial boot-time connect, or an unrelated later reconnect) is ignored by
-- requiring `pending` before a connected/disconnected event can resolve the
-- banner -- otherwise the overlay would flash a stale result for events it
-- never asked about.
function M.next_feedback(status, event)
	status = status or { pending = false, message = nil, ok = nil }

	if event.kind == 'login_started' then
		return { pending = true, message = 'Logging in...', ok = nil }
	end

	if not status.pending then
		return status
	end

	if event.kind == 'connected' then
		return { pending = false, message = 'Logged in as ' .. tostring(event.identity), ok = true }
	elseif event.kind == 'disconnected' then
		return { pending = false, message = event.error or 'Login failed', ok = false }
	end

	return status
end

-- The impersonate endpoint only exists on the dev server (404s in
-- production), so surface a heads-up in the overlay when the client isn't
-- pointed at one -- the login attempt will still fail gracefully via
-- next_feedback's disconnected/error branch, this is just an earlier hint.
function M.server_warning(use_custom_server)
	if use_custom_server then
		return nil
	end
	return 'Requires the local dev server (use_custom_server) -- will fail against production'
end

return M
