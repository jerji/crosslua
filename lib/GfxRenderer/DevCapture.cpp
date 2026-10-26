#include "DevCapture.h"

#ifdef CROSSLUA_DEV
#include <cstring>

namespace devcapture {
namespace {
struct Item {
  int16_t x, y, w, h;
  int32_t font;
  uint8_t kind;  // 0 = text, 1 = rect
  uint8_t color;
  char text[36];
};
constexpr int MAX_ITEMS = 80;
Item cur[MAX_ITEMS];
Item shown[MAX_ITEMS];
int curN = 0, shownN = 0;
uint32_t curSeq = 0, shownSeq = 0;
bool curOverflow = false, shownOverflow = false;
int suppress = 0;

Item* next() {
  if (curN >= MAX_ITEMS) {
    // Some screens repaint partially without clearScreen(); keep the NEWEST items by dropping the oldest 8.
    constexpr int DROP = 8;
    memmove(cur, cur + DROP, sizeof(Item) * static_cast<size_t>(MAX_ITEMS - DROP));
    curN = MAX_ITEMS - DROP;
    curOverflow = true;
  }
  return &cur[curN++];
}
}  // namespace

void beginFrame() {
  curN = 0;
  curOverflow = false;
}

void text(int fontId, int x, int y, const char* s) {
  if (!s || !*s) return;
  Item* it = next();
  if (!it) return;
  it->kind = 0;
  it->x = static_cast<int16_t>(x);
  it->y = static_cast<int16_t>(y);
  it->w = it->h = 0;
  it->color = 0;
  it->font = fontId;
  size_t n = 0;
  for (; s[n] && n < sizeof(it->text) - 1; n++) it->text[n] = (static_cast<unsigned char>(s[n]) < 0x20) ? ' ' : s[n];
  it->text[n] = '\0';
}

void rect(int x, int y, int w, int h, int color) {
  if (suppress > 0 || w <= 0 || h <= 0 || w * h < 120) return;  // skip corner/outline pixel spam
  Item* it = next();
  if (!it) return;
  it->kind = 1;
  it->x = static_cast<int16_t>(x);
  it->y = static_cast<int16_t>(y);
  it->w = static_cast<int16_t>(w);
  it->h = static_cast<int16_t>(h);
  it->color = static_cast<uint8_t>(color);
  it->font = 0;
  it->text[0] = '\0';
}

Suppress::Suppress() { suppress++; }
Suppress::~Suppress() { suppress--; }

void commitFrame() {
  memcpy(shown, cur, sizeof(Item) * static_cast<size_t>(curN));
  shownN = curN;
  shownOverflow = curOverflow;
  shownSeq = ++curSeq;
}

void dump(Print& out, const char* activity, int screenW, int screenH) {
  out.printf("SCREEN_START:%lu:%s:%dx%d%s\n", static_cast<unsigned long>(shownSeq), activity, screenW, screenH,
             shownOverflow ? ":TRUNCATED" : "");
  for (int i = 0; i < shownN; i++) {
    const Item& it = shown[i];
    if (it.kind == 0)
      out.printf("T %d %d %ld %s\n", it.x, it.y, static_cast<long>(it.font), it.text);
    else
      out.printf("R %d %d %d %d %d\n", it.x, it.y, it.w, it.h, it.color);
  }
  out.print("SCREEN_END\n");
}
}  // namespace devcapture
#endif
