#!/usr/bin/env python3
"""Regenerate assets/puzzles.txt from the full Lichess puzzle database (CC0).

The bundled set is SKEWED toward easy: players restart from easy every run, so the lowest rating
bands need far more variety than the rarely-reached hard bands (vs the old uniform 240/band, which
made the easy puzzles repeat). The quality filter keeps well-liked, reasonably-calibrated puzzles and
takes the most popular per band. Every Lichess puzzle is a legal line from a real game, so the output
replays cleanly (verified by replaying each through ChessRules).

Usage:
  curl -sO https://database.lichess.org/lichess_db_puzzle.csv.zst
  zstd -dc lichess_db_puzzle.csv.zst | python3 scripts/dev/sample_puzzles.py > assets/puzzles.txt
  godot --headless --path . -s res://scripts/dev/build_puzzles.gd   # rebuild assets/puzzles.res
"""
import sys, heapq, itertools

# Per 100-rating band target counts, decreasing from easy to hard (the easiest band gets the most).
# The decline gets gentler toward the top (steps shrink 20 -> 3), so the rarely-reached hard bands keep
# a healthy pool of variety for a strong player instead of dropping off a cliff.
TARGETS = {4: 1200, 5: 1000, 6: 850, 7: 700, 8: 600, 9: 500, 10: 450, 11: 400, 12: 360, 13: 330,
           14: 310, 15: 292, 16: 276, 17: 262, 18: 250, 19: 240, 20: 231, 21: 223, 22: 216,
           23: 210, 24: 205, 25: 201, 26: 198}

heaps = {b: [] for b in TARGETS}   # per band: a min-heap of the top-N by (popularity, nb_plays)
cnt = itertools.count()
total = 0
for line in sys.stdin:
    total += 1
    if total == 1 and line.startswith("PuzzleId"):
        continue  # header
    p = line.rstrip("\n").split(",")  # PuzzleId,FEN,Moves,Rating,RatingDeviation,Popularity,NbPlays,...
    if len(p) < 8:
        continue
    try:
        rating = int(p[3]); rd = int(p[4]); pop = int(p[5]); nb = int(p[6])
    except ValueError:
        continue
    fen = p[1]; moves = p[2]
    nmoves = moves.count(" ") + 1
    if rating < 400 or rating >= 2700:
        continue
    if nmoves < 2 or nmoves > 12:        # need a setup move + a solution; cap absurdly long lines
        continue
    if rd > 90 or pop < 80 or nb < 30:   # well-calibrated rating + well-liked + played enough
        continue
    b = rating // 100
    if b not in TARGETS:
        continue
    h = heaps[b]
    key = (pop, nb, next(cnt))           # unique key so heap items never compare by fen/moves
    if len(h) < TARGETS[b]:
        heapq.heappush(h, (key, fen, moves, rating))
    elif key > h[0][0]:
        heapq.heapreplace(h, (key, fen, moves, rating))

out = []
for b in sorted(TARGETS):
    for key, fen, moves, rating in sorted(heaps[b], key=lambda x: x[3]):
        out.append(f"{fen},{moves},{rating}")
sys.stdout.write("\n".join(out) + "\n")
sys.stderr.write("written %d puzzles; per-band counts:\n" % len(out))
for b in sorted(TARGETS):
    got = len(heaps[b])
    sys.stderr.write("  band %d: %d / %d%s\n" % (b, got, TARGETS[b], "" if got == TARGETS[b] else "  <-- short!"))
