# ---------------------------------------------------------------------------
# Open the routed design in the Innovus GUI for screenshots.
#   innovus -files pnr/show_layout.tcl          (from the project folder)
# Then: File > Save Image (or a screenshot) with the views you want:
#   * whole chip (already fitted)
#   * clock tree: Clock > CCOpt Clock Tree Debugger
#   * congestion / density: View > Show Congestion, Tools > Density Map
# ---------------------------------------------------------------------------
set run [expr {[info exists ::env(PNR_RUN)] ? $::env(PNR_RUN) : "pnr/out/arb3_p3.0"}]
restoreDesign $run/db/final.enc.dat dma_top_syn
fit
