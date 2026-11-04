#!/bin/sh
# Hold-length x weight exploration for ADAPT_V2 (all 5 scenarios).
#   ./explore.sh xrun | icarus      -> explore/grid.csv

# Stop early if the Cadence tools are not on PATH (csh; source /home/install/cshrc)
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. In csh run: source /home/install/cshrc"; exit 1; }; }

SIM=${1:-xrun}; T=tb_arbiter_compare; mkdir -p explore
[ "$SIM" = xrun ] && need xrun
SRC="rtl/wait_counters.sv rtl/request_fifo.sv rtl/chan_monitor.sv rtl/traffic_monitor.sv rtl/adaptive_arbiter.sv \
     rtl/fixed_priority_arbiter.sv rtl/rr_arbiter.sv rtl/arbiter_select.sv rtl/tg_fir.sv \
     rtl/tg_matmul.sv rtl/tg_sparse.sv tb/mem_port_model.sv tb/tb_arbiter_compare.sv"
echo "hold,weights,scenario,arbiter,thr,jain,lavg,p99,lmax,stall,err" > explore/grid.csv
for h in 1 2 4 8; do for w in "4 3 2 1" "2 4 1 1" "4 3 0 1" "2 3 1 0"; do set -- $w
  for s in 0 1 2 3 4; do
    P="ARB_TYPE=3 SCENARIO=$s HOLD_MAX=$h W_OCC=$1 W_WAIT=$2 W_RATE=$3 W_BURST=$4"
    if [ "$SIM" = xrun ]; then
      D=""; for p in $P; do D="$D -defparam $T.$p"; done
      OUT=$(xrun -q -sv -top $T $SRC $D)
    else
      D=""; for p in $P; do D="$D -P$T.$p"; done
      iverilog -g2012 $D -o explore/e.vvp $SRC && OUT=$(vvp -n explore/e.vvp)
    fi
    echo "$h,$1$2$3$4,$(echo "$OUT" | grep '^SUM,' | cut -d, -f2-)" >> explore/grid.csv
  done; done; done
echo "wrote explore/grid.csv"
