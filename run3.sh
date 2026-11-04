#!/bin/sh
# ---------------------------------------------------------------------------
# Step 3: AXI3 burst DMA + DRAM-like memory, end-to-end comparison.
#
#   ./run3.sh xrun one [ARB] [SCEN]    one run (default: adaptive v2, HEAVY)
#   ./run3.sh xrun sweep               5 scenarios x 4 arbiters -> results3.csv
#   ./run3.sh xrun nobursts            sweep with MAX_BURST=1 (bursting off)
#   ./run3.sh xrun cov                 coverage regression (37 runs: the 20
#                                      sweep runs + random AXI backpressure +
#                                      contiguous-access scenario + error injection),
#                                      code coverage merged with IMC, functional
#                                      coverage merged by cov/cov_summary.py
#   ./run3.sh xrun covmerge            redo only the IMC merge + reports
#   ./run3.sh icarus ...               same with Icarus Verilog (functional
#                                      coverage only; no code coverage)
#
#   ARB : 0 fixed, 1 round robin, 2 adaptive v1, 3 adaptive v2
#   SCEN: 0 HEAVY, 1 BALANCED, 2 LIGHT, 3 SLOW_DRAM, 4 LOW, 5 CONTIG (coverage)
#   Optional: MAXOUT=16 (outstanding bursts), e.g. 'env MAXOUT=16 ./run3.sh xrun sweep'
#   Works from csh/tcsh too (arguments, not VAR=value).
# ---------------------------------------------------------------------------

# Stop early if the Cadence tools are not on PATH (csh; source /home/install/cshrc)
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. In csh run: source /home/install/cshrc"; exit 1; }; }

SIM=${1:-xrun}
MODE=${2:-one}
CYCLES=${CYCLES:-5000}
TOP=tb_axi_system

SRC="rtl/wait_counters.sv rtl/request_fifo.sv rtl/chan_monitor.sv rtl/traffic_monitor.sv \
     rtl/adaptive_arbiter.sv rtl/fixed_priority_arbiter.sv rtl/rr_arbiter.sv \
     rtl/arbiter_select.sv rtl/tg_fir.sv rtl/tg_matmul.sv rtl/tg_sparse.sv \
     rtl/axi3_dma_master.sv rtl/adaptive_dma_top.sv \
     tb/axi3_mem_model.sv tb/axi3_checker.sv tb/func_cov.sv tb/tb_axi_system.sv"

run_one() {   # $1 = ARB, $2 = SCEN, $3 = MAX_BURST
    case "$SIM" in
      xrun)
        xrun -q -sv -top $TOP $SRC \
             -defparam $TOP.ARB_TYPE=$1 -defparam $TOP.SCENARIO=$2 \
             -defparam $TOP.MAX_BURST=$3 -defparam $TOP.SIM_CYCLES=$CYCLES \
             -defparam $TOP.MAX_OUT=${MAXOUT:-8} ;;
      icarus)
        iverilog -g2012 -o sim3.vvp -P$TOP.ARB_TYPE=$1 -P$TOP.SCENARIO=$2 \
             -P$TOP.MAX_BURST=$3 -P$TOP.SIM_CYCLES=$CYCLES -P$TOP.MAX_OUT=${MAXOUT:-8} $SRC 2>/dev/null \
          && vvp -n sim3.vvp ;;
      *) echo "simulator must be xrun or icarus"; exit 1 ;;
    esac
}

sweep() {   # $1 = MAX_BURST, $2 = output csv
    echo "kind,scenario,arbiter,f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11" > $2
    for s in 4 2 1 0 3; do
      for a in 0 1 2 3; do
        echo "running scenario $s, arbiter $a (max burst $1)"
        run_one $a $s $1 > log3_b$1_s${s}_a${a}.txt 2>&1
        grep -E '^(CSV|SUM),' log3_b$1_s${s}_a${a}.txt >> $2
        grep -q "RESULT: PASS" log3_b$1_s${s}_a${a}.txt || echo "  ** check log3_b$1_s${s}_a${a}.txt (no PASS)"
      done
    done
    echo "wrote $2"
    command -v python3 >/dev/null && python3 summarize.py $2
}

[ "$SIM" = xrun ] && need xrun
[ "$SIM" = icarus ] && need iverilog

