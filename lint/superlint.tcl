# ---------------------------------------------------------------------------
# Jasper Superlint run for adaptive_dma_top (adaptive v2 configuration).
# Run:  jg -superlint lint/superlint.tcl -batch      (from the project folder)
# To lint another arbiter, change ARB_TYPE below (0 fixed, 1 RR, 2 v1, 3 v2).
#
# Command names follow Jasper 2022.09. If a command errors, check it inside
# Jasper with:  help check_superlint
# ---------------------------------------------------------------------------
clear -all

analyze -sv12 \
    rtl/wait_counters.sv rtl/request_fifo.sv rtl/chan_monitor.sv rtl/traffic_monitor.sv \
    rtl/adaptive_arbiter.sv rtl/fixed_priority_arbiter.sv rtl/rr_arbiter.sv \
    rtl/arbiter_select.sv rtl/axi3_dma_master.sv rtl/adaptive_dma_top.sv

elaborate -top adaptive_dma_top -parameter ARB_TYPE 3

clock clk
reset reset

# Structural lint rules plus automatic formal checks (dead code, stuck
# signals, FSM reachability, out-of-range indexing, X-assignments)
check_superlint -extract
check_superlint -prove
check_superlint -report -file lint/out/superlint_report.txt -force

exit -force
