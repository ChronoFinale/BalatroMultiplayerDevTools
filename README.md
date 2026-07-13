# Multiplayer DevTools

A standalone SMODS mod that adds **dev-only account impersonation** for local
testing of [BalatroMultiplayerAPI](https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI)
(matchmaking, PvP, etc.) without needing a second Steam login per test
instance.

It is a separate mod from `MultiplayerAPI`, in its own repository: the API mod
is identical for every user, release or developer. Dev capability comes from
installing/enabling this mod, nothing else.

## What it does

- Boot-time impersonation via env vars, read before the game connects:
  - `BMP_IMPERSONATE_ID=<players.id uuid>`
  - `BMP_IMPERSONATE_NAME=<steamName>` (any name — the dev server creates the
    account on first login if it doesn't exist)
  - Neither set -> falls through to real Steam auth.
- A **DEV** button embedded in the Multiplayer account panel (main menu) that
  opens a picker to switch which account the running client is authenticated
  as at runtime, without restarting. Type any name (created on demand) or a
  player uuid, or use the quick-select buttons.
- Both paths log in via the dev server's impersonation endpoint (404s in
  production — requires `MPAPI.config.use_custom_server` pointed at a local
  dev server running `NODE_ENV=development`). Impersonated accounts are real
  `players` rows, so they can queue matchmaking and appear on the leaderboard
  like a real player.

## Install

This mod **depends on `MultiplayerAPI`** (declared in `MPAPIDevTools.json`),
which must also be installed.

Copy or junction this repository into your Mods folder like any other mod:

```
mklink /J "%AppData%\Balatro\Mods\MPAPIDevTools" "<path to this repo>"
```

(or the equivalent symlink on macOS/Linux, or just copy the folder.)

Enable/disable it like any mod — via the SMODS mod manager, or by adding a
`.lovelyignore` file to the folder.

## Testing

Pure-core unit tests, no game/mod runtime needed:

```
luajit test_impersonation.lua
```
