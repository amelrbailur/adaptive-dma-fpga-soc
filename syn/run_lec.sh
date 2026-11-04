#!/bin/sh
# ---------------------------------------------------------------------------
# Conformal LEC: RTL vs Genus netlist for every synthesized configuration.
#   ./syn/run_lec.sh                 all syn/out/arb*_p*/ directories
#   ./syn/run_lec.sh syn/out/arb3_p2.5
# ---------------------------------------------------------------------------
[ -d rtl ] && [ -d syn ] || { echo "ERROR: run this from the project folder (the one containing rtl/ and syn/)"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. In csh run: source /home/install/cshrc"; exit 1; }; }
need lec
DIRS=${*:-$(ls -d syn/out/arb*_p* 2>/dev/null)}
for d in $DIRS; do
    [ -f $d/rtl2gate.do ] || { echo "$d: no LEC dofile (run synthesis first)"; continue; }
    lec -XL -nogui -dofile $d/rtl2gate.do > $d/lec_run.log 2>&1
    # Conformal's compare summary has rows "Equivalent", "Non-equivalent", "Aborted"
    # The first compare table is the main one (PO + DFF); a second, small
    # table is the sequential-merge check.
    eq=$(grep -E "^ *Equivalent " $d/lec_run.log | head -1 | awk '{print $NF}')
    ne=$(grep -E "^ *Non-equivalent " $d/lec_run.log | head -1 | awk '{print $NF}')
    ab=$(grep -E "^ *Abort" $d/lec_run.log | head -1 | awk '{print $NF}')
    if [ -z "$eq" ]; then
        echo "$d: no compare result; last lines of $d/lec_run.log:"
        tail -10 $d/lec_run.log | sed 's/^/    /'
    elif [ "${ne:-0}" != 0 ] || [ "${ab:-0}" != 0 ]; then
        echo "$d: ** LEC FAIL: equivalent $eq, non-equivalent ${ne:-0}, aborted ${ab:-0} (see $d/lec.log)"
    else
        echo "$d: LEC PASS: $eq equivalent points, 0 non-equivalent, 0 aborted"
    fi
done
