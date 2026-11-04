# ---------------------------------------------------------------------------
# Innovus MMMC setup (legacy UI): setup at slow corner, hold at fast corner,
# parasitics from the gsclib045 QRC tech file.
# Uses env PNR_SDC (constraints written by Genus) plus pnr/extra.sdc.
# ---------------------------------------------------------------------------
set LIBDIR /home/install/FOUNDRY/digital/45nm/dig/lib
# QRC tech file from the same LIBS/ set as the P&R LEF (gsclib045.fixed.lef),
# so layer data (incl. sheet resistance) match. Override with env PNR_QRC.
set QRC [expr {[info exists ::env(PNR_QRC)] ? $::env(PNR_QRC) : \
               "/home/install/FOUNDRY/digital/45nm/LIBS/qx/qrcTechFile"}]

create_library_set -name slow_ls -timing [list $LIBDIR/slow.lib]
create_library_set -name fast_ls -timing [list $LIBDIR/fast.lib]

# Option name changed across Innovus versions; try the newer one first.
if {[catch {create_rc_corner -name rc_typ -qrc_tech $QRC -T 25} msg]} {
    puts "INFO: -qrc_tech not accepted ($msg); using -qx_tech_file"
    create_rc_corner -name rc_typ -qx_tech_file $QRC -T 25
}

create_delay_corner -name dc_slow -library_set slow_ls -rc_corner rc_typ
create_delay_corner -name dc_fast -library_set fast_ls -rc_corner rc_typ

create_constraint_mode -name func -sdc_files [list $::env(PNR_SDC) pnr/extra.sdc]

create_analysis_view -name setup_view -constraint_mode func -delay_corner dc_slow
create_analysis_view -name hold_view  -constraint_mode func -delay_corner dc_fast

set_analysis_view -setup [list setup_view] -hold [list hold_view]
