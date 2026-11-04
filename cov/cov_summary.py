#!/usr/bin/env python3
"""Merge functional coverage from all coverage-regression logs.

Usage: python3 cov/cov_summary.py cov/logs/*.txt [--md]
Each log contains lines  FCOV,<test>,<bin>,<hits>  (hits = -1 means the bin
does not apply to that configuration). A bin is covered if any run hit it.
"""
import sys

def main():
    md = "--md" in sys.argv
    files = [f for f in sys.argv[1:] if f != "--md"]
    if not files:
        sys.exit(__doc__)
    order, total, runs_hit, first = [], {}, {}, {}
    applicable = set()
    for f in files:
        test = f.rsplit("/", 1)[-1].replace(".txt", "")
        for line in open(f, errors="replace"):
            if not line.startswith("FCOV,"):
                continue
            _, _, b, h = line.strip().split(",")[:4]
            h = int(h)
            if b not in total:
                order.append(b); total[b] = 0; runs_hit[b] = 0
            if h >= 0:
                applicable.add(b)
            if h > 0:
                total[b] += h; runs_hit[b] += 1
                first.setdefault(b, test)
    rows = []
    for b in order:
        status = "n/a" if b not in applicable else ("HIT" if total[b] > 0 else "MISS")
        rows.append((b, total[b], runs_hit[b], first.get(b, "-"), status))
    app = [r for r in rows if r[4] != "n/a"]
    cov = [r for r in app if r[4] == "HIT"]
    hdr = ("Bin", "Total hits", "Runs hitting", "First hit in", "Status")
    if md:
        print("| " + " | ".join(hdr) + " |")
        print("|" + "---|" * len(hdr))
        for r in rows:
            print("| " + " | ".join(str(x) for x in r) + " |")
    else:
        w = [max(len(str(x)) for x in col) for col in zip(hdr, *rows)]
        fmt = "  ".join("{:<%d}" % n for n in w)
        print(fmt.format(*hdr)); print(fmt.format(*["-" * n for n in w]))
        for r in rows:
            print(fmt.format(*[str(x) for x in r]))
    print(f"\nFunctional coverage: {len(cov)} / {len(app)} bins hit "
          f"({100.0 * len(cov) / max(len(app), 1):.1f}%) over {len(files)} runs")
    missed = [r[0] for r in app if r[4] == "MISS"]
    if missed:
        print("Not hit: " + ", ".join(missed))

if __name__ == "__main__":
    main()
