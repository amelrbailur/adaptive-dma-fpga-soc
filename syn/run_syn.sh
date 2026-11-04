#!/bin/sh
# ---------------------------------------------------------------------------
# Synthesize the DMA subsystem with Genus for each arbiter, then summarize.
#   ./syn/run_syn.sh                 all 4 arbiters at 2.5 ns (400 MHz)
#   ./syn/run_syn.sh 2.0             all 4 at 2.0 ns
#   ./syn/run_syn.sh 2.0 3           only adaptive v2 at 2.0 ns
#   ./syn/run_syn.sh sweep           all 4 at 4.0 3.0 2.5 2.0 1.5 1.2 ns (fmax)
# Run from the project folder (the one containing rtl/ and syn/).
# Results: syn/out/arb<A>_p<PERIOD>/  and  syn/out/summary.md
# ---------------------------------------------------------------------------
[ -d rtl ] && [ -d syn ] || { echo "ERROR: run this from the project folder (the one containing rtl/ and syn/)"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. In csh run: source /home/install/cshrc"; exit 1; }; }
need genus

TAGW=${SYN_TAGW:-4}
run() {   # $1 = arbiter, $2 = period
    out=syn/out/arb$1_p$2
    mkdir -p $out
    echo "Genus: arbiter $1, period $2 ns -> $out"
    SYN_ARB=$1 SYN_PERIOD=$2 SYN_TAGW=$TAGW SYN_OUT=$out \
        genus -batch -files syn/genus.tcl -log $out/genus > /dev/null 2>&1
    if ! grep -q SYN_DONE $out/genus.log 2>/dev/null; then
        echo "  ** Genus did not finish; see $out/genus.log"
        grep -E 'SYN_ERROR|^Error|ERROR' $out/genus.log | head -5
    elif grep -qE "^dma_top_syn +0 " $out/area.rpt 2>/dev/null; then
        echo "  ** Genus produced an empty design; see $out/genus.log"
    fi
}

if [ "$1" = sweep ]; then
    for p in 4.0 3.0 2.5 2.0 1.5 1.2; do for a in 0 1 2 3; do run $a $p; done; done
else
    P=${1:-2.5}; [ $# -gt 0 ] && shift
    ARBS=${*:-"0 1 2 3"}
    for a in $ARBS; do run $a $P; done
fi
command -v python3 >/dev/null && python3 syn/syn_summary.py syn/out
