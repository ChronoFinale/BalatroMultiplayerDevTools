-- Standalone unit tests for devtools/instance_slot.lua: slot acquisition via
-- an injected bind effect (real fake, no sockets) and the slot -> default
-- identity decision. Run: luajit test_instance_slot.lua

local this_dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'

local function load_module(path)
	local f = assert(io.open(path, 'r'))
	local content = f:read('*a')
	f:close()
	local chunk = assert(loadstring(content, path))
	return chunk()
end

local failures = 0
local function check(cond, msg)
	if cond then
		print('PASS: ' .. msg)
	else
		failures = failures + 1
		print('FAIL: ' .. msg)
	end
end

-- Fake bind: a set of already-taken ports; binding a free port returns a
-- handle table and marks it taken (mirroring the OS-level mutual exclusion).
local function make_fake_os(taken)
	taken = taken or {}
	return function(host, port)
		if host ~= '127.0.0.1' then
			error('bound wrong host: ' .. tostring(host))
		end
		if taken[port] then
			return nil
		end
		taken[port] = true
		return { port = port }
	end, taken
end

local DEFAULTS = { 'Player001', 'Player002', 'Player003', 'Player004' }

print('-- acquire --')

do
	-- First window on an idle machine claims slot 1 and holds its port.
	local M = load_module(this_dir .. 'instance_slot.lua')
	local bind = make_fake_os()
	check(M.acquire(45601, 4, bind) == 1, 'first instance claims slot 1')
	check(M.held ~= nil and M.held.port == 45601, 'winning handle is held for the process lifetime')
end

do
	-- Second window: slot 1's port is taken, so it claims slot 2 -- the whole
	-- point of the feature (two windows -> two different players).
	local M = load_module(this_dir .. 'instance_slot.lua')
	local bind = make_fake_os({ [45601] = true })
	check(M.acquire(45601, 4, bind) == 2, 'second instance claims slot 2')
end

do
	-- Fifth window with only four slots: every port taken -> nil (real Steam).
	local M = load_module(this_dir .. 'instance_slot.lua')
	local bind = make_fake_os({ [45601] = true, [45602] = true, [45603] = true, [45604] = true })
	check(M.acquire(45601, 4, bind) == nil, 'all slots taken -> nil')
	check(M.held == nil, 'no handle held when nothing was acquired')
end

do
	-- A bind that THROWS (socket library quirk) must be treated as slot-taken,
	-- not crash the boot path.
	local M = load_module(this_dir .. 'instance_slot.lua')
	local calls = 0
	local slot = M.acquire(45601, 2, function(host, port)
		calls = calls + 1
		if port == 45601 then
			error('boom')
		end
		return { port = port }
	end)
	check(slot == 2 and calls == 2, 'throwing bind is treated as slot-taken, next slot tried')
end

print()
print('-- pick_default --')

do
	local M = load_module(this_dir .. 'instance_slot.lua')
	check(M.pick_default(1, DEFAULTS) == 'Player001', 'slot 1 -> Player001')
	check(M.pick_default(2, DEFAULTS) == 'Player002', 'slot 2 -> Player002')
	check(M.pick_default(5, DEFAULTS) == nil, 'slot past the list -> no default')
	check(M.pick_default(nil, DEFAULTS) == nil, 'no slot (all taken / no socket lib) -> no default')
	check(M.pick_default(1, nil) == nil, 'no defaults table -> no default')
	check(M.pick_default(1, { '' }) == nil, 'blank name -> no default')
end

print()
if failures == 0 then
	print('ALL TESTS PASSED')
	os.exit(0)
else
	print(failures .. ' TEST(S) FAILED')
	os.exit(1)
end
