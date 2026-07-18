# 08 — The Speedrun Consumer Mod (contrast case to PvP)

> Source tree: `C:/Users/micha/AppData/Roaming/Balatro/Mods/BalatroSpeedrunning` (branch `spdrn-local`).
> All file references below are relative to that mod root unless prefixed with `BalatroMultiplayerAPI/` or `MultiplayerPvP/`.

## 1. What this layer owns

BalatroSpeedrunning (`SPDRN`) is the second consumer of the shared MPAPI platform and the proof that the platform's seams are real: it ships two race-to-ante-9 gamemodes (best-of-3 White Stake, single-run Gold Stake), a practice mode, private lobbies, and ranked/casual matchmaking — in roughly 600 lines of `objects/` code (`core.lua` is 120 lines) — by consuming MPAPI's lobby, ActionType, matchmaking-handle, and BanPick engines rather than reimplementing them. It owns only what is genuinely speedrun-specific: the vanilla-only draft pool ruling, ante-9 win detection, per-run seed derivation for best-of-3, lobby-kind routing (practice/private/ranked/casual), and server-clock run timing. It is deliberately independent of PvP: the two mods register side by side via `MPAPI.register_mod` (`core.lua:47`), and a lobby only routes ActionTypes whose `mod.id` matches, so their wire vocabularies never collide (`objects/actions/ban_pick_state.lua:2-3`).

## 2. Key files

| File | Role | The one thing to know |
|---|---|---|
| `core.lua` | Mod bootstrap + MPAPI registration | Loads `objects/` only inside `MPAPI.on_loaded` (`core.lua:46,112`); hooks `win_game`/`Game:update` to replace vanilla win/lose screens (`core.lua:90-110`) |
| `objects/actions/start_game.lua` | The one start broadcast every flow funnels through | Routes by lobby kind: practice → immediate, matchmade draft mode → BanPick then countdown, else → countdown (`start_game.lua:31-61`) |
| `objects/actions/ban_pick_ban.lua` / `ban_pick_state.lua` | The two draft wire actions | Pure delegation to `MPAPI.BanPick.apply_ban` / `on_state` — the consumer owns only the action keys (`ban_pick_ban.lua:13-15`) |
| `objects/gamemodes/white_stake_triple.lua` | Best-of-3, white stake | `ban_pick = { pool_size = 9, keep = 3 }` (`:13`); `on_ante_change` sequences runs 2 and 3 off the survivors (`:19-73`) |
| `objects/gamemodes/gold_stake_single.lua` | Single run, gold stake | `ban_pick = { pool_size = 5, keep = 1 }` (`:11`); ante 9 → broadcast `spdrn_player_won` (`:16-32`) |
| `objects/matchmaking/vanilla_pool.lua` | Vanilla-only draft pool builder | Hardcoded list of the 15 vanilla decks by design — never filter "not modded" (`vanilla_pool.lua:10-17`) |
| `objects/matchmaking/queue.lua` | Ranked/casual queue lifecycle | One `_join_queue(kind, gamemode_key)`; ranked prefixes the server `game_mode` string (`queue.lua:8`) |
| `objects/matchmaking/run_timing.lua` / `result.lua` | Server-clock timing + result report | Host-only, self-guarded to matches (`run_timing.lua:5-11`, `result.lua:5-12`) |
| `domain/lobby_kind.lua`, `ui/lobby/kind.lua` | The lobby-kind enum + accessor | Client-side `SPDRN._lobby_kind`, set synchronously by every entry path (`kind.lua:1-6`) |
| `tests/` | In-game (`BInt`) + standalone luajit tests | Loaded only when the Integration mod is present (`core.lua:113-115`) |

## 3. How it works

### 3.1 One BanPick engine, two games — the legacy `pool_size/keep` shape

The draft engine lives entirely in MPAPI (`BalatroMultiplayerAPI/api/ban_pick.lua`, 1440 lines) and supports two config shapes: the **legacy** `{ pool_size, keep }` form and the **scheduled** `{ schedule = {...} }` form (`ban_pick.lua:10-15`). Speedrun uses the legacy form; the engine derives an alternating-single-ban schedule from it:

