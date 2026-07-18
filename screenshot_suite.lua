-- Visual test framework: drives the REAL game UI with scripted scenarios and
-- captures a screenshot of each settled scene into the LOVE save directory
-- (%APPDATA%/Balatro/shot_suite/), plus a manifest.json describing the run.
-- Pair with tools/compare_shots.py for golden-based visual REGRESSION:
--
--   $env:BMP_SHOT_SUITE = "1"; & Balatro.exe        -- run suite, auto-quit
--   python tools/compare_shots.py                    -- diff against goldens/
--   python tools/compare_shots.py --accept           -- promote run to goldens
--
-- Or from a running instance: DEVTOOLS.run_shot_suite().
--
-- THIS MOD IS ONLY THE RUNNER. The scenarios themselves live in the repos
-- whose code they cover, as inert files never loaded by those mods: each
-- loaded SMODS mod may carry `dev/shots.lua` returning
--
--   function(H)   -- H = this harness (start_draft/find_tile/find_ui)
--     return {
--       {
--         name = '01-my-scene',       -- also the PNG/golden filename
--         expect = 'what a correct shot shows',  -- reviewed against the PNG
--         region = {x=.2,y=.4,w=.6,h=.55},  -- optional: frame-fraction crop
--                                     -- compared by compare_shots.py, so the
--                                     -- animated background never diffs
--         skip = function() ... end,  -- optional: return true to skip
--         setup = function(done) ... end,  -- stage the scene, then done()
--         teardown = function() ... end,   -- optional: undo hovers etc.
--       },
--     }
--   end
--
-- Discovery happens once, at the start of an explicitly-requested run --
-- nothing is loaded or executed on normal boots. The API repo's
-- dev/shots.lua is the reference example: its scenarios drive the real
-- draft engine via a loopback lobby (BP.start as host with action keys NOT
-- in MPAPI.ActionTypes, so broadcasts no-op while the whole host path runs
-- for real), and interactions go through the same code paths as player
-- input (card:click(), card:hover(), the G.FUNCS button handlers).

local M = { scenarios = {} }
local SHOT_DIR = 'shot_suite'
local BP = MPAPI.BanPick

