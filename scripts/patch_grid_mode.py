#!/usr/bin/env python3
"""Add device.input_mode('grid') to every Lua app that uses left/right events.

Run from the repo root: python3 scripts/patch_grid_mode.py
Inserts at the top of main.lua (after the initial comment block) so it runs
before any input events are polled.  Safe to re-run — checks for existing
injection.
"""

import re
import os

PLUGINS = 'sd_card_contents/plugins'

GRID_LINE = 'device.input_mode("grid")'

def find_left_right_apps(base):
    apps = []
    for root, dirs, files in os.walk(base):
        if 'main.lua' in files:
            path = os.path.join(root, 'main.lua')
            rel = os.path.relpath(path, base)
            with open(path) as f:
                content = f.read()
            uses_left = "'left'" in content or '"left"' in content
            uses_right = "'right'" in content or '"right"' in content
            if uses_left or uses_right:
                apps.append((path, rel, content))
    return apps

def inject_grid_mode(content):
    if GRID_LINE in content:
        return content, False
    
    # Skip the comment block at the top (lines starting with --)
    # Insert right after it, before the first non-comment/non-blank line
    lines = content.split('\n')
    insert_after = 0
    in_comment_block = True
    for i, line in enumerate(lines):
        stripped = line.strip()
        if in_comment_block and (stripped.startswith('--') or stripped == ''):
            insert_after = i + 1
            continue
        in_comment_block = False
        # Stop at first require, local, or function
        if stripped.startswith('local ') or stripped.startswith('function ') or \
           stripped.startswith('require') or stripped.startswith('--'):
            break
        insert_after = i + 1
    
    lines.insert(insert_after, GRID_LINE)
    return '\n'.join(lines), True

def main():
    base = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), PLUGINS)
    apps = find_left_right_apps(base)
    modified = 0
    skipped = 0
    for path, rel, content in sorted(apps, key=lambda x: x[1]):
        new_content, changed = inject_grid_mode(content)
        if changed:
            with open(path, 'w') as f:
                f.write(new_content)
            print(f"  + {rel}")
            modified += 1
        else:
            print(f"  - {rel} (skipped)")
            skipped += 1
    print(f"\nModified: {modified}, Skipped: {skipped} (already has grid mode call or no suitable insertion point)")

if __name__ == '__main__':
    main()