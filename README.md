# Balatro Multiplayer DevTools

Dev-only toolbox for working on the Balatro Multiplayer stack
([BalatroMultiplayerAPI](https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI)
and its consumer mods). Install it alongside the mods you develop; never ship
it to players.

## Install

Clone into your Balatro `Mods` folder (or junction it there):

```powershell
git clone https://github.com/ChronoFinale/BalatroMultiplayerDevTools "$env:APPDATA\Balatro\Mods\BalatroMultiplayerDevTools"
```

Requires Steamodded and the MultiplayerAPI mod. Everything here assumes a
local dev server (`use_custom_server`) — the impersonation endpoint 404s in
production by design.

## What's in the box

### Per-window auto-login (instance slots)

Launch the game twice with zero setup: the first window logs in as
`Player001`, the second as `Player002` (up to `Player004`). Each instance
claims a slot by binding a localhost port (45601+) for its lifetime, so slots
never collide and free themselves on exit. Override per window with
`BMP_IMPERSONATE_NAME` / `BMP_IMPERSONATE_ID`; the slot identity prefills the
in-client picker.

### Account impersonation picker

A DEV row in the Multiplayer account panel: switch which player this instance
is authenticated as at runtime (name or uuid), without relaunching.

### Visual test harness (`DEVTOOLS.shots`)

Scripted UI scenarios -> screenshots, driven through the REAL engine and UI
on a loopback lobby (no server, no second window needed):

```powershell
# run all scenarios and quit (~90s): PNGs + gallery.html + manifest.json
$env:BMP_SHOT_SUITE = "1"; & "<path-to>\Balatro.exe"

# review
start "$env:APPDATA\Balatro\shot_suite\gallery.html"
```

Each scenario carries an `expect` caption describing what a correct shot
shows — scroll the gallery and flag anything abnormal.

This mod is only the RUNNER. Scenarios live in the repos whose code they
cover, as an inert `dev/shots.lua` the mod itself never loads (the API
repo's is the reference example). The harness discovers those files at the
start of a run; nothing loads or executes on normal boots:

```lua
-- <your-mod>/dev/shots.lua
return function(H)  -- H: start_draft / find_tile / find_ui helpers
    return {
        {
            name = '01-my-scene',
            expect = 'what a correct shot shows',
            setup = function(done) --[[ stage the scene ]] done() end,
        },
    }
end
```

Optional golden diffing (a pointer to what changed, not a pass/fail gate):

```powershell
python tools/compare_shots.py            # diff current run vs goldens/
python tools/compare_shots.py --accept   # promote current run to goldens
```
