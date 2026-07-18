# Balatro Multiplayer — Ecosystem Field Guide

For contributors who need to review and commit across the whole mod family in
finite time. Written for an experienced developer (assumes ~Java-shaped
instincts) who is new to Lua and to this codebase. Companion docs:
[VERIFICATION.md](VERIFICATION.md) (visual test gallery), each repo's
`agents.md`/`.claude/` context files.

---

## Part 1 · Lua for the Java developer

Lua is what you'd get if you deleted everything from Java except objects,
lambdas, and maps — then merged those three into one construct. Almost every
"weird" thing below is that one idea playing out.

### The one construct: tables

A table is simultaneously your `HashMap`, `ArrayList`, object, namespace,
package, and enum:

```lua
local lobby = { code = 'ABCD', players = {} }   -- object with fields
lobby.players[1] = { id = 'p1' }                -- list (1-INDEXED. Always.)
MP.LOBBY = lobby                                -- namespace member
```

| Java thing | Lua equivalent |
|---|---|
| class + fields | table with keys |
| method | function stored in a table; `obj:method(x)` is sugar for `obj.method(obj, x)` — the colon passes `self` |
| interface | duck typing: "has a `leave()` function" IS the interface (see the fake lobby in the shot harness satisfying the real lobby contract) |
| package/import | a module file `return`s a table; loader assigns it somewhere reachable |
| `private` | file-scoped `local` variables — `local _selected = {}` at the top of `ban_pick.lua` is a private static field; nothing outside the file can touch it |
| `static` | module-local state (same `local` mechanism) |
| enum | string constants (`'ban'`, `'pick'`) — compared by value, no type safety |
| `null` | `nil` — but assigning `t.k = nil` DELETES the key, and `#list` is undefined with nil holes |
| exceptions | `pcall(f, args)` returns `ok, result_or_error` — try/catch as a function call. Convention here: effectful calls that may fail return `nil, err` instead of throwing |
| generics/types | none. Discipline substitutes: naming conventions, `expect`-style doc comments, and tests. This is WHY the test culture here is strict |

### Five traps that bite Java instincts

1. **Globals by default.** `x = 1` inside a function creates a *global*.
   Everything must be declared `local`. (Un-`local`ed helpers are the classic
   review catch.)
2. **Only `nil` and `false` are falsy.** `0` and `""` are TRUE. `if count then`
   passes when count is 0.
3. **1-indexing** — `for i = 1, #list`. Off-by-ones hide in ported brain-code.
4. **`t.method()` vs `t:method()`** — dot call forgets `self`; symptom is
   "attempt to index nil (local 'self')".
5. **Closures capture variables, not values** — the standard callback idiom
   here (`function() return pool end` passed as `build_pool`) leans on this;
   loop-variable capture works per-iteration (unlike old Java anon-class pain).

### Encapsulation, this-codebase style

There are no classes in the mod code (the *engine* uses metatable OO — you
consume it, rarely write it). The dominant unit is the **module with private
state and an exported surface**:

```lua
-- ban_pick.lua shape
local _selected = {}                  -- private field
local function selection_toggle(...)  -- private method (pure!)
BP.request_ban = function(...)        -- public API
BP._selection = { toggle = ... }      -- test seam, underscore = "for tests"
```

Read any file top-to-bottom as: privates → pure core → effectful public
surface → engine handlers (`G.FUNCS.*` = button callbacks registered globally).

### The engine's OO (what `Card`, `UIBox`, `Moveable` are)

Vanilla uses metatable inheritance: `Card` "extends" `Moveable` extends
`Node`. Two things matter for review:

- **Instance method override**: `function card:click() ... end` on ONE object
  shadows the class method — the codebase's standard way to change behavior of
  a single UI element (see `deck_tile`). Like an anonymous subclass at runtime.
- Calling the parent: `Node.hover(self)` — explicit, no `super`.

---

## Part 2 · The layer map