function M.register(sc)
	assert(type(sc) == 'table' and type(sc.name) == 'string' and type(sc.setup) == 'function',
		'shots.register needs {name=string, setup=function}')
	M.scenarios[#M.scenarios + 1] = sc
end

DEVTOOLS.shots = M

-----------------------------
-- Loopback draft helpers (exposed so consumer scenarios can reuse them)
-----------------------------

local _real_get_lobby = nil
local _lobby = nil

-- The fake lobby needs more surface than the draft engine itself uses:
-- the moment MPAPI.get_current_lobby returns it, AMBIENT systems consult it
-- too -- e.g. the_order's pseudorandom hook runs get_active_ruleset ->
-- lobby:get_metadata() from the particle update loop. Every method here is
-- a safe no-op default; extend it when a new system crashes the suite.
local function fake_lobby()
	return {
		is_host = true,
		player_id = 'shot_host',
		code = 'SHOT',
		connected = true,
		get_players = function(_self)
			return { { id = 'shot_host', displayName = 'Host' }, { id = 'shot_guest', displayName = 'Guest' } }
		end,
		get_metadata = function(_self)
			return {}
		end,
		get_gamemode_instance = function(_self)
			return nil
		end,
	}
end

-- Start a real draft on the loopback lobby. `first` = 1 puts the local player
-- on turn (build_order puts lobby.player_id at order[1]), 2 = the opponent.
function M.start_draft(pool, schedule, first)
	_lobby = fake_lobby()
	if not _real_get_lobby then
		_real_get_lobby = MPAPI.get_current_lobby
	end
	MPAPI.get_current_lobby = function()
		return _lobby
	end
	BP.start(_lobby, {
		build_pool = function()
			return pool
		end,
		schedule = schedule,
		state_action = 'shot_state', -- deliberately unregistered: broadcasts no-op
		ban_action = 'shot_ban',
	}, function() end)
	_lobby._ban_pick.first = first or 1
	-- Rebuild through the real state path so turn/actor UI reflects `first`.
	BP.on_state(_lobby, _lobby._ban_pick)
	return _lobby
end

function M.find_tile(item_id)
	for _, c in ipairs(G.I.CARD or {}) do
		if c.mp_item_id == item_id then
			return c
		end
	end
end

-- Depth-first search of a UI tree for a node matching pred (children tables
-- mix array entries and named keys like h_popup, so iterate pairs).
function M.find_ui(node, pred, depth)
	if not node or (depth or 0) > 12 then
		return nil
	end
	if node.config and pred(node) then
		return node
	end
	for _, ch in pairs(node.children or {}) do
		local hit = M.find_ui(ch, pred, (depth or 0) + 1)
		if hit then
			return hit
		end
	end
	local root = node.UIRoot
	if root then
		return M.find_ui(root, pred, (depth or 0) + 1)
	end
end

-----------------------------
-- Scenario discovery
-----------------------------

-- Pull scenarios from the mods under test: any loaded SMODS mod may carry
-- dev/shots.lua (see the header contract). Runs once per session, at the
-- start of an explicitly-requested run.
local function discover()
	if M._discovered then
		return
	end
	M._discovered = true
	for id, _mod in pairs(SMODS.Mods or {}) do
		local ok, chunk = pcall(SMODS.load_file, 'dev/shots.lua', id)
		if ok and chunk then
			local ok2, factory = pcall(chunk)
			if ok2 and type(factory) == 'function' then
				local ok3, list = pcall(factory, M)
				if ok3 and type(list) == 'table' then
					local n = 0
					for _, sc in ipairs(list) do
						local ok4, err = pcall(M.register, sc)
						if ok4 then
							n = n + 1
						else
							DEVTOOLS.sendWarnMessage('bad scenario from ' .. id .. ': ' .. tostring(err))
						end
					end
					DEVTOOLS.sendDebugMessage('shots: ' .. n .. ' scenarios from ' .. id)
				elseif not ok3 then
					DEVTOOLS.sendWarnMessage('shots factory errored for ' .. id .. ': ' .. tostring(list))
				end
			end
		end
	end
	-- Deterministic run order regardless of mod iteration order.
	table.sort(M.scenarios, function(a, b)
		return a.name < b.name
	end)
end

-----------------------------
-- Runner
-----------------------------

local function after(delay, fn)
	G.E_MANAGER:add_event(Event({
		trigger = 'after',
		delay = delay,
		blockable = false,
		blocking = false,
		func = function()
			fn()
			return true
		end,
	}))
end

local SETTLE = 1.2 -- seconds for tweens/alignment (incl. popup clamp) to rest

local function cleanup()
	pcall(function()
		if G.FUNCS.exit_overlay_menu then
			G.FUNCS.exit_overlay_menu()
		end
	end)
end

local function run_scenario(i, entries, on_finished)
	local sc = M.scenarios[i]
	if not sc then
		on_finished(entries)
		return
	end
	local entry = { name = sc.name, region = sc.region, expect = sc.expect }
	entries[#entries + 1] = entry
	if sc.skip and sc.skip() then
		entry.status = 'skipped'
		run_scenario(i + 1, entries, on_finished)
		return
	end
	local ok, err = pcall(sc.setup, function() end)
	if not ok then
		entry.status = 'error'
		entry.error = tostring(err)
		cleanup()
		run_scenario(i + 1, entries, on_finished)
		return
	end
	after(SETTLE, function()
		love.graphics.captureScreenshot(SHOT_DIR .. '/' .. sc.name .. '.png')
		entry.status = 'captured'
		-- Capture happens at end-of-frame; tear down strictly after.
		after(0.1, function()
			if sc.teardown then
				pcall(sc.teardown)
			end
			cleanup()
			after(0.2, function()
				run_scenario(i + 1, entries, on_finished)
			end)
		end)
	end)
end

-- One-glance contact sheet: shot_suite/gallery.html, double-click to review
-- the whole run in a browser (image + name + expectation per scenario).
local function write_gallery(entries)
	local h = {
		'<!doctype html><meta charset="utf-8"><title>shot suite</title>',
		'<body style="background:#1c2726;color:#e6ece7;font:14px system-ui;margin:20px">',
		'<h1 style="font-size:18px">Shot suite run</h1>',
	}
	for _, e in ipairs(entries) do
		h[#h + 1] = '<div style="margin:18px 0;max-width:1100px">'
		h[#h + 1] = '<h2 style="font-size:15px;margin:4px 0">' .. e.name .. '  <small style="color:#97a8a3">' .. (e.status or '') .. '</small></h2>'
		if e.expect then
			h[#h + 1] = '<p style="color:#97a8a3;margin:4px 0;max-width:80ch">expect: ' .. e.expect .. '</p>'
		end
		if e.status == 'captured' then
			h[#h + 1] = '<img src="' .. e.name .. '.png" style="max-width:100%;border:1px solid #384a48;border-radius:6px">'
		end
		h[#h + 1] = '</div>'
	end
	h[#h + 1] = '</body>'
	love.filesystem.write(SHOT_DIR .. '/gallery.html', table.concat(h, '\n'))
end

function DEVTOOLS.run_shot_suite(and_quit)
	discover()
	love.filesystem.createDirectory(SHOT_DIR)
	DEVTOOLS.sendDebugMessage('shot suite: ' .. #M.scenarios .. ' scenarios -> save-dir/' .. SHOT_DIR)
	run_scenario(1, {}, function(entries)
		love.filesystem.write(SHOT_DIR .. '/manifest.json', MPAPI.json_encode({ scenarios = entries }))
		write_gallery(entries)
		local lines = {}
		for _, e in ipairs(entries) do
			lines[#lines + 1] = e.name .. '  ' .. e.status .. (e.error and (': ' .. e.error) or '')
		end
		DEVTOOLS.sendDebugMessage('shot suite done:\n' .. table.concat(lines, '\n'))
		if _real_get_lobby then
			MPAPI.get_current_lobby = _real_get_lobby
			_real_get_lobby = nil
		end
		_lobby = nil
		if and_quit then
			-- Give the last captureScreenshot's end-of-frame write time to land.
			after(1.0, function()
				love.event.quit()
			end)
		end
	end)
end

-- Auto-runs capture at a CANONICAL resolution: shots are deterministic
-- across runs/machines (goldens need that) and 16:9 fills the frame with UI
-- -- Balatro sizes its interface by window HEIGHT, so ultrawide width only
-- adds background. Override with BMP_SHOT_RES=WxH (clamped to the desktop by
-- LOVE); the game quits after the run, so nothing is restored.
local function set_canonical_resolution()
	local w, h = 1920, 1080
	local env = os.getenv('BMP_SHOT_RES')
	if env then
		local ew, eh = env:match('^(%d+)x(%d+)$')
		if ew then
			w, h = tonumber(ew), tonumber(eh)
		end
	end
	pcall(function()
		love.window.setMode(w, h, { fullscreen = false, resizable = true })
		love.resize(w, h)
	end)
end

-- Env-triggered auto-run: poll until the main menu is up, settle, run, quit.
if os.getenv('BMP_SHOT_SUITE') then
	local started = false
	G.E_MANAGER:add_event(Event({
		blockable = false,
		blocking = false,
		no_delete = true,
		func = function()
			if started then
				return true
			end
			if G.STAGE == G.STAGES.MAIN_MENU then
				started = true
				set_canonical_resolution()
				-- Generous first delay: the menu's background shader and card
				-- cascade take a few seconds to spin up after the menu appears;
				-- capturing sooner gives the first scenario a half-loaded
				-- backdrop the rest of the run does not have.
				after(6.0, function()
					DEVTOOLS.run_shot_suite(true)
				end)
				return true
			end
			return false
		end,
	}))
end

return M
