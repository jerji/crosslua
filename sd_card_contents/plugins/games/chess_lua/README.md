# Chess (CrossLua)

Chess for the X4, ported from crossplay's C++ chess app
(`src/apps_local/chess/` and the `link/` play-nearby layer). Plays against
the device's engine, against a person sharing the device (pass-and-play or
face-to-face), or against a nearby device over ESP-NOW.

```
main.lua    screens and flow (menu, settings, board, play nearby)
chess.lua   the rules engine: movegen, make/unmake, FEN, SAN, repetition keys
engine.lua  the opponent: negamax alpha-beta, MVV-LVA ordering, node budget
link.lua    the ESP-NOW session: search, match, turns, notes, bye
art.lua     piece silhouette bitmaps (hex) for the white-piece knockout
art/*.bmp   the celtic piece set, 6 types x 2 colours x 2 sizes
```

## Rules

Legal move generation (castling through check, en passant, promotion,
discovered pins) is a direct port of `ChessCore.cpp` and is verified against
it: perft counts on the standard positions match the C++ core exactly
(depth 2 from the opening = 400). The four ways a game ends are the C++'s:
checkmate and stalemate read off the position; threefold repetition and the
fifty-move rule are facts about the game (history keys, windowed by the
halfmove clock), owned by the same `refreshLegalMoves` that sets `gameOver`.

## Engine

Same shape as `ChessEngine.cpp`: negamax with alpha-beta, MVV-LVA ordering,
piece-square tables, mate scores shrinking with distance, and a node budget
as the safety net. The depth cap is sized for the device (the Lua runtime
runs ~435k VM ops/s on the X4):

| search | nodes (opening) | estimated device time |
|---|---|---|
| depth 1 (EASY)      | 20   | ~0.2s   |
| depth 2 (NORMAL)    | 113  | ~2s     |
| depth 3 (HARD)      | 1035 | ~15s    |

`MAX_DEPTH` is 3 where the C++ caps at 4; the level map is the C++'s 1/3/4
scaled down one ply. `playEngineMove()` always searches a COPY of the board,
so the panel never shows a mid-search position.

## Play nearby

The session is a port of `LinkSession`/`LinkPlay`'s semantics over ESP-NOW
with the text-frame style of `play_nearby_ttt_lua`:

- the payload is the WHOLE position (FEN + last SAN), not a move, so a lost
  packet is a stale frame the next one corrects;
- turns strictly alternate; host is elected by coin toss per search (ties by
  lower MAC), exactly like the C++ — nothing for the user to pick;
- unacknowledged states retransmit every 400ms; a side with nothing to say
  re-acks every 1000ms (the liveness signal); 10s of silence = lost;
- one-byte notes (play-again / leaving) ride their own sequence so a rematch
  can be asked exactly when there is no turn left to carry it.

The host-tested link logic lives in `test_link.lua` (a full match, a dropped
state frame healed by retransmit, a silent-peer timeout). Match screens keep
the design doc's rules: the final board holds ~2.5s and outranks even the
opponent leaving; PLAY AGAIN asks the other device; Back tells them and
restores the solo game; nothing is saved during a match.

## Deviations from the C++ (with reasons)

- **Cursor, not touch.** The Lua runtime exposes seven buttons and no touch
  API; the board plays with a D-pad cursor + Confirm, like the other Lua
  board games. The gear (settings) is reached by pressing Up past the top
  rank; Confirm opens it.
- **Depth map 1/2/3 vs 1/3/4** — see the table above; 4 plies would take
  minutes.
- **Text wire format** (TTT style) instead of the C++ binary XLNK frames.
  Same session, different codec; Lua and C++ builds do not interoperate (the
  C++ chess never shipped on the Lua runtime).
- **Turn capsule says "YOUR MOVE"/"THEIR MOVE"** — the Lua runtime has no
  player-name store, so the C++'s "CALM FINCH'S MOVE" is not reproducible.
- **Repetition keys are strings** (67-byte fingerprints) instead of
  FNV-1a 64-bit: string keys cannot collide in Lua, which the C++ hash
  strictly can; the en-passant square is included raw, exactly like the C++.
- **Save/settings in `data:` scope** (`data:chess.sav` / `data:chess.cfg`)
  instead of `/.crosspoint/`; same formats otherwise.
- **Endgame hold** counts from the game-over moment, since Lua paints
  synchronously (no second render task to race).
- **No `PLAY NEARBY` persistence**, matching "multiplayer is an action":
  every entry starts at the MENU with the radio off.

## Things the design doc wants that the API does not have

- **Auto-sleep hooks.** The C++ saves the solo game in `onExit()` (sleep,
  app switch). The Lua API has no onExit/onSleep callback, so a device that
  falls asleep on its own mid-game cannot be intercepted to save; the last
  completed pair is saved instead (and Back always saves).
- **Sleep suppression during a match.** The C++ link layer keeps the device
  awake (`wantsAwake`). Lua has no sleep-suppression API; the match loop
  uses `input.poll()` + `app.sleep(30)` so the session keeps ticking, but a
  very long idle stretch still risks the auto-sleep timer. A sleep during a
  match ends it (the peer times out after 10s), which is the C++ behavior
  anyway ("a match lives only while both apps are open").

## Verify

```
luac5.4 -p main.lua chess.lua engine.lua link.lua art.lua     # syntax
# scratch tests (host Lua, no device):
lua5.4 test_logic.lua   # perft vs the C++ core, end kinds, engine mates
lua5.4 test_link.lua    # whole match over a fake radio, loss, silence
# smoke:
lua5.4 scratch/smoke/run.lua chess_lua 'confirm,back'
```