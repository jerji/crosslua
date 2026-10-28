# 2048

Slide tiles with **Left / Right** (front buttons) and **Up / Down** (side buttons); equal tiles merge. **Confirm** undoes
the last move (one level). **Back** opens a menu (Resume / New game / Exit). The game and your best score are saved after
every move, so quitting (even holding Back) never loses anything.

Tiles are drawn as outlines up to 16, solid black from 32; 2048 gets a white inner frame. Keep playing after 2048.

`game.lua` holds the rules and has no device calls (unit-tested on the host).
