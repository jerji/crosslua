# Study — spaced-repetition flashcards for the X4

FSRS-5 scheduling (the algorithm modern Anki uses) plus Anki-style learning steps (1 m, 10 m; relearn 10 m).
The scheduler is a line-for-line Lua port of [crossplay](https://github.com/ma-r-s/crossplay)'s `StudyFsrs.cpp` /
`StudyScheduler.cpp` (MIT) and is checked against the original C++ on 9,179 answers
(`test/lua_host/golden/`, run by `test/lua_host/run.sh`).

## Using it
* Home → Plugins → **Study**. Pick a deck, **Confirm** opens it.
* Card front: **Confirm** shows the answer. Answer screen (labels are above the buttons, with the next interval):
  **Back** = Again · **Confirm** = Good · **Left** = Hard · **Right** = Easy. (Side buttons: Up = Again, Down = Good.)
  So the usual card is *Confirm, Confirm*.
* Back on a card front returns to the deck list. Hold Back 1 s to quit the app at any time. Progress is saved after
  every answer.
* 10 new cards/day, 100 reviews/day (constants at the top of `main.lua`).
* Dates need a clock. The X4 has no battery clock; it is set when WiFi connects. Without one the header says
  *no clock* and review days stop advancing (nothing is corrupted).

## Decks
Put `.tsv` or `.txt` files in `decks/` (next to the app) or in `/.crosslua/data/study_lua/decks/` on the card. One card
per line, tab separated: `front<TAB>back[<TAB>more]`. Lines starting with `#` are ignored.

* **Anki import:** *File → Export → Notes in Plain Text* gives exactly this format (HTML is cleaned for you:
  `<br>`/`<div>` → line breaks, tags removed, entities decoded, `[sound:…]` dropped; arrows/dashes become ASCII).
* **Cloze:** a front containing `{{c1::answer}}` or `{{c1::answer::hint}}` shows `[...]` / `[hint]` and reveals the
  full sentence on the back.
* **Append new cards at the END of the file.** Progress is stored by line position (editing the middle shifts it).
* Decks of several thousand cards are fine: nothing about the cards is kept in RAM (see `store.lua`).
* Included: `decks/ports.tsv` (common network ports, protocols, a few cloze cards).

## Storage (all under `/.crosslua/data/study_lua/study/<deck>/`)
`index.bin` (line offsets), `cards.bin` (24 bytes/card, updated in place), `meta.json` (daily counters). Delete a
folder to reset that deck.

## Not (yet) here
Undo, per-deck options, FSRS parameter optimisation, images/audio, Anki `.apkg` import.
