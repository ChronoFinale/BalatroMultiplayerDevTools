-- Dev-only in-client account impersonation picker.
--
-- Lets a running game instance switch which real account (players row) it's
-- authenticated as at RUNTIME, instead of only at boot via the
-- BMP_IMPERSONATE_ID / BMP_IMPERSONATE_NAME env vars (see devtools/init.lua).
-- Reuses the exact mechanism the env vars use -- monkey-patch the shared
-- connection prototype's _do_auth to call _try_impersonate_auth(target), then
-- drive the existing MPAPI.reconnect() disconnect/reconnect path -- so this
-- file adds no new networking, just a UI in front of what devtools/init.lua
-- already does at boot.
--
-- This is part of the standalone Multiplayer DevTools mod (devtools/), kept
-- separate from the MultiplayerAPI mod and not distributed with its releases.

local impersonation = DEVTOOLS.load_file('impersonation.lua')

-- Forward declarations for helper functions
local create_UIBox_dev_impersonate_overlay
local build_dev_row
local do_login

-----------------------------
-- STATE VARIABLES
-----------------------------

-- Persistent across overlay open/close within this client session (this file
-- is loaded once at boot), so re-opening the picker keeps whatever was last
-- typed or quick-selected -- the "last used this session" prefill priority.
local _input_state = { text = impersonation.resolve_prefill(nil, os.getenv('BMP_IMPERSONATE_ID'), os.getenv('BMP_IMPERSONATE_NAME')) }

-- pending/message/ok banner state, advanced by impersonation.next_feedback().
local _feedback = { pending = false, message = nil, ok = nil }

local SEED_NAMES = { 'Player001', 'Player002', 'Player003', 'Player004' }

-----------------------------
-- UI FUNCTIONS
-----------------------------

-- The extra row embedded at the bottom of the Multiplayer account panel (see
-- the MPAPI.account_button wrap below), right under the "Connected"/status
-- line -- a small, clearly-dev-only red mini-button, not a separate box.
build_dev_row = function()
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.05 },
		nodes = {
			{
				n = G.UIT.C,
				config = { align = 'cm', padding = 0.04, minw = 0.9, minh = 0.35, r = 0.1, hover = true, shadow = true, colour = darken(G.C.RED, 0.1), button = 'mpapi_dev_impersonate_open' },
				nodes = {
					{ n = G.UIT.T, config = { text = 'DEV', scale = 0.28, colour = G.C.WHITE, shadow = true } },
				},
			},
		},
	}
end

