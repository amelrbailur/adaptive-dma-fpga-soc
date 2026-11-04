#!/bin/sh
# ---------------------------------------------------------------------------
# Step-2 arbiter comparison.
#
#   ./run.sh xrun   one            one run: adaptive v2, HEAVY (quick check)
#   ./run.sh xrun   sweep          5 scenarios x 4 arbiters -> results.csv
#   ./run.sh icarus one | sweep    same with Icarus Verilog
#
#   One run with your own choice, e.g. round robin under SLOW_MEM:
#     ARB=1 SCEN=3 ./run.sh xrun one
#
#   ARB : 0 fixed, 1 round robin, 2 adaptive v1, 3 adaptive v2 (default)
#   SCEN: 0 HEAVY, 1 BALANCED, 2 LIGHT, 3 SLOW_MEM, 4 SWITCH_PEN
# ---------------------------------------------------------------------------

# Stop early if the Cadence tools are not on PATH (csh; source /home/install/cshrc)
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. In csh run: source /home/install/cshrc"; exit 1; }; }

SIM=${1:-xrun}
MODE=${2:-one}
CYCLES=${CYCLES:-5000}
TOP=tb_arbiter_compare

SRC="rtl/wait_counters.sv rtl/request_fifo.sv rtl/chan_monitor.sv rtl/traffic_monitor.sv \
     rtl/adaptive_arbiter.sv rtl/fixed_priority_arbiter.sv rtl/rr_arbiter.sv \
     rtl/arbiter_select.sv rtl/tg_fir.sv rtl/tg_matmul.sv rtl/tg_sparse.sv \
     tb/mem_port_model.sv tb/tb_arbiter_compare.sv"

run_one() {   # $1 = ARB, $2 = SCEN, output to stdout
    case "$SIM" in
      xrun)
        xrun -q -sv -top $TOP $SRC \
             -defparam $TOP.ARB_TYPE=$1 -defparam $TOP.SCENARIO=$2 \
             -defparam $TOP.SIM_CYCLES=$CYCLES ;;
      icarus)
        iverilog -g2012 -o sim.vvp \
             -P$TOP.ARB_TYPE=$1 -P$TOP.SCENARIO=$2 -P$TOP.SIM_CYCLES=$CYCLES $SRC \
          && vvp -n sim.vvp ;;
      *) echo "simulator must be xrun or icarus"; exit 1 ;;
    esac
}

[ "$SIM" = xrun ] && need xrun
[ "$SIM" = icarus ] && need iverilog

case "$MODE" in
  one)
    run_one ${ARB:-3} ${SCEN:-0} ;;
  sweep)
    echo "kind,scenario,arbiter,f1,f2,f3,f4,f5,f6,f7,f8,f9" > results.csv
    for s in 0 1 2 3 4; do
      for a in 0 1 2 3; do
        echo "running scenario $s, arbiter $a"
        run_one $a $s > log_s${s}_a${a}.txt 2>&1
        grep -E '^(CSV|SUM),' log_s${s}_a${a}.txt >> results.csv
        grep -q "RESULT: PASS" log_s${s}_a${a}.txt || echo "  ** check log_s${s}_a${a}.txt (no PASS)"
      done
    done
    echo "wrote results.csv and log_s*_a*.txt"
    command -v python3 >/dev/null && python3 summarize.py results.csv ;;
  *)
    echo "usage: $0 xrun|icarus one|sweep"; exit 1 ;;
esac
