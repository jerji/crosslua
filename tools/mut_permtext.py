#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/PermText.h'
shutil.copy(F, '/tmp/orig28')
atexit.register(lambda: shutil.copy('/tmp/orig28', F))
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
M = [
 ('PT1 width off by one (<)', 'line.size() + 2 + w.size() <= maxWidth', 'line.size() + 2 + w.size() < maxWidth'),
 ('PT2 width off by one (+1)', 'line.size() + 2 + w.size() <= maxWidth', 'line.size() + 2 + w.size() <= maxWidth + 1'),
 ('PT3 separator without space', 'line += ", " + w;', 'line += "," + w;'),
 ('PT4 separator not counted', 'line.size() + 2 + w.size()', 'line.size() + w.size()'),
 ('PT5 last line dropped', '  if (!line.empty()) out += line + "\\n";', ''),
 ('PT6 no trailing newline on wrap', 'out += line + "\\n";\n      line = w;', 'out += line;\n      line = w;'),
 ('PT7 labels reordered', 'for (const char* l : labels) {', 'for (auto it = labels.rbegin(); it != labels.rend(); ++it) {\n    const char* l = *it;'),
 ('PT8 wrapped label lost', 'out += line + "\\n";\n      line = w;', 'out += line + "\\n";\n      line.clear();'),
]
print('== baseline', run(), flush=True)
for name, a, b in M:
    s = open('/tmp/orig28').read()
    if a not in s: print('!! anchor missing', name); continue
    open(F, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run()[:60], flush=True)
    shutil.copy('/tmp/orig28', F)
print('== restored ->', run(), flush=True)
