// Packs permission labels into the few lines the native confirmation dialog can show (it fits ~3 lines of ~25
// characters and clips the rest with "...", which for a recording device is not acceptable). Pure and header-only so
// the host tests cover it.
#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace crosslua {

// Joins `labels` with ", " into lines of at most `maxWidth` characters, greedily, in the order given (most sensitive
// first). A label longer than the width gets a line to itself. Every line ends with '\n'. Empty input -> empty string.
inline std::string packPermissionLabels(const std::vector<const char*>& labels, size_t maxWidth) {
  std::string out, line;
  for (const char* l : labels) {
    const std::string w(l);
    if (line.empty()) {
      line = w;
    } else if (line.size() + 2 + w.size() <= maxWidth) {
      line += ", " + w;
    } else {
      out += line + "\n";
      line = w;
    }
  }
  if (!line.empty()) out += line + "\n";
  return out;
}

}  // namespace crosslua
