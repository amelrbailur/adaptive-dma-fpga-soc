#!/bin/sh
# ---------------------------------------------------------------------------
# Lint the synthesizable design (adaptive_dma_top) with Cadence tools.
#   ./lint/run_lint.sh hal         Xcelium HAL linter, all 4 arbiter configs
#   ./lint/run_lint.sh superlint   Jasper Superlint app (batch, report file)
#   ./lint/run_lint.sh superlint_gui   same, opened in the Jasper GUI
# Run from the project folder (the one containing rtl/).
# Reports go to lint/out/. Expected leftovers are listed in lint/WAIVERS.md.
# ---------------------------------------------------------------------------

# Stop early if the Cadence tools are not on PATH (csh; source /home/install/cshrc)
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. In csh run: source /home/install/cshrc"; exit 1; }; }

TOOL=${1:-hal}
RTL="rtl/wait_counters.sv rtl/request_fifo.sv rtl/chan_monitor.sv rtl/traffic_monitor.sv \
     rtl/adaptive_arbiter.sv rtl/fixed_priority_arbiter.sv rtl/rr_arbiter.sv \
     rtl/arbiter_select.sv rtl/axi3_dma_master.sv rtl/adaptive_dma_top.sv"
mkdir -p lint/out

case "$TOOL" in
  hal)
    need xrun
    for a in 0 1 2 3; do
      echo "HAL: ARB_TYPE=$a"
      rm -f lint/out/hal_arb$a.log
      xrun -hal -sv -top adaptive_dma_top $RTL \
           -defparam adaptive_dma_top.ARB_TYPE=$a \
           -l lint/out/hal_arb$a.log > /dev/null 2>&1
      [ -s lint/out/hal_arb$a.log ] || { echo "ERROR: HAL produced no log"; exit 1; }
      # Drop waived rules (lint/hal_waived_rules.txt); keep everything else
      grep -vE '^[[:space:]]*(#|$)' lint/hal_waived_rules.txt > lint/out/.waived
      grep -E '\*[EWF],[A-Za-z0-9_]+ \(' lint/out/hal_arb$a.log \
        | grep -vwFf lint/out/.waived > lint/out/hal_arb${a}_open.txt
      n=$(wc -l < lint/out/hal_arb${a}_open.txt)
      echo "  unexplained findings: $n   (full log lint/out/hal_arb$a.log)"
      grep -oE '\*[EWF],[A-Za-z0-9_]+' lint/out/hal_arb${a}_open.txt | sort | uniq -c | sort -rn | sed 's/^/    /'
    done
    echo "Unexplained findings per config: lint/out/hal_arb*_open.txt"
    ;;
  superlint)
    need jg
    rm -f lint/out/superlint_report.txt
    jg -superlint lint/superlint.tcl -batch -proj lint/out/jgproject > lint/out/superlint.log 2>&1
    if [ ! -s lint/out/superlint_report.txt ]; then
      echo "ERROR: Superlint did not produce a report; see lint/out/superlint.log"; exit 1
    fi
    echo "Jasper Superlint finished. Report: lint/out/superlint_report.txt"
    grep -A8 "VIOLATIONS SUMMARY" lint/out/superlint_report.txt
    echo "Session log: lint/out/superlint.log"
    ;;
  superlint_gui)
    need jg
    # Same run, but stays open in the Jasper GUI to inspect each violation
    sed '/^exit/d' lint/superlint.tcl > lint/out/superlint_gui.tcl
    jg -superlint lint/out/superlint_gui.tcl -proj lint/out/jgproject_gui &
    echo "Jasper GUI starting. Superlint tab -> expand each violation category."
    ;;
  *) echo "usage: $0 hal|superlint|superlint_gui"; exit 1 ;;
esac
