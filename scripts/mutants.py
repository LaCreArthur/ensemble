#!/usr/bin/env python3
"""Proves the tests catch real bugs: applies each mutant in Tests/mutants.tsv (one deliberate bug in the
source), runs the tests, and expects them to fail; restores the file after each. A mutant that survives
means a feature no test really checks. Usage: scripts/mutants.py [substring of a mutant's file]"""
import subprocess, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
only = sys.argv[1] if len(sys.argv) > 1 else ''
survived = 0
for n, line in enumerate((root / 'Tests/mutants.tsv').read_text().splitlines(), 1):
    if not line.strip() or line.startswith('#'): continue
    path, before, after = (s.replace('\\n', '\n') for s in line.split('\t'))
    if only not in path: continue
    f = root / path; text = f.read_text()
    assert text.count(before) == 1, f'line {n}: {before!r} must occur once in {path}'
    f.write_text(text.replace(before, after))
    try:
        r = subprocess.run(['swift', 'test', '-q'], cwd=root, capture_output=True, text=True)
    finally:
        f.write_text(text)
    build_broke = 'error:' in r.stdout + r.stderr and 'Test run' not in r.stdout
    verdict = 'BUILD BROKE' if build_broke else ('caught' if r.returncode != 0 else 'SURVIVED')
    if verdict != 'caught': survived += 1
    print(f'{verdict:12} {path.split("/")[-1]}: {before.strip()[:60]} -> {after.strip()[:60]}', flush=True)
sys.exit(1 if survived else 0)
