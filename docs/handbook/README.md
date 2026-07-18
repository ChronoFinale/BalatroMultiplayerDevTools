# Ecosystem Handbook

This handbook is the depth layer for the Balatro Multiplayer ecosystem: nine
chapters, one per architectural layer, each written for a contributor who has to
*review and commit* against that layer — not just read around it. Where the
[Field Guide](../FIELD-GUIDE.md) is the **map** (Lua-for-Java-devs, the five-layer
stack diagram, the six review patterns, and the PR checklists), each chapter here
is the **territory**: what the layer owns, the key files with the one load-bearing
fact per file, how the machinery actually works, and the gotchas that each cost a
real bug. Read the Field Guide first to orient; drop into a chapter when a PR
lands on that layer and you need to know the exact seams, invariants, and failure
modes before you can judge the change.

The mapping is deliberate. Field-Guide **Part 2 · The layer map** names five
layers; the chapters expand them. Layer 1 (vanilla engine) → ch. 01. Layer 2
(loaders) → ch. 02. Layer 3 (the MPAPI framework — where most review time goes)
splits across ch. 03–06 because it is the largest surface: core connection/lobby/
actions, matchmaking, the ban-pick engine, and transport each get their own
chapter. Layer 4 (consumer mods) → ch. 07 (PvP) and ch. 08 (Speedrun, the
contrast case that proves the seams are real). Layer 5 (backend) → ch. 09. Every
chapter reinforces the same six patterns the Field Guide lists — host-authoritative
state, staleness guards, pure decisions in thin shells, build-time vs frame-time,
shared localization, graceful degradation — so the two documents cite the same
vocabulary from opposite altitudes.

## Chapters

| # | Chapter | Layer | The hook |
|---|---|---|---|
| 01 | [Vanilla Engine Primitives](01-vanilla-engine.md) | 1 · Engine | Everything mods hook lands here: one `Game:update` per frame, the five-queue event manager, Moveable target/visible transforms, and UIBox clickability fixed once at build. |
| 02 | [Loaders: Lovely + SMODS](02-loaders.md) | 2 · Loaders | Everything before a line of MP logic runs — Lovely rewrites vanilla source via regex TOML patches, SMODS resolves manifests/priorities and injects centers into `G.P_CENTERS`. |
| 03 | [MPAPI core: connection, lobby, actions](03-api-core.md) | 3 · Framework | The client-side multiplayer kernel: the auth/connection state machine, the lobby event emitter, and the schema-validated ActionType send/broadcast framework — all callback-driven, nothing blocks. |
| 04 | [Matchmaking (API layer)](04-matchmaking.md) | 3 · Framework | The client half of ranked/queued play: synchronous queue handles, one personal MQTT topic, the match-found → `LOBBY_READY` auto-join, and the leave-or-stay queue guard. |
| 05 | [The Ban-Pick Draft Engine](05-banpick-engine.md) | 3 · Framework | A generic host-authoritative turn-based draft: host validates and rebroadcasts full canonical state, guests only request; draft_id epochs + serial watermarks guard staleness; the whole draft UI lives here too. |
| 06 | [Transport: MQTT worker + api_client](06-transport.md) | 3 · Framework | The only code that touches the network — one Love2D worker thread runs MQTT *and* all HTTPS (HTTP does **not** travel over MQTT), with `\1`-delimited channel commands and FIFO response correlation. |
| 07 | [The MultiplayerPvP Consumer Mod](07-pvp-consumer.md) | 4 · Consumer | The adapter that runs legacy Multiplayer on the new MQTT API: two one-way bridges (`Client.send` → `pvp_*` broadcasts, API events → `MP.LOBBY`), a host-side referee, and pure-Lua departure/forfeit cores. |
| 08 | [The Speedrun Consumer Mod](08-speedrun-consumer.md) | 4 · Consumer | The second consumer and proof the seams are real: two race-to-ante-9 gamemodes in ~600 lines by consuming MPAPI's lobby/action/matchmaking/ban-pick engines instead of reimplementing them. |
| 09 | [The Backend Server](09-server.md) | 5 · Server | Express 5 + EMQX + Postgres: authenticates players, fences every MQTT connect/publish/subscribe via EMQX webhooks, runs the 2s matchmaking loop, applies Elo in one transaction — a recorder with opinions, not a referee. |

## Suggested reading order

The chapters are numbered bottom-up (engine → server). You do not have to read
them in order — read toward the layer your first PRs will hit.

**(a) Reviewing UI PRs first** — start where clickability, layout, and draw
order are decided, then follow the UI up through the framework and into a consumer:

1. Field Guide, **Parts 1–2** (Lua idioms + the layer map) — orientation.
2. **01 · Vanilla Engine** — the substrate every UIBox, Moveable, and Controller
   click resolves against; build-time vs frame-time is the whole game.
3. **05 · Ban-Pick Engine** — the richest UI in the codebase (deck tiles,
   Confirm/Random row, hover popups, on-screen clamping) over host-authoritative state.
4. **03 · MPAPI core** — the lobby object and shared account/UI surface the views render.
5. **07 · PvP Consumer** — the lobby view, ready system, and in-game HUD/round flow.
6. **02 · Loaders** — last, for the localization-union rule (Field-Guide pattern 5)
   that every user-visible string in a UI PR must satisfy.

**(b) Reviewing networking PRs first** — start at the wire and work up through the
state machines to the authority and the backend:

1. Field Guide, **Parts 1–2**, then **Part 4** (the six patterns).
2. **06 · Transport** — the worker thread, the channel protocol, FIFO correlation,
   and the HTTP-is-not-over-MQTT correction to internalize before anything else.
3. **03 · MPAPI core** — the connection/auth state machine and the ActionType
   send/broadcast/dispatch framework everything else rides on.
4. **04 · Matchmaking** — queues, handles, the personal topic, and match-found routing.
5. **09 · Backend Server** — the authoritative other end: EMQX webhook fencing,
   the 2s matchmaking loop, and the Elo transaction.
6. **05 · Ban-Pick Engine** — host-authoritative shared state and staleness guards,
   the canonical reference for Field-Guide patterns 1 and 2.
7. **07 · PvP Consumer** then **08 · Speedrun** — how two consumers wire the
   above into wire vocabularies that never collide.
