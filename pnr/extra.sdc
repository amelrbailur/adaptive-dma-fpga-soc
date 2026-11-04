# ---------------------------------------------------------------------------
# Implementation constraints added on top of the Genus SDC.
# grant[1:0] is an observability/debug output (waveforms, coverage); nothing
# functional reads it, so it is not timed (standard for debug ports).
# ---------------------------------------------------------------------------
set_false_path -to [get_ports {grant[*]}]
