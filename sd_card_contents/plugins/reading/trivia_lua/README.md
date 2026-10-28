# TRIVIA (CrossLua port)

A port of the crossplay TRIVIA app. The questions live in a binary pack on the
SD card; this app reads them, serves them in two modes, and keeps per-device
state beside the pack.

## What you need to play

Put a pack at **`Trivia/pack.dat`** on the card (the folder is named `Trivia`
at the card's root). This app ships a tiny starter: copy

    plugins/trivia_lua/sample_pack.dat   →   Trivia/pack.dat

(six questions across all five levels, one US-flagged, one quizmaster-only).
For the real fifty-thousand-question pack, follow the crossplay repo's
`trivia-pack` GitHub prerelease; any pack built by `build_pack.py` or
`assemble_pack.py` works unchanged, because the format is identical.

On first launch the device asks to read **and write** the `Trivia` folder.
The read grant is for the pack; the write grant is for `pack.state` (which
questions this device has seen / flagged) and `prefs` (the difficulty), the
same two files the C++ app maintains — a card played by both apps shares
difficulty and flags.

## Controls (seven buttons, no touch)

Every screen's footer is one-to-one with the C++ hit boxes:

| button   | play screens                               |
|----------|--------------------------------------------|
| confirm  | primary: REVEAL / NEXT / pick an option    |
| left     | HIDE (once the answer is showing)          |
| right    | END (does not move between screens)        |
| up/down  | move the cursor in lists / the four options|
| back     | END on play screens, back up elsewhere     |

- **QUIZMASTER**: confirm reveals the answer; the room argues. HIDE flags the
  question so the chooser never serves it again; WHY? attaches a reason, UNDO
  takes the flag back.
- **SOLO**: four options, scored. The score resets when you enter solo and is
  never saved — a bar game's score belongs to the evening. Ending the round
  shows ROUND OVER: "You got N of M."
- **DIFFICULTY** cycles Any → 1..5 on the front door and is saved to
  `Trivia/prefs`.
- **SETTINGS**: US QUESTIONS (off by default — the pack ships international;
  turning it on deals the flagged questions) and HIDDEN QUESTIONS (count +
  show them all again).

## Files

- `core.lua` — the pack reader, state, chooser, options and scoring; pure Lua
  and host-testable (the logic test runs it under `lua5.4` against a file
  shim).
- `main.lua` — the UI.
- `sample_pack.dat` — the six-question starter pack, built by hand from the
  format spec (`docs/apps/trivia-pack-format.md`); regenerate with the
  builder in the scratch folder.

## How the pack format works (summary)

`pack.dat`: magic `XTRIVIA\0`, version u16 = 1, count u32, then
(count+1) u32 offsets (relative to the blob start, the last one the blob's
size), then the records. Each record: difficulty u8 (bit 7 = US-centric
flag), year u16, alternate count u8, distractor count u8, then
(2 + alts + wrongs) fields of (u16 length + UTF-8 bytes): question, answer,
alternates, distractors. A record over 448 bytes is rejected, never
truncated. `pack.state` is exactly `count` bytes, bit 0 SEEN / bit 1 FLAGGED
at the question's own index; any length disagreement with the pack means the
pack was replaced and the file is rebuilt. `prefs` is one byte: the
difficulty (0 = any).

## Differences from the crossplay app

- **No download and no SYNC.** Those need a hardcoded host and the network;
  this port deliberately has neither. The no-pack screen says where to put a
  pack instead. `Trivia/pack.meta` (the build id) is therefore never written
  and reporting is never queued — exactly the C++ behaviour when the build is
  unknown, which is the honest state for a hand-copied pack.
- **WHY? reasons** go to `data:trivia/reports.log` instead of the reports
  queue, because the queue's header requires the pack id that only SYNC can
  establish. The FLAGGED bit itself always lands in `pack.state` on the card.
- **US QUESTIONS** is stored in `data:trivia/us`, a copy of the C++ app's
  shared firmware setting, which the Lua sandbox cannot reach.
- **Button navigation** replaces touch; the clue is set in `sans18` (the
  reading serif is not in the Lua font set) and wrapped by measured width.