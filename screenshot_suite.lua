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
-- GENERAL REGISTRY: any mod (or this file) registers scenarios --
--
--   DEVTOOLS.shots.register({
--     name = '09-my-scene',           -- also the PNG/golden filename
--     expect = 'what a correct shot shows', -- reviewed against the PNG by
--                                     -- whoever (or whatever) checks the run
--     region = {x=.2,y=.4,w=.6,h=.55},-- optional: frame-fraction crop compared
--                                     -- by compare_shots.py, so the animated
--                                     -- background never participates in diffs
--     skip = function() ... end,      -- optional: return true to skip
--     setup = function(done) ... end, -- stage the scene; call done() when set
--     teardown = function() ... end,  -- optional: undo hovers etc.
--   })
--
-- Register from a consumer mod behind `if DEVTOOLS and DEVTOOLS.shots then`.
--
-- The built-in draft scenarios below double as examples. They drive the real
-- draft engine via a loopback lobby: BP.start as host with action keys that
-- are NOT in MPAPI.ActionTypes -- broadcasts no-op while the whole host path
-- (state machine, validation, overlay UI) runs for real. Interactions go
-- through the same code paths as player input (card:click(), card:hover(),
-- the G.FUNCS button handlers), so the screenshots show what a player gets.

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
-- Built-in draft scenarios
-----------------------------

local PLAIN_POOL = { 'b_red', 'b_blue', 'b_yellow', 'b_green', 'b_black', 'b_magic', 'b_nebula', 'b_ghost', 'b_abandoned' }
local TUPLE_POOL = {
	{ key = 'b_red', stake = 1 }, { key = 'b_red', stake = 5 }, { key = 'b_blue', stake = 3 },
	{ key = 'b_green', stake = 4 }, { key = 'b_black', stake = 1 }, { key = 'b_magic', stake = 3 },
	{ key = 'b_nebula', stake = 5 }, { key = 'b_ghost', stake = 1 }, { key = 'b_abandoned', stake = 4 },
}
-- actor = 1 matters: resolve_actor maps a step's actor through state.first,
-- and a nil actor resolves as actor 2 -- without it every scene renders as
-- the OPPONENT's turn (the first suite run caught exactly that).
local BAN3 = { { actor = 1, action = 'ban', count = 3 } }

-- The centered draft panel (no popups above it).
local PANEL_REGION = { x = 0.22, y = 0.38, w = 0.56, h = 0.60 }
-- Panel plus the airspace hover popups grow into.
local HOVER_REGION = { x = 0.16, y = 0.04, w = 0.68, h = 0.94 }

local function cocktail_missing()
	return not (G.P_CENTERS and G.P_CENTERS.b_mp_cocktail)
end

local function cocktail_pool()
	local pool = { unpack(TUPLE_POOL) }
	pool[3] = {
		key = 'b_mp_cocktail', stake = 3,
		cocktail = { 'b_green', 'b_black', 'b_mp_orange' },
		cocktail_name = 'Casjb',
	}
	return pool
end

M.register({
	name = '01-ban-turn-plain',
	expect = "Draft overlay over the main menu: DECK BAN title, 'Your turn' status in green, 9 deck tiles in a row, 'Selected: 0/3' counter, greyed Confirm Ban, blue Random. No ERROR text anywhere.",
	region = PANEL_REGION,
	setup = function(done)
		M.start_draft(PLAIN_POOL, BAN3, 1)
		done()
	end,
})
M.register({
	name = '02-selected-2of3',
	expect = "Two tiles (1st and 5th) raised with red 'Selected' tags; counter reads 'Selected: 2/3'; Confirm still greyed (needs exactly 3).",
	region = PANEL_REGION,
	setup = function(done)
		M.start_draft(PLAIN_POOL, BAN3, 1)
		local t1, t2 = M.find_tile('b_red'), M.find_tile('b_black')
		if t1 then t1:click() end
		if t2 then t2:click() end
		done()
	end,
})
M.register({
	name = '03-random-armed',
	expect = "No tiles raised; counter reads '?/3'; Random button is RED reading 'Cancel Random'; Confirm is GREEN reading 'Confirm Random'.",
	region = PANEL_REGION,
	setup = function(done)
		M.start_draft(PLAIN_POOL, BAN3, 1)
		G.FUNCS.mpapi_ban_pick_random()
		done()
	end,
})
M.register({
	name = '04-offturn-greyed',
	expect = "Status reads waiting/their-turn (not green); counter and BOTH buttons visible but greyed out; layout otherwise identical to scenario 01.",
	region = PANEL_REGION,
	setup = function(done)
		M.start_draft(PLAIN_POOL, BAN3, 2)
		done()
	end,
})
M.register({
	name = '05-banned-tiles',
	expect = "Same board as 01 but the 2nd and 8th tiles are debuffed (darkened X overlay); they must not react to anything.",
	region = PANEL_REGION,
	setup = function(done)
		local lobby = M.start_draft(PLAIN_POOL, BAN3, 1)
		lobby._ban_pick.banned['b_blue'] = true
		lobby._ban_pick.banned['b_ghost'] = true
		BP.on_state(lobby, lobby._ban_pick)
		done()
	end,
})
M.register({
	name = '06-tuple-hover-stake-column',
	expect = "Hover popup over the 7th tile: deck name + effects on the left, stake column on the right (stake name in its colour, description, 'Also applied' list). Popup fully on screen.",
	region = HOVER_REGION,
	setup = function(done)
		M.start_draft(TUPLE_POOL, BAN3, 1)
		local tile = M.find_tile('b_nebula@5')
		if tile then tile:hover() end
		done()
	end,
	teardown = function()
		local tile = M.find_tile('b_nebula@5')
		if tile then tile:stop_hover() end
	end,
})
M.register({
	name = '07-cocktail-badge-hover',
	expect = "Badge pill above the tiles reads 'Casjb Cocktail: Green Deck + Black Deck + Orange Deck'; its hover shows the three decks SIDE BY SIDE with full effects, growing downward, fully on screen.",
	region = HOVER_REGION,
	skip = cocktail_missing,
	setup = function(done)
		M.start_draft(cocktail_pool(), BAN3, 1)
		local badge = M.find_ui(G.OVERLAY_MENU, function(n)
			return n.config.mp_comp_item ~= nil
		end)
		if badge then
			-- The rich hover is installed by the badge's per-frame init func;
			-- immediately after the rebuild it has not run yet, so hovering
			-- now would hit the default popup-less UIElement hover. Run it
			-- explicitly first (idempotent), then hover.
			G.FUNCS.mpapi_cocktail_badge_init(badge)
			badge:hover()
		end
		done()
	end,
})
M.register({
	name = '08-cocktail-tile-hover-compact',
	expect = "Cocktail tile hover is COMPACT: 'Casjb Cocktail' title, 'rotating 3-deck mix' line, three deck NAMES only (no effect boxes), plus the stake column. Same footprint as a normal deck's hover.",
	region = HOVER_REGION,
	skip = cocktail_missing,
	setup = function(done)
		M.start_draft(cocktail_pool(), BAN3, 1)
		local tile = M.find_tile('b_mp_cocktail@3')
		if tile then tile:hover() end
		done()
	end,
})

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
				after(2.0, function()
					DEVTOOLS.run_shot_suite(true)
				end)
				return true
			end
			return false
		end,
	}))
end

return M
