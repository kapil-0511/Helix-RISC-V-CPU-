# =============================================================================
# setup_project.tcl  —  Helix  |  5-Stage Pipelined 32-bit CPU
# =============================================================================
# Creates the Vivado project with all RTL and testbench sources configured
# and ready for simulation. Does NOT compile or run any simulations.
#
# Vivado Tcl console:
#   source C:/Users/kapily/Downloads/aria32_5stage/sim/setup_project.tcl
#
# Then simulate any TB manually:
#   set_property top tb_cpu [get_filesets sim_1]
#   launch_simulation
#   run all
#   close_simulation
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set rtl_dir    [file normalize [file join $script_dir .. rtl]]
set tb_dir     [file normalize [file join $script_dir .. tb]]

puts ""
puts "==================================================================="
puts "  Helix  |  5-Stage Pipelined CPU  |  Project Setup"
puts "==================================================================="

# ── Detect simulator ──────────────────────────────────────────────────────────
if {[info commands create_project] ne ""} {
    set SIM_TOOL "vivado"
} elseif {[info commands vlib] ne ""} {
    set SIM_TOOL "modelsim"
} else {
    puts "\[ERROR\]  Cannot detect simulator (neither create_project nor vlib found)."
    puts "         Source this script from Vivado's Tcl console or ModelSim/Questa."
    return
}

puts "\[INFO\]  Simulator : $SIM_TOOL"
puts "\[INFO\]  RTL dir   : $rtl_dir"
puts "\[INFO\]  TB dir    : $tb_dir"
puts ""

# =============================================================================
# ── VIVADO ────────────────────────────────────────────────────────────────────
# =============================================================================
if {$SIM_TOOL eq "vivado"} {

    set proj_dir [file normalize [file join $script_dir vivado_proj]]

    create_project -force helix $proj_dir -part xc7a35tcpg236-1

    set_property simulator_language Mixed         [current_project]
    set_property target_language   Verilog        [current_project]
    set_property default_lib       xil_defaultlib [current_project]

    # ── RTL sources ───────────────────────────────────────────────────────────
    set rtl_files [list \
        [file join $rtl_dir defines.v   ] \
        [file join $rtl_dir alu.v       ] \
        [file join $rtl_dir control.v   ] \
        [file join $rtl_dir reg_file.v  ] \
        [file join $rtl_dir cond_check.v] \
        [file join $rtl_dir data_mem.v  ] \
        [file join $rtl_dir inst_mem.v  ] \
        [file join $rtl_dir cpu_top.v   ] \
    ]
    add_files -fileset sources_1 $rtl_files

    # defines.v is `included by other files — mark as header to skip solo compile
    set_property file_type {Verilog Header} [get_files */defines.v]
    set_property include_dirs [list $rtl_dir] [get_filesets sources_1]
    puts "\[INFO\]  RTL sources added (8 files)."

    # ── Testbenches ───────────────────────────────────────────────────────────
    set tb_files [list \
        [file join $tb_dir tb_memcpy.sv    ] \
        [file join $tb_dir tb_array_sum.sv ] \
        [file join $tb_dir tb_minmax.sv    ] \
        [file join $tb_dir tb_sort.sv      ] \
        [file join $tb_dir tb_factorial.sv ] \
        [file join $tb_dir tb_bitops.sv    ] \
        [file join $tb_dir tb_gcd.sv       ] \
        [file join $tb_dir tb_power.sv     ] \
        [file join $tb_dir tb_isqrt.sv     ] \
        [file join $tb_dir tb_collatz.sv   ] \
        [file join $tb_dir tb_fibonacci.sv ] \
        [file join $tb_dir tb_bsearch.sv   ] \
        [file join $tb_dir tb_cpu.sv       ] \
    ]
    add_files -fileset sim_1 -norecurse $tb_files
    set_property file_type SystemVerilog \
        [get_files -of_objects [get_filesets sim_1] -filter {NAME =~ *.sv}]
    set_property include_dirs [list $rtl_dir] [get_filesets sim_1]
    set_property xsim.simulate.runtime "" [get_filesets sim_1]
    set_property top     tb_cpu        [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    update_compile_order -fileset sim_1
    puts "\[INFO\]  Testbenches added (13 files)."

    puts ""
    puts "==================================================================="
    puts "  Helix  |  Project ready (Vivado)."
    puts "  To simulate, pick a TB top and launch from the GUI or Tcl:"
    puts "    set_property top tb_cpu \[get_filesets sim_1\]"
    puts "    launch_simulation"
    puts "    run all"
    puts "    close_simulation"
    puts "==================================================================="

}

puts ""
