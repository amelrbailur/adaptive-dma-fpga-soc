#!/bin/sh
# Tempus sign-off STA of a routed design.   ./pnr/run_sta.sh [pnr/out/arb3_p3.0]
[ -d rtl ] && [ -d pnr ] || { echo "ERROR: run this from the project folder"; exit 1; }
command -v tempus >/dev/null 2>&1 || { echo "ERROR: 'tempus' not found. In csh run: source /home/install/cshrc"; exit 1; }
D=${1:-pnr/out/arb3_p3.0}
[ -f $D/final.spef ] || { echo "ERROR: $D/final.spef missing; run ./pnr/run_pnr.sh first"; exit 1; }
rm -rf $D/sta
SDC=$D/final.sdc
[ -f $SDC ] || { SDC=syn/out/$(basename $D)/design.sdc; echo "NOTE: $D/final.sdc not found; using the Genus SDC (I/O paths will be pessimistic)"; }
echo "Tempus: constraints $SDC"
STA_DIR=$D STA_SDC=$SDC tempus -no_gui -files pnr/sta.tcl -log $D/tempus > /dev/null 2>&1
[ -s $D/sta/summary.rpt ] && { echo "Tempus done: $D/sta/"; echo "  worst setup slack:   $(grep -m1 'Slack Time' $D/sta/setup.rpt | awk '{print $NF}') ns"; echo "  worst hold slack:    $(grep -m1 'Slack Time' $D/sta/hold.rpt | awk '{print $NF}') ns"; echo "  reg2reg setup slack: $(grep -m1 'Slack Time' $D/sta/reg2reg.rpt | awk '{print $NF}') ns"; echo "  DRV violations:      $(grep -c 'VIOLATED' $D/sta/violators.rpt)  (summary.rpt lists violating paths only; empty = none)"; } \
  || { echo "** Tempus stopped early:"; grep -E "ERROR" $D/tempus.log | head -8; }
