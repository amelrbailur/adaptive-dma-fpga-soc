# ---------------------------------------------------------------------------
# IMC: merge the code-coverage databases of all coverage runs and write
# reports.  Run (from the project folder):  imc -exec cov/imc_merge.tcl
# To browse interactively afterwards:       imc -load cov_work/merged/all &
#
# The four arbiter configurations elaborate different generate blocks, so
# the merge uses the union of all models. ('report' is IMC's legacy text
# report; it prints a REPDEP deprecation warning, which is harmless.)
# ---------------------------------------------------------------------------
merge cov_work/step3/* -out cov_work/merged/all -overwrite -initial_model union_all
load -run cov_work/merged/all
# Reviewed exclusions (made in the IMC GUI, see cov/EXCLUSIONS.md)
if {[file exists cov/exclusions.vRefine]} {
    load -refinement cov/exclusions.vRefine
    puts "Loaded exclusions: cov/exclusions.vRefine"
}
report -summary -inst -metrics overall:block:expression:fsm:toggle -out cov/out/code_cov_summary.txt
report -detail  -inst -metrics block:expression:fsm -out cov/out/code_cov_detail.txt
exit
