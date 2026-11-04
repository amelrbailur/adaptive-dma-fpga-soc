#!/usr/bin/env python3
"""Summarize Genus runs: area (total and arbiter), slack, power, cell count.

Usage: python3 syn/syn_summary.py syn/out
Writes syn/out/summary.md and prints the same table.
Parsers are tolerant: a value Genus formats differently shows as '?';
the raw reports are in each run directory.
"""
import os, re, sys

ARB = {"0": "FIXED", "1": "RR", "2": "ADAPTIVE", "3": "ADAPT_V2"}
NUM = r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"

def read(p):
    try:
        return open(p, errors="replace").read()
    except OSError:
        return ""

def area(txt, inst):
    """(total area, cell count) of an instance row in report_area.
    Row: <inst> [<module>] <cells> <cell area> <net area> <total area> <wireload>"""
    for line in txt.splitlines():
        tok = line.split()
        if tok and tok[0] == inst:
            nums = [t for t in tok[1:] if re.fullmatch(NUM, t)]
            if len(nums) >= 4:
                return float(nums[3]), int(float(nums[0]))
    return None, None

def slack(txt):
    """Worst slack in ns. Genus 21: 'Path 1: MET (0 ps)' / 'VIOLATED (-35 ps)'."""
    m = re.search(r"Path 1:\s*(?:MET|VIOLATED)\s*\((" + NUM + r")\s*ps\)", txt)
    if m:
        return float(m.group(1)) / 1000.0
    m = re.search(r"Slack:=\s*(" + NUM + ")", txt)          # value in ps
    if m:
        return float(m.group(1)) / 1000.0
    m = re.search(r"Timing slack\s*:\s*(" + NUM + r")\s*(ps|ns)?", txt)
    if m:
        v = float(m.group(1))
        return v / 1000.0 if (m.group(2) == "ps") else v
    return None

def power(txt):
    """Total power in mW from the 'Subtotal' row: leakage internal switching total (W)."""
    for line in txt.splitlines():
        tok = line.split()
        if tok and tok[0].lower() in ("subtotal", "total"):
            nums = [t for t in tok[1:] if re.fullmatch(NUM, t)]
            if len(nums) >= 4:
                return f"{1000*float(nums[3]):.2f}"
    return None

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "syn/out"
    rows = []
    for d in sorted(os.listdir(root)):
        m = re.match(r"arb(\d)_p([\d.]+)$", d)
        if not m:
            continue
        a, p = m.group(1), m.group(2)
        path = os.path.join(root, d)
        ar = read(os.path.join(path, "area.rpt"))
        tot, cells = area(ar, "dma_top_syn")
        arb, acells = area(ar, "arbiter")
        sl = slack(read(os.path.join(path, "timing.rpt")))
        pw = power(read(os.path.join(path, "power.rpt")))
        done = "SYN_DONE" in read(os.path.join(path, "genus.log"))
        rows.append((ARB.get(a, a), p,
                     f"{tot:.1f}" if tot is not None else "?",
                     f"{arb:.1f}" if arb is not None else "?",
                     f"{100*arb/tot:.1f}%" if (arb and tot) else "?",
                     str(cells) if cells is not None else "?",
                     str(acells) if acells is not None else "?",
                     (f"{sl:+.3f}" + (" MET" if sl >= 0 else " VIOL")) if sl is not None else "?",
                     pw or "?", "ok" if done else "FAILED"))
    hdr = ("Arbiter", "Period ns", "Total area um2", "Arbiter area um2", "Arbiter share",
           "Cells", "Arbiter cells", "Slack ns", "Power mW", "Run")
    out = ["| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    txt = "\n".join(out)
    print(txt)
    with open(os.path.join(root, "summary.md"), "w") as f:
        f.write(txt + "\n")
    print(f"\nwrote {os.path.join(root, 'summary.md')}")

if __name__ == "__main__":
    main()