```lua
-- BalatroMultiplayerAPI/api/ban_pick.lua:111-118
local function derive_schedule(pool_size, keep)
    local bans = math.max(0, (pool_size or 0) - (keep or 1))
    local sched = {}
    for i = 1, bans do
        sched[i] = { actor = ((i - 1) % 2) + 1, action = "ban", count = 1 }
    end
    return sched
end
```

So White Stake Triple's `{ pool_size = 9, keep = 3 }` becomes six alternating single bans; Gold Stake Single's `{ pool_size = 5, keep = 1 }` becomes four. Contrast with PvP, which passes an explicit `schedule` plus tuple `{ key, stake }` items, a `decorate_tile` stake-sticker hook, and an `on_action_applied` server audit stash (`MultiplayerPvP/pvp_api/actions.lua:101-126`). Speedrun passes none of those — plain string keys keep item identity = key (`ban_pick.lua:83-91`), so the whole tuple/stake machinery is dormant. The consumer's total draft footprint is the two 16-line ActionType files plus the `BanPick.start` call below.

### 3.2 The vanilla-only pool ruling and builder

Matchmade Speedrun drafts must never offer a modded deck: the opponent may not have PvP (or any deck mod) installed, so the clients could not agree on the pick (`vanilla_pool.lua:3-8`, maintainer ruling 2026-07-17). The builder samples from an **explicit** list of the 15 vanilla deck keys — deliberately not "all Backs minus modded", which would depend on loader internals (`vanilla_pool.lua:10-12`):

```lua
-- objects/matchmaking/vanilla_pool.lua:22-35
function SPDRN.vanilla_draft_pool(size, rng)
    rng = rng or math.random          -- injectable for tests
    local eligible = {}
    for _, key in ipairs(SPDRN.VANILLA_DECKS) do
        if not G or not G.P_CENTERS or G.P_CENTERS[key] then
            eligible[#eligible + 1] = key
        end
    end
    local pool = {}
    while #pool < (size or 0) and #eligible > 0 do
        pool[#pool + 1] = table.remove(eligible, rng(#eligible))
    end
    return pool
end
```

It is wired in as the draft's `build_pool` override (`start_game.lua:41-45`); without it the engine would default to sampling **all** installed Backs (`ban_pick.lua:94-108`) — the exact bug the ruling forbids. Note only the **host** ever runs `build_pool` (`ban_pick.lua:1303-1304`); guests just render the broadcast state, which is why a host-side vanilla guarantee suffices.

### 3.3 Best-of-3 sequencing off the ban survivors

`spdrn_start_game` hands the draft survivors to the countdown, then to `SPDRN.begin_run` (`start_game.lua:51-55`). `begin_run` instantiates the gamemode, stashes the ordered deck list as `instance._run_decks` and the broadcast seed as `instance._base_seed` (`ui/lobby/run_start.lua:64-71`). White Stake Triple then drives runs 2 and 3 from `on_ante_change`:

```lua
-- objects/gamemodes/white_stake_triple.lua:29-63 (abridged)
self._run_count = self._run_count + 1
if self._run_count < 3 then
    local run_idx = self._run_count + 1
    local deck = self._run_decks and self._run_decks[run_idx]
    ...
    local seed = SPDRN.derive_seed(self._base_seed, run_idx)
    G.E_MANAGER:add_event(Event({ func = function()
        self:start_run(deck, seed)
        return true
    end }))
else
    ... broadcast spdrn_player_won ...
end
```

Survivor order = pool order minus bans (`ban_pick.lua:161-170`), so "the three decks map to runs 1/2/3 in order" (`white_stake_triple.lua:35-38`). Later seeds are **derived, not broadcast**: `SPDRN.derive_seed` is a precision-safe djb2 spread over `base_seed:run_idx:char` kept under 2^24 so `h * 33` never loses precision in LuaJIT doubles — every client computes identical run-2/run-3 seeds with no extra network round trip (`ui/lobby/seed.lua:12-29`). The restart is deferred one event tick because `on_ante_change` runs synchronously inside `ease_ante` (`white_stake_triple.lua:54-58`).

### 3.4 Lobby kinds and what applies where

`SPDRN._lobby_kind` is a client-side authority set synchronously by every entry path before any lobby UI exists (`ui/lobby/kind.lua:1-6`): practice (`ui/main_menu/practice.lua:5`), private create/join (`ui/main_menu/create_lobby.lua:144`, `join.lua:67`), and the queue (`queue.lua:4,49`). `is_matchmaking()` means RANKED or CASUAL (`kind.lua:8-11`). What each kind gets:

