// Reference driver: runs review scenarios through crossplay's real C++ FSRS-5 + learning-step scheduler
// (src/apps_local/study/, MIT, by ma-r-s) and prints the card state after every answer.
// The Lua port (sd_card_contents/plugins/study_lua) must reproduce golden.txt.
// Build:  g++ -std=c++17 -I<crossplay>/src/apps_local/study ref_driver.cpp StudyFsrs.cpp StudyScheduler.cpp -o ref
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "StudyScheduler.h"

namespace study {
Memory CardState::memory() const {
  Memory m;
  m.stability = stability;
  m.difficulty = difficulty;
  m.learned = stability > 0.0f && difficulty > 0.0f;
  return m;
}
void CardState::setMemory(const Memory& m) {
  stability = m.stability;
  difficulty = m.difficulty;
}
}  // namespace study

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  FILE* f = fopen(argv[1], "r");
  if (!f) return 2;
  study::Fsrs fsrs;  // Anki's default FSRS-5 weights, 0.9 retention
  study::Scheduler sched(fsrs, study::Steps::defaults());
  char line[8192];
  int sc = 0;
  while (fgets(line, sizeof line, f)) {
    study::CardState card;  // a brand-new card
    long long clock = 20000LL * 1440 + 600;
    printf("S %d\n", sc++);
    for (char* tok = strtok(line, ",\n"); tok; tok = strtok(nullptr, ",\n")) {
      int rating = atoi(tok);
      long long adv = atoll(strchr(tok, ':') + 1);
      clock += adv;
      int today = (int)(clock / 1440), nowMin = (int)(clock % 1440);
      if (!study::Scheduler::isDue(card, today, nowMin)) {  // wait until it is
        clock = (long long)card.dueDay * 1440 + (card.state == 1 || card.state == 3 ? card.dueMinute : 0);
        today = (int)(clock / 1440);
        nowMin = (int)(clock % 1440);
      }
      study::Outcome o = sched.answer(card, (study::Rating)rating, today, nowMin);
      card = o.card;
      printf("%d %d %d %d %.5g %.5g %d %d %d %d %d\n", card.state, card.stepIndex, card.dueDay, card.dueMinute,
             card.stability, card.difficulty, card.reps, card.lapses, o.delayMinutes, o.intervalDays,
             o.graduated ? 1 : 0);
    }
  }
  return 0;
}