```
┌───────────────────────────────────────────────────────────────────────┐
│ 5 SERVER   Express 5 + EMQX (MQTT) + Postgres · D:\Things10\server    │
│            normal backend engineering; your Java instincts transfer   │
├───────────────────────────────────────────────────────────────────────┤
│ 4 CONSUMER MODS   MultiplayerPvP · BalatroSpeedrunning                │
│            thin bridges: API events → mod globals; gamemode rules     │
├───────────────────────────────────────────────────────────────────────┤
│ 3 API FRAMEWORK   BalatroMultiplayerAPI ("MPAPI")                     │
│            lobby/matchmaking state machines, ban-pick engine,         │
│            api_client (HTTP-over-MQTT, FIFO), auth, shared UI         │
├───────────────────────────────────────────────────────────────────────┤
│ 2 LOADERS   Lovely (binary patcher, lovely/*.toml) · SMODS (mod       │
│            loader: manifests, priorities, centers, localization)      │
├───────────────────────────────────────────────────────────────────────┤
│ 1 VANILLA ENGINE   LOVE2D + Balatro source (read-only reference)      │
│            G.E_MANAGER events · Moveable · UIBox/UIElement · CardArea │
└───────────────────────────────────────────────────────────────────────┘
```

**Where expertise concentrates:** layer 1 is deep but you learn it
symptom-driven (grep the vanilla source when something misbehaves — it's at
`D:\SteamLibrary\steamapps\common\Balatro\Balatro\`). Layer 3 is where most
review time goes. Layer 4 is thin *by design* — if a consumer PR is fat,
that's itself a finding.

### Layer-1 primitives worth knowing cold (each cost us a real bug)

- **`G.E_MANAGER`**: everything is queued `Event`s. `trigger='after'` +
  `delay`; `blockable/blocking` flags; **`no_delete = true` survives
  `clear_queue()`** (run start wipes the queue — killed our shot runner once).
- **`Moveable` alignment**: minor objects follow a `major` via bonds; a
  STATIONARY major skips re-alignment of children (why clamping a popup's
  outer box moved nothing); vanilla `Card:move` re-applies popup alignment
  EVERY frame (why one-shot mutations get overwritten).
- **`UIBox/UIElement`**: clickability decided ONCE at build (`config.button`
  present or forever inert — the `can_play` disable-by-nulling pattern);
  `ref_table`/`ref_value` text re-reads every frame (live counters for free);
  DynaText/UIBox objects self-register at construction → build popup content
  LAZILY or orphans draw at the origin.
- **`CardArea`**: `emplace → set_ranks` mutates state (drag!) of every card
  already in the area — per-card setup before later emplaces gets undone.

---

## Part 3 · Guided reading tour (~10 files, in order)

Read with the stated question in mind; each file answers one.

1. **PvP `agents.md`** — orientation. *How does the whole mod fit together?*
2. **API `api/lobby.lua`** — the central object. *What events exist, what does
   `get_metadata` carry, who is host?*
3. **PvP `pvp_api/lobby_bridge.lua`** — THE consumer pattern. *How do API
   events become `MP.LOBBY`/`MP.GAME` mutations? Note `decide_departure_action`
   consuming plain state — pure-core in the wild.*
4. **API `api/ban_pick.lua`** (skim, it's ~1400 lines) — the richest module.
   *Find: private state block, pure selection layer, host-authoritative
   `apply_action`, staleness guard (`draft_id`/serial), `G.FUNCS` handlers.*
5. **API `networking/api_client/client.lua`** — transport. *Why FIFO? What
   happens when the worker dies?*
6. **API `api/matchmaking/queue_guard.lua`** — smallest complete feature.
   *The `guard_queued(replay)` contract; why must consumers pass their OWN
   entry point?* (The doc comment answers it — stranding.)
7. **PvP `pvp_api/draft_pool.lua`** — degradation done right. *Trace every
   fallback: no server → local; bad pool → local; old API → local.*
8. **Speedrun `objects/actions/start_game.lua`** — a second consumer for
   contrast. *Same BanPick engine, different config; where does the vanilla
   pool restriction live?*
9. **Server `features/draft/draft.service.ts`** — the recorder-not-referee
   philosophy. *Why does validation flag-and-log instead of reject?*
10. **DevTools `screenshot_suite.lua`** — the harness. *How does a fake lobby
    satisfy the real contract? What did ambient systems force it to stub?*

---

## Part 4 · The six patterns (review against these)

1. **Host-authoritative shared state.** One writer (host) owns canonical
   state, validates every action *regardless of what the UI allowed*, and
   broadcasts FULL state; guests wholesale-replace and re-render. Never patch
   guest-side, never trust a client. Reference: `ban_pick.lua`
   (`apply_action` → `broadcast_state` → `on_state`).
2. **Staleness guards on every async consumer.** Broadcasts and callbacks
   arrive late/duplicated/reordered: scope watermarks per-epoch
   (`draft_id` + serial), dead-set finished epochs, and re-check "is this
   still the current lobby?" after every async hop (`fetch` callbacks in
   `actions.lua`).
3. **Pure decisions, thin shells.** Branching lives in pure functions taking
   plain tables (`decide_departure_action`, `selection_toggle`,
   `popup_clamp_y`, `vanilla_draft_pool`); handlers gather → decide → act.
   Inject rng/clock (`rng = rng or math.random`). If a test needs a stubbed
   `G` to check a *decision*, the decision is in the wrong place.
4. **Build-time vs frame-time in the engine.** Structure (clickability,
   registered objects) is fixed at UIBox build; behavior changes happen in
   per-frame `func`s (disable-by-nulling `config.button`, live `ref_table`
   text, move-wrapper clamps). Adding structure after build silently fails.
5. **Localization is a shared dictionary.** Every user string goes through
   `localize()` with a key; en-us files are shared across the family — merge
   conflicts resolve as a UNION or players see literal `ERROR`.
6. **Graceful degradation across version skew.** Any pairing of old/new
   server, API, and consumer must limp, not crash: feature-detect
   (`if not MPAPI.matchmaking.fetch_draft_pool then`), fall back locally,
   log a warning, never surface failure to the player.

---

## Part 5 · Review checklists by PR type

**Any PR:** tests included and green · every string localized (key in a
dictionary) · conventional commit, no trailers · small enough to hold in your
head (if not, that's the first comment).

**Engine/UI PR (touches `ui/`, `G.FUNCS`, UIBoxes):**
- [ ] Buttons declare `config.button` at build; disabling nulls it per frame
- [ ] No DynaText/UIBox constructed outside an immediately-placed tree
- [ ] Per-element behavior via instance method override, vanilla restored/called (`Node.hover(self)`)
- [ ] Anything positioned dynamically: what happens when its anchor MOVES? when it's stationary?
- [ ] After-emplace mutations (drag, states) done AFTER all emplaces
- [ ] New user-visible state → `dev/shots.lua` scenario with an `expect`

**Networking/state PR:**
- [ ] Who is the single writer? Can a guest mutate shared state? (fail if yes)
- [ ] Every async callback staleness-checked (epoch/serial or current-lobby)
- [ ] Host validates independent of UI gating
- [ ] Old-peer/old-server combinations degrade with a logged fallback
- [ ] Lifecycle flags cleared on EVERY exit path (leave, disconnect, teardown)

**Consumer-mod PR (PvP/Speedrun):**
- [ ] Stays a thin bridge — API events → mod state; no protocol logic here
- [ ] Guard replays re-enter the consumer's OWN full entry point, never an API primitive
- [ ] Matchmade-only behavior gated on `is_matchmaking()`; custom lobbies untouched

**Server PR:** normal backend review (types, injection, tests) + the local
philosophy: the server records and flags, it does not referee the client game.

---

## Part 6 · Becoming fast (the meta)

- Review PRs smallest-first; the queue doubles as a curriculum.
- When code surprises you, ask the agent *why* before reading further — the
  answer usually names one of the six patterns or a layer-1 primitive.
- Own one bug end-to-end periodically, agent as navigator only.
- Use the shot harness as a laboratory: stage a state you don't understand,
  screenshot it, read backward from pixels to code.
- Grep vanilla on symptom, not curiosity: `grep -rn "set_ranks" <balatro-src>`
  answers in seconds what speculation burns hours on.
- Expect adversarially-reviewed branches: your review is for design judgment
  ("is this the right behavior for players?"), not bug-hunting — the findings
  log tells you where machines already looked.