| | practice | private | matchmade (ranked/casual) |
|---|---|---|---|
| Lobby | local, no server lobby, view suppressed (`practice.lua:1-16`) | server lobby, host START button (`run_start.lua:115-121`) | server lobby via match handle; host auto-starts when all ready (`ready.lua:74-96`) |
| Draft | never — host-picked deck list (`start_game.lua:31-32`) | never — `meta.deck`, countdown (`start_game.lua:56-60`) | yes iff `gm_def.ban_pick` (`start_game.lua:33`), vanilla pool, rendered inline in the lobby panel (`ui/lobby/controls.lua:76-77`) |
| Countdown | skipped (`countdown.lua:32-33`) | 5 s synced | 5 s synced, shows survivor deck backs |
| Server timing/rating | no (`run_timing.lua:5-6` no match handle) | no | yes: host `mark_started` + `report_result`; server decides rated-vs-casual from the `ranked:` prefix (`queue.lua:8`, `result.lua:2-3`) |

## 4. Main flows

### Matchmade best-of-3: queue → draft → three runs

```mermaid
sequenceDiagram
    participant H as Host client
    participant G as Guest client
    participant S as Server (matchmaking)
    H->>S: queue(game_mode='ranked:spdrn_white_stake_triple') [queue.lua:12-17]
    S-->>H: lobby_ready
    S-->>G: lobby_ready
    Note over H,G: both signal_ready + resync loop [queue.lua:58-59]
    H->>G: broadcast spdrn_start_game{seed} (auto-start) [ready.lua:94-95]
    Note over H,G: both run start_game.on_receive; gm has ban_pick + is_matchmaking [start_game.lua:33]
    H->>H: BanPick.start: build vanilla pool(9), schedule=6 alt bans [ban_pick.lua:1303-1328]
    H->>G: spdrn_ban_pick_state (full state, serial-stamped) [ban_pick.lua:1090-1110]
    loop until 3 survivors
        G->>H: spdrn_ban_pick_ban{item_key} (guest turns) [ban_pick_ban.lua:13-15]
        H->>G: spdrn_ban_pick_state (rebroadcast)
    end
    Note over H,G: on_complete(survivors) → 5s countdown [start_game.lua:51-55]
    H->>S: mark_started (host only) [start_game.lua:22-25]
    Note over H,G: begin_run(gm, survivors, seed) → run 1 [run_start.lua:41-72]
    Note over H,G: ante 9 ×2 → derive_seed(base, 2|3), start_run deck 2|3 [white_stake_triple.lua:29-63]
    H->>G: spdrn_player_won{player_id} (first to finish run 3) [white_stake_triple.lua:70-71]
    H->>S: report_result(placements) [player_won.lua:28-30, result.lua:22]
```

### Ban application (host authority)

```mermaid
sequenceDiagram
    participant G as Guest (its turn)
    participant H as Host
    G->>G: click tiles → _selected; Confirm [ban_pick.lua:761-771,1401]
    G->>H: ban_action{item_key=id} to order[1] [ban_pick.lua:1200-1204]
    H->>H: apply_action: turn check, legality, mark ban, advance schedule [ban_pick.lua:1137-1173]
    H->>G: state_action{state} serial++ [ban_pick.lua:1098-1109]
    G->>G: on_state: staleness guard → replace lobby._ban_pick, prune selection, re-render [ban_pick.lua:1208-1246]
    Note over G,H: state.complete → both fire on_complete(survivors) exactly once [ban_pick.lua:1248-1265]
```

## 5. Invariants & gotchas