create_UIBox_dev_impersonate_overlay = function()
	local identity_line = 'Disconnected'
	if MPAPI.connection_state.state == MPAPI.ConnectionState.CONNECTED then
		local name = MPAPI.connection_state.steam_name
		name = (name and name ~= '') and name or 'Unknown'
		identity_line = name .. '  (' .. tostring(MPAPI.connection_state.player_id) .. ')'
	end

	local feedback_colour = G.C.UI.TEXT_LIGHT
	if _feedback.ok == true then
		feedback_colour = G.C.GREEN
	elseif _feedback.ok == false then
		feedback_colour = G.C.RED
	elseif _feedback.pending then
		feedback_colour = G.C.GOLD
	end

	local quick_button_nodes = {}
	for i, name in ipairs(SEED_NAMES) do
		quick_button_nodes[#quick_button_nodes + 1] = {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.03 },
			nodes = {
				UIBox_button({
					button = 'mpapi_dev_impersonate_quick_' .. i,
					label = { name },
					colour = G.C.BLUE,
					minw = 1.7,
					minh = 0.5,
					scale = 0.32,
				}),
			},
		}
	end

	local warning = impersonation.server_warning(MPAPI.config and MPAPI.config.use_custom_server)
	local warning_node = nil
	if warning then
		warning_node = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.03 },
			nodes = {
				{ n = G.UIT.T, config = { text = warning, scale = 0.28, colour = G.C.UI.TEXT_INACTIVE } },
			},
		}
	end

	local contents = {
		{
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.1 },
			nodes = {
				{ n = G.UIT.T, config = { text = 'Dev: Impersonate Account', scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			},
		},
		{
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.05 },
			nodes = {
				{ n = G.UIT.T, config = { text = 'Currently: ' .. identity_line, scale = 0.32, colour = G.C.UI.TEXT_INACTIVE } },
			},
		},
		{
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.1 },
			nodes = {
				create_text_input({
					id = 'mpapi_dev_impersonate_input',
					ref_table = _input_state,
					ref_value = 'text',
					prompt_text = 'any name (created if new) or uuid',
					max_length = 60,
					w = 4.5,
					h = 0.6,
				}),
			},
		},
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = quick_button_nodes },
		{
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.1 },
			nodes = {
				UIBox_button({ button = 'mpapi_dev_impersonate_login', label = { 'Login as' }, colour = G.C.GREEN, minw = 2.2, minh = 0.6, scale = 0.4 }),
			},
		},
		{
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.05, minh = 0.4 },
			nodes = {
				{ n = G.UIT.T, config = { text = _feedback.message or '', scale = 0.32, colour = feedback_colour } },
			},
		},
	}

	if warning_node then
		contents[#contents + 1] = warning_node
	end

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

-- Impureim sandwich: parse (pure) -> monkey-patch + reconnect (effects) ->
-- the connection-state-change hook below resolves the banner once the
-- reconnect attempt settles (success or failure).
do_login = function(raw_input)
	local target, err = impersonation.parse_target(raw_input)
	if not target then
		_feedback = { pending = false, message = err, ok = false }
		MPAPI.dev_impersonate_overlay:update()
		return
	end

	_feedback = impersonation.next_feedback(_feedback, { kind = 'login_started' })
	MPAPI.dev_impersonate_overlay:update()

	-- Same override point devtools/init.lua uses for BMP_IMPERSONATE_*: patch
	-- the shared connection prototype so the next connect() attempt logs in as
	-- `target` via the dev impersonation endpoint instead of Steam/refresh.
	local connection = MPAPI.networking.connection
	connection._do_auth = function(self)
		self:_try_impersonate_auth(target)
	end

	MPAPI.sendDebugMessage('[dev-impersonate] switching to ' .. tostring(target.playerId or target.steamName))
	MPAPI.reconnect()
end

G.FUNCS.mpapi_dev_impersonate_open = function(e)
	MPAPI.dev_impersonate_overlay:as_overlay()
end

G.FUNCS.mpapi_dev_impersonate_login = function(e)
	do_login(_input_state.text)
end

for i, name in ipairs(SEED_NAMES) do
	G.FUNCS['mpapi_dev_impersonate_quick_' .. i] = function(e)
		_input_state.text = name
		MPAPI.dev_impersonate_overlay:update()
	end
end

-----------------------------
-- GLOBAL UI ELEMENTS
-----------------------------

MPAPI.dev_impersonate_overlay = MPAPI.ui_element(create_UIBox_dev_impersonate_overlay)

-----------------------------
-- EMBED INTO THE ACCOUNT PANEL
-----------------------------

-- Embed the DEV control INSIDE the existing Multiplayer account panel
-- (MPAPI.account_button) instead of floating as our own UIBox: the panel is
-- the API's own bordered box, anchored top-left ('tli') -- there is no free
-- corner on the main menu (vanilla's Profile button owns bottom-left, the
-- version text owns top-right, G.MAIN_MENU_UI's Play/Options/etc row owns
-- bottom-middle, Discord/language own bottom-right). Embedding also means
-- persistence comes for free: every place that already calls
-- MPAPI.account_button:update() to react to connection-state changes and
-- mod/lobby view switches (api/connection/state.lua, api/mod_registry/
-- focus.lua, api/mod_registry/view.lua) re-renders our row along with it --
-- no separate G.ROOM_ATTACH attachment or update-wrap needed.
--
-- ui/main_menu.lua's create_UIBox_account_button is a local, not reachable
-- from devtools/, so we wrap the GLOBAL MPAPI.account_button ui_element it
-- produces instead: keep the original element to source its live inline
-- content (el.node -- see api/ui_element.lua's "Inline" mode doc comment),
-- and replace MPAPI.account_button with a new ui_element whose build_fn
-- appends our row inside the same bordered panel box, right after the
-- "Connected" status line (the panel's last row). main_menu.lua's own
-- attach_account_button() reads MPAPI.account_button fresh at call time (it
-- runs later, once the game builds the main menu), so it ends up attaching
-- OUR wrapped element to the exact anchor the vanilla-facing panel already
-- uses -- zero changes needed outside devtools/. This relies on devtools/
-- loading strictly after MultiplayerAPI's own core.lua has finished (see
-- devtools/init.lua's load-order note), so MPAPI.account_button already
-- exists by the time we get here.
local _base_account_button = MPAPI.account_button

local function create_UIBox_account_panel_with_dev()
	local base_node = _base_account_button.node
	local dev_row = build_dev_row()

	-- base_node is { n = C, config = {...}, nodes = { <bordered panel R node> } }
	-- (see api/ui_element.lua's build_inline()). Reach into that panel node's
	-- own row list and append ours as its new last row. Falls back to
	-- appending below the panel (still visible, just not "inside" the
	-- border) if that shape ever changes, rather than silently dropping the
	-- dev control.
	local panel = base_node and base_node.nodes and base_node.nodes[1]
	if panel and panel.nodes then
		panel.nodes[#panel.nodes + 1] = dev_row
		return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = { base_node } }
	end

	return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = { base_node, dev_row } }
end

MPAPI.account_button = MPAPI.ui_element(create_UIBox_account_panel_with_dev)

-----------------------------
-- CONNECTION-STATE HOOK
-----------------------------

-- Registered once at load: resolves the picker's pending banner from whatever
-- the reconnect triggered by do_login() settles into. Ignores connection
-- churn it didn't start (next_feedback's pending guard) -- e.g. the initial
-- boot-time connect, or a later manual reconnect from the account overlay.
MPAPI.on_connection_state_change(function(new_state, context)
	if not _feedback.pending then
		return
	end

	if new_state == MPAPI.ConnectionState.CONNECTED then
		local conn = MPAPI.get_connection()
		local identity = (conn and (conn.steam_name or conn.player_id)) or 'unknown'
		_feedback = impersonation.next_feedback(_feedback, { kind = 'connected', identity = identity })
		MPAPI.dev_impersonate_overlay:update()
	elseif new_state == MPAPI.ConnectionState.DISCONNECTED and context.error then
		_feedback = impersonation.next_feedback(_feedback, { kind = 'disconnected', error = context.error })
		MPAPI.dev_impersonate_overlay:update()
	end
end)
