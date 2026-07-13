-- Standalone unit tests for devtools/impersonation.lua's pure decision
-- functions (target parsing, prefill priority, feedback state machine) that
-- power devtools/impersonation_ui.lua's runtime account-impersonation picker.
--
-- The module under test has no MPAPI/G/love dependencies, so it's loaded
-- directly (loadstring) with no fake environment needed.
--
-- Run: luajit test_impersonation.lua

local this_dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
local SRC_PATH = this_dir .. 'impersonation.lua'

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local content = f:read('*a')
	f:close()
	return content
end

local function load_module(source)
	local chunk = assert(loadstring(source, 'impersonation'))
	return chunk()
end

local M = load_module(read_file(SRC_PATH))

local failures = 0
local function check(cond, msg)
	if cond then
		print('PASS: ' .. msg)
	else
		failures = failures + 1
		print('FAIL: ' .. msg)
	end
end

------------------------
-- parse_target: name vs uuid detection
------------------------

print('-- parse_target --')

do
	local target, err = M.parse_target('Player001')
	check(target ~= nil and target.steamName == 'Player001' and target.playerId == nil, 'plain name -> steamName target')
	check(err == nil, 'plain name -> no error')
end

do
	local uuid = 'a1b2c3d4-e5f6-4789-abcd-ef0123456789'
	local target, err = M.parse_target(uuid)
	check(target ~= nil and target.playerId == uuid and target.steamName == nil, 'uuid-shaped input -> playerId target')
	check(err == nil, 'uuid input -> no error')
end

do
	-- Uppercase hex and surrounding whitespace should still be recognized/trimmed.
	local target = M.parse_target('  A1B2C3D4-E5F6-4789-ABCD-EF0123456789  ')
	check(target ~= nil and target.playerId == 'A1B2C3D4-E5F6-4789-ABCD-EF0123456789', 'uppercase uuid + whitespace trimmed -> playerId target')
end

do
	-- Failure path: blank / whitespace-only input must produce a genuine error,
	-- not a silently-empty target that would hit the impersonate endpoint
	-- with {} (which the server would likely reject anyway, but with a much
	-- less useful message than catching it client-side first).
	local target, err = M.parse_target('   ')
	check(target == nil, 'blank input -> no target')
	check(err ~= nil and #err > 0, 'blank input -> error message present')
end

do
	local target, err = M.parse_target(nil)
	check(target == nil and err ~= nil, 'nil input -> no target, error present')
end

do
	-- Near-miss uuid shapes (wrong segment lengths / non-hex chars) must fall
	-- back to steamName, not be misparsed as a playerId.
	local target = M.parse_target('not-a-uuid-at-all')
	check(target.steamName == 'not-a-uuid-at-all' and target.playerId == nil, 'near-uuid-shaped junk -> steamName fallback')
end

------------------------
-- resolve_prefill: session-last > env id > env name > empty
------------------------

print()
print('-- resolve_prefill --')

check(M.resolve_prefill('LastUsed', 'env-id', 'EnvName') == 'LastUsed', 'session last used wins over env vars')
check(M.resolve_prefill(nil, 'env-id', 'EnvName') == 'env-id', 'env id wins over env name when no session value')
check(M.resolve_prefill('', 'env-id', 'EnvName') == 'env-id', 'empty-string session value treated as absent')
check(M.resolve_prefill(nil, nil, 'EnvName') == 'EnvName', 'env name used when no session value or env id')
check(M.resolve_prefill(nil, nil, nil) == '', 'no session/env values -> empty prefill')

------------------------
-- next_feedback: picker state machine
------------------------

print()
print('-- next_feedback --')

do
	local s = M.next_feedback({ pending = false }, { kind = 'login_started' })
	check(s.pending == true and s.message == 'Logging in...', 'login_started -> pending state')
end

do
	local pending = { pending = true, message = 'Logging in...' }
	local s = M.next_feedback(pending, { kind = 'connected', identity = 'Player002' })
	check(s.pending == false and s.ok == true and s.message:find('Player002', 1, true) ~= nil, 'connected while pending -> success state names the identity')
end

do
	-- Failure path: a disconnect-with-error while pending must resolve to a
	-- visible failure state. This is the "fail gracefully, not crash" guard
	-- rail for production servers where the impersonate endpoint 404s.
	local pending = { pending = true, message = 'Logging in...' }
	local s = M.next_feedback(pending, { kind = 'disconnected', error = 'Impersonation auth failed: 404' })
	check(s.pending == false and s.ok == false and s.message == 'Impersonation auth failed: 404', 'disconnected-with-error while pending -> failure state carries the error message')
end

do
	-- Connection churn NOT initiated by the picker (not pending) must be
	-- ignored, so e.g. the initial boot-time connect doesn't flash a stale
	-- "Logged in as ..." banner the user never asked for.
	local idle = { pending = false, message = nil, ok = nil }
	local s = M.next_feedback(idle, { kind = 'connected', identity = 'SomeoneElse' })
	check(s.pending == false and s.message == nil and s.ok == nil, 'connected while NOT pending -> ignored, no stale banner')
end

do
	-- RED verification (control): this module is wholly new, so there's no
	-- pre-fix source to diff against. Instead, prove the pending-guard above
	-- actually matters by running the same event through a naive state
	-- machine that lacks it -- it WOULD show a stale banner, which is exactly
	-- the bug the guard in M.next_feedback prevents.
	local function broken_next_feedback(status, event)
		if event.kind == 'login_started' then
			return { pending = true, message = 'Logging in...', ok = nil }
		elseif event.kind == 'connected' then
			return { pending = false, message = 'Logged in as ' .. tostring(event.identity), ok = true }
		elseif event.kind == 'disconnected' then
			return { pending = false, message = event.error or 'Login failed', ok = false }
		end
		return status
	end
	local idle = { pending = false, message = nil, ok = nil }
	local broken = broken_next_feedback(idle, { kind = 'connected', identity = 'SomeoneElse' })
	check(broken.message == 'Logged in as SomeoneElse', '(control) broken state machine without the pending-guard WOULD show a stale banner -- proves the guard in M.next_feedback matters')
end

------------------------
-- server_warning
------------------------

print()
print('-- server_warning --')

check(M.server_warning(true) == nil, 'use_custom_server on -> no warning')
check(M.server_warning(false) ~= nil, 'use_custom_server off -> warning text present')
check(M.server_warning(nil) ~= nil, 'use_custom_server unset (nil) -> warning text present')

------------------------

print()
if failures == 0 then
	print('ALL TESTS PASSED')
	os.exit(0)
else
	print(failures .. ' TEST(S) FAILED')
	os.exit(1)
end
