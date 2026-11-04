#!/bin/sh
# ---------------------------------------------------------------------------
# Innovus place & route of one Genus run.
#   ./pnr/run_pnr.sh                         adaptive v2 at 3.0 ns (syn/out/arb3_p3.0)
#   ./pnr/run_pnr.sh syn/out/arb1_p3.0       another synthesized configuration
#   ./pnr/run_pnr.sh syn/out/arb3_p3.0 cts   resume from the saved placement
#                                            (also: route, final)
#   env PNR_UTIL=0.6 ./pnr/run_pnr.sh        different core utilization
# Results: pnr/out/<syn run name>/  (rpt/, db/, final_netlist.v, final.spef, final.sdf)
# ---------------------------------------------------------------------------
[ -d rtl ] && [ -d pnr ] || { echo "ERROR: run this from the project folder (the one containing rtl/ and pnr/)"; exit 1; }
case "$(pwd)" in *" "*) echo "ERROR: the project path contains a space: $(pwd)"; echo "       Innovus cannot work there. Copy the project to a path without spaces (e.g. ~/proj)."; exit 1;; esac
command -v innovus >/dev/null 2>&1 || { echo "ERROR: 'innovus' not found. In csh run: source /home/install/cshrc"; exit 1; }

SYN=${1:-syn/out/arb3_p3.0}
[ -f $SYN/netlist.v ] && [ -f $SYN/design.sdc ] || { echo "ERROR: $SYN has no netlist.v / design.sdc. Synthesize first, e.g. ./syn/run_syn.sh 3.0 3"; exit 1; }
FROM=${2:-start}
OUT=pnr/out/$(basename $SYN)
LOG=innovus_$FROM
mkdir -p $OUT
echo "Innovus: $SYN -> $OUT, from stage '$FROM'   (progress: grep PNR_ $OUT/$LOG.log)"
PNR_SYN=$SYN PNR_OUT=$OUT PNR_FROM=$FROM innovus -no_gui -files pnr/innovus.tcl -log $OUT/$LOG > /dev/null 2>&1

grep -E "PNR_STAGE|PNR_INFO" $OUT/$LOG.log | grep -v "^ *Puts" | sed 's/^/  /'
if grep -q "^PNR_DONE\|PNR_DONE$" $OUT/$LOG.log; then
    echo "Done. Key reports:"
    echo "  $OUT/rpt/timing_postRoute/       (setup)"
    echo "  $OUT/rpt/timing_postRoute_hold/  (hold)"
    echo "  $OUT/rpt/summary.rpt, final_area.rpt, final_power.rpt, drc.rpt, connectivity.rpt"
    grep -A12 "Setup mode" $OUT/rpt/timing_postRoute/*.summary 2>/dev/null | head -14
else
    echo "** Innovus stopped early. First errors:"
    grep -E "^\*\*ERROR" $OUT/$LOG.log | head -8
    echo "  (resume after a fix with: ./pnr/run_pnr.sh $SYN <stage>; saved: $(ls $OUT/db 2>/dev/null | grep -v dat | tr '\n' ' '))"
fi
