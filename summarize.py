#!/usr/bin/env python3
"""Turn results.csv from ./run.sh sweep into comparison tables.

Usage: python3 summarize.py results.csv [--md]
  --md  print Markdown tables (paste straight into a report)
"""
import csv
import sys
from collections import defaultdict

ARBS = ["FIXED", "RR", "ADAPTIVE", "ADAPT_V2"]
SCENS = []          # filled in file order


def load(path):
    summ, chans = {}, defaultdict(dict)
    with open(path) as f:
        for row in csv.reader(f):
            if not row or row[0] == "kind":
                continue
            row = [c.strip() for c in row]
            if row[0] == "SUM":
                _, sc, arb, thr, jain, lavg, lp99, lmax, stall, err = row[:10]
                summ[(sc, arb)] = dict(thr=float(thr), jain=float(jain), lavg=int(lavg),
                                       lp99=int(lp99), lmax=int(lmax), stall=int(stall),
                                       err=int(err))
                if len(row) >= 12:   # step 3: DRAM row-hit rate, avg burst
                    summ[(sc, arb)].update(rowhit=float(row[10]), burst=float(row[11]))
                if sc not in SCENS:
                    SCENS.append(sc)
            elif row[0] == "CSV":
                _, sc, arb, ch, srv, off, lavg, lp99, lmax, mwait, stall, err = row
                chans[(sc, arb)][ch] = dict(srv=int(srv), off=int(off), lavg=int(lavg),
                                            lp99=int(lp99), lmax=int(lmax), mwait=int(mwait),
                                            stall=int(stall))
    return summ, chans


def table(headers, rows, md):
    if md:
        out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
        out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    else:
        w = [max(len(str(x)) for x in col) for col in zip(headers, *rows)]
        fmt = "  ".join("{:>%d}" % n for n in w)
        out = [fmt.format(*headers), fmt.format(*["-" * n for n in w])]
        out += [fmt.format(*[str(c) for c in r]) for r in rows]
    return "\n".join(out)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    md = "--md" in sys.argv
    summ, chans = load(sys.argv[1])

    for sc in SCENS:
        if not any((sc, a) in summ for a in ARBS):
            continue
        print(f"\n### {sc}\n" if md else f"\n=== {sc} ===")
        rows = []
        for a in ARBS:
            s = summ.get((sc, a))
            if not s:
                continue
            c = chans[(sc, a)]
            per_ch = " / ".join(f"{c[ch]['lmax']}" for ch in ("FIR", "MATMUL", "SPARSE") if ch in c)
            share = " / ".join(f"{100*c[ch]['srv']//max(c[ch]['off'],1)}%"
                               for ch in ("FIR", "MATMUL", "SPARSE") if ch in c)
            extra = [f"{100*s['rowhit']:.0f}%", f"{s['burst']:.2f}"] if 'rowhit' in s else []
            rows.append([a, f"{s['thr']:.3f}", s['lavg'], s['lp99'], s['lmax'],
                         per_ch, share, f"{s['jain']:.3f}", s['stall']] + extra +
                        ["PASS" if s['err'] == 0 else f"FAIL({s['err']})"])
        hdr = ["Arbiter", "Thr", "Lat avg", "p99", "Max*", "Max F/M/S",
               "Srv/Off F/M/S", "Jain", "Stalls"]
        if rows and len(rows[0]) == 12:
            hdr += ["RowHit", "Burst"]
        print(table(hdr + ["Check"], rows, md))
    print("\nThr = requests (step 2) or completed beats (step 3) per cycle. Latency in cycles from request ready at the accelerator to grant (includes source stalls). "
          "Srv/Off = served / demand cycles. Max* includes requests still queued at the end. "
          "Jain over served/offered per channel.")


if __name__ == "__main__":
    main()
