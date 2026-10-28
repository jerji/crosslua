#pragma once
// CrossLua dev/test aid: records what the renderer draws so a host can read the screen as TEXT over serial
// (`CMD:SCREEN`) instead of decoding a screenshot. Compiled only when CROSSLUA_DEV is defined; costs ~6 KB RAM.
//
// A "frame" = everything drawn between clearScreen() and displayBuffer(). commitFrame() publishes it, dump()
// prints the last published frame:
//   SCREEN_START:<seq>:<activity>:<w>x<h>
//   T <x> <y> <fontId> <text>            one per drawText (logical screen coordinates, y = top of line)
//   R <x> <y> <w> <h> <color>            one per fillRect/fillRectDither
//                                        (color: 16=black 1=white 5=lightgray 10=darkgray)
//   SCREEN_END
#ifdef CROSSLUA_DEV
#include <Print.h>

#include <cstdint>

namespace devcapture {
void beginFrame();
void text(int fontId, int x, int y, const char* s);
void rect(int x, int y, int w, int h, int color);
void commitFrame();
// While alive, rect() calls are ignored (a rounded rect is recorded once, not as its dozen internal fills).
struct Suppress {
  Suppress();
  ~Suppress();
};
void dump(Print& out, const char* activity, int screenW, int screenH);
}  // namespace devcapture
#endif

// Dev/test serial channel pump, defined in main.cpp (this header is included there). Blocking backend calls
// (net.connect's cancel loop, http transfers) call pollSerial() so CMD:BTN injections keep working while the
// firmware loop is parked inside them. Compiled in all builds; outside CROSSLUA_DEV it only reads the port buffer.
namespace devcapture {
void pollSerial();
}
