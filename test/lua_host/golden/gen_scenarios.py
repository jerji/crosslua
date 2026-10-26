#!/usr/bin/env python3
"""Deterministic review scenarios for the scheduler golden test. One scenario per line: "rating:advanceMinutes,..."."""
import random
random.seed(20261025)
ADV = [0, 0, 5, 12, 90, 1440, 1440 * 3, 1440 * 9, 1440 * 40, 1440 * 200]
lines = []
for _ in range(400):
    n = random.randint(1, 45)
    steps = []
    for _ in range(n):
        r = random.choices([1, 2, 3, 4], weights=[2, 2, 6, 1.5])[0]
        steps.append(f"{r}:{random.choice(ADV)}")
    lines.append(",".join(steps))
open("scenarios.txt", "w").write("\n".join(lines) + "\n")
print(len(lines), "scenarios")