- **Matchmade pools are vanilla-only, from the explicit list.** Any PR that swaps `build_pool` for the engine default or derives the list from `G.P_CENTER_POOLS.Back` re-introduces the modded-deck desync the ruling exists to prevent (`vanilla_pool.lua:3-17`, `ban_pick.lua:94-108`). Custom/private lobbies never draft, so they are unaffected (`start_game.lua:33`, `vanilla_pool.lua:7-8`).
- **Draft actions must live in the consumer, keyed per mod.** A lobby only attaches ActionTypes whose `mod.id` matches — `spdrn_ban_pick_*` and `pvp_ban_pick_*` are separate registrations delegating to the same engine (`ban_pick_state.lua:2-3`, `ban_pick.lua:20-24`). Moving them "up" into MPAPI would break routing.
- **Only the host mutates draft state; guests render broadcasts.** `spdrn_ban_pick_ban` drops on non-hosts (`ban_pick_ban.lua:10-12`); guests send their own bans to `order[1]` (the host slot, `ban_pick.lua:121-136,1203`). The randomized *acting* first player is `state.first`, independent of routing order — don't conflate the two (`ban_pick.lua:138-141`).
- **Best-of-3 decks/seeds are positional and derived.** Run N uses survivor N and `derive_seed(base, N)`; `_run_count` counts *completed* runs, so the live run is `_run_count + 1` (`white_stake_triple.lua:36-38`, `run_start.lua:87-88`). A same-seed restart must reuse the current run's live seed and deck, not re-derive run 1's (`run_start.lua:76-100`).
- **`on_ante_change` fires inside `ease_ante` — never restart synchronously there.** The deferred-event wrapper (`white_stake_triple.lua:54-63`) and `teardown_existing_run`'s HUD/`G.TAROT_INTERRUPT` cleanup (`run_start.lua:1-21`, `white_stake_triple.lua:83-86`) each pin a real crash; removing either regresses it.
- **Lobby kind is client-local state, not metadata.** UI and start routing read `SPDRN._lobby_kind` synchronously (`kind.lua:1-6`); metadata `kind` is informational. Every entry path sets it and every exit path (`queue.lua:70,87`, `ui/lobby/events.lua:68`) clears it — a path that forgets to clear leaks matchmaking behavior into the next private lobby.
- **Ready is racy by design, patched twice.** A guest's first ready can beat the host's topic subscription, so there is a resync loop (`ready.lua:16-28`) *and* a one-shot guest re-announce when it hears a peer (`player_ready.lua:9-18`); the start broadcast stops the loop (`start_game.lua:28-29`). `maybe_autostart` must broadcast exactly once (`ready.lua:74-96`).
- **Test-fixture drift:** the in-game `BInt` ban-pick tests still hand-build the pre-schedule state shape (`turn_index`/`bans_remaining`, `tests/ban_pick.lua:17-26`), while the engine now walks `schedule`/`sched_index` (`ban_pick.lua:1137-1173`). Treat green/red from that suite with suspicion until the fixtures are migrated; the standalone luajit tests (`tests/vanilla_draft_pool.lua:4`) drive the current pure builders.

## 6. Review lens

- **Thinness is the feature.** New Speedrun behavior should be a gamemode field, a `BanPick.start` config entry, or a small ActionType — if a PR copies engine logic (turn validation, state broadcast, pool building, countdown) into the consumer, push it back to MPAPI or reuse the seam (`start_game.lua:38-50` is the whole draft integration).
- **Kind routing:** does every branch in a touched flow behave for all four kinds? Check `start_game.lua:31-61` style dispatch and the end-screen matrix (`ui/lose_screen.lua:57-76`); practice must never touch server handles (`run_timing.lua:5-6`).
- **Pool changes:** matchmade drafts must call `SPDRN.vanilla_draft_pool` with the gamemode's `pool_size`, keep the list explicit, and keep `rng` injectable (`vanilla_pool.lua:22`, `start_game.lua:43-45`).
- **Host-only side effects:** `mark_run_started`, `report_match_result`, ban application, and auto-start are all host-gated with self-guards; a PR that drops a `lobby.is_host` / `handle.match_id` check double-reports or lets guests mutate the draft (`run_timing.lua:5-11`, `result.lua:5-12`, `ban_pick_ban.lua:10`).
- **Multi-run math:** any change near `_run_count`, `_run_decks`, `derive_seed`, or restart must keep decks and seeds positionally consistent across all clients — same-index deck + derived seed, restart preserves the instance (`white_stake_triple.lua:29-63`, `run_start.lua:74-101`).
- **Deferred restarts + teardown:** anything that calls `start_run`/`G.FUNCS.start_run` must go through `safe_start_run` or an explicit deferred event *after* `teardown_existing_run` (`run_start.lua:23-35`); a synchronous restart inside a game callback is an instant-crash smell.
