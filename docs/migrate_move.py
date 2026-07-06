#!/usr/bin/env python3
# Migration tool: insert `move ` before each argument flagged by share-place
# stage1 as "takes ownership of a non-Copy value". Safe because the old move
# semantics already consumed these bindings (no use-after in the compiler).
import re, sys, collections

check_out = sys.argv[1]
text = open(check_out).read()

# Parse: an error line followed by a ` --> file:line:col` line.
sites = []  # (file, line, col)
lines = text.splitlines()
for i, ln in enumerate(lines):
    if "takes ownership of a non-Copy value" in ln:
        # find the next  --> file:line:col
        for j in range(i+1, min(i+4, len(lines))):
            m = re.search(r'-->\s+(\S+\.w):(\d+):(\d+)', lines[j])
            if m:
                sites.append((m.group(1), int(m.group(2)), int(m.group(3))))
                break

# Group by file, insert right-to-left per (line, col) so earlier cols don't shift.
by_file = collections.defaultdict(list)
for f, l, c in sites:
    by_file[f].append((l, c))

total = 0
for f, poss in by_file.items():
    src = open(f).read().split("\n")
    # dedupe + sort descending by (line, col)
    poss = sorted(set(poss), key=lambda t: (t[0], t[1]), reverse=True)
    for (l, c) in poss:
        idx = l - 1
        line = src[idx]
        col = c - 1  # 1-based -> 0-based
        # sanity: don't double-insert if already `move `
        if line[col:col+5] == "move ":
            continue
        src[idx] = line[:col] + "move " + line[col:]
        total += 1
    open(f, "w").write("\n".join(src))
    print(f"{f}: {len(poss)} sites")

print(f"TOTAL move insertions: {total}")