# One coverage run: $1 = test name, rest = PARAM=value pairs
cov_one() {
    name=$1; shift
    case "$SIM" in
      xrun)
        D=""; for p in "$@"; do D="$D -defparam $TOP.$p"; done
        xrun -q -sv -top $TOP $SRC $D -defparam $TOP.SIM_CYCLES=$CYCLES \
             -coverage all -covdut adaptive_dma_top -covworkdir cov_work \
             -covscope step3 -covtest $name -covoverwrite ;;
      icarus)
        D=""; for p in "$@"; do D="$D -P$TOP.$p"; done
        iverilog -g2012 -o sim3.vvp $D -P$TOP.SIM_CYCLES=$CYCLES $SRC 2>/dev/null \
          && vvp -n sim3.vvp ;;
    esac > cov/logs/$name.txt 2>&1
    sed -i "s/^FCOV,run,/FCOV,$name,/" cov/logs/$name.txt
    if grep -q "RESULT: PASS" cov/logs/$name.txt; then echo "  $name: PASS"
    else echo "  $name: ** NO PASS ** (see cov/logs/$name.txt)"; fi
}

case "$MODE" in
  covmerge)
    need imc
    mkdir -p cov/out; rm -rf cov_work/merged; mkdir -p cov_work/merged
    imc -exec cov/imc_merge.tcl > cov/out/imc.log 2>&1
    if [ -s cov/out/code_cov_summary.txt ]; then
        head -40 cov/out/code_cov_summary.txt
        echo "Full: cov/out/code_cov_summary.txt, code_cov_detail.txt"
        echo "Browse: imc -load cov_work/merged/all &"
    else
        echo "IMC did not write a report; see cov/out/imc.log"
        grep -E '\*E,' cov/out/imc.log | head -5
    fi ;;
  cov)
    rm -rf cov/logs cov/out; mkdir -p cov/logs cov/out
    [ "$SIM" = xrun ] && rm -rf cov_work
    echo "1) the 20 sweep configurations"
    for s in 0 1 2 3 4; do for a in 0 1 2 3; do
        cov_one s${s}_a${a} ARB_TYPE=$a SCENARIO=$s; done; done
    echo "2) random AXI backpressure (HEAVY, BALANCED)"
    for s in 0 1; do for a in 0 1 2 3; do
        cov_one bp_s${s}_a${a} ARB_TYPE=$a SCENARIO=$s BP=1; done; done
    echo "3) contiguous access orders (CONTIG scenario: write bursts, gathering on all channels)"
    for a in 0 1 2 3; do cov_one contig_a$a ARB_TYPE=$a SCENARIO=5; done
    echo "4) error injection (SLVERR, wrong RID, wrong BID)"
    cov_one err_resp ARB_TYPE=3 SCENARIO=1 ERR=1
    cov_one err_id   ARB_TYPE=3 SCENARIO=1 ERR=2
    cov_one err_bid  ARB_TYPE=3 SCENARIO=1 ERR=3
    echo "5) single active channel (long grant runs on one channel)"
    cov_one solo_a2 ARB_TYPE=2 SCENARIO=0 SOLO=1
    cov_one solo_a3 ARB_TYPE=3 SCENARIO=0 SOLO=1
    echo
    python3 cov/cov_summary.py cov/logs/*.txt | tee cov/out/func_cov.txt
    python3 cov/cov_summary.py cov/logs/*.txt --md > cov/out/func_cov.md
    if [ "$SIM" = xrun ]; then
        need imc
        echo; echo "Merging code coverage with IMC ..."
        rm -rf cov_work/merged; mkdir -p cov_work/merged
        imc -exec cov/imc_merge.tcl > cov/out/imc.log 2>&1
        if [ -s cov/out/code_cov_summary.txt ]; then
            echo "Code coverage summary: cov/out/code_cov_summary.txt"
            head -40 cov/out/code_cov_summary.txt
            echo "Browse: imc -load cov_work/merged/all &"
        else
            echo "IMC did not write a report; see cov/out/imc.log"
            grep -E '\*E,' cov/out/imc.log | head -5
        fi
    fi ;;
  one)      run_one ${3:-3} ${4:-0} ${MAXB:-4} ;;
  sweep)    sweep 4 results3.csv ;;
  nobursts) sweep 1 results3_nobursts.csv ;;
  *)        echo "usage: $0 xrun|icarus one [ARB] [SCEN] | sweep | nobursts | cov | covmerge"; exit 1 ;;
esac
