# =============================================================================
# setup_project.tcl  —  ARIA-32  5-Stage Sequential Pipeline
# =============================================================================
# Works in BOTH Vivado Tcl console AND ModelSim / Questa.
# Auto-detects the simulator at runtime.
#
# Vivado Tcl console:
#   source C:/Users/kapily/Downloads/aria32_5stage/sim/setup_project.tcl
#
# ModelSim / Questa batch:
#   vsim -c -do "source setup_project.tcl" -do "quit -f"
#
# ModelSim / Questa GUI console:
#   do setup_project.tcl
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set rtl_dir    [file normalize [file join $script_dir .. rtl]]
set tb_dir     [file normalize [file join $script_dir .. tb]]

puts ""
puts "==================================================================="
puts "  ARIA-32  5-Stage  |  Project Setup"
puts "==================================================================="

# ── Detect simulator ──────────────────────────────────────────────────────────
# Vivado has create_project; ModelSim/Questa has vlib.
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
# ── VIVADO path ───────────────────────────────────────────────────────────────
# =============================================================================
if {$SIM_TOOL eq "vivado"} {

    set proj_dir [file normalize [file join $script_dir vivado_proj]]
    puts "\[INFO\]  Project   : $proj_dir"

    # Create project (xc7a35tcpg236-1 = Artix-7, free WebPACK — part is
    # irrelevant for simulation but Vivado requires one)
    create_project -force aria32_5stage $proj_dir -part xc7a35tcpg236-1

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

    # defines.v is `included by other files — not a standalone compile unit.
    # Marking it as a Verilog Header stops Vivado from compiling it solo.
    set_property file_type {Verilog Header} [get_files */defines.v]

    set_property include_dirs [list $rtl_dir] [get_filesets sources_1]
    puts "\[INFO\]  RTL compiled OK (8 files)."

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
    foreach f $tb_files {
        set_property file_type SystemVerilog [get_files $f]
    }
    set_property include_dirs [list $rtl_dir] [get_filesets sim_1]

    # Let TBs control termination via $finish — no forced xsim timeout
    set_property xsim.simulate.runtime "" [get_filesets sim_1]
    puts "\[INFO\]  Testbenches added OK (12 files)."

    puts ""
    puts "==================================================================="
    puts "  Setup complete (Vivado).  Run simulations with:"
    puts "    source $script_dir/run_all.tcl"
    puts ""
    puts "  Or run one TB manually:"
    puts "    set_property top tb_power \[get_filesets sim_1\]"
    puts "    launch_simulation"
    puts "    run all"
    puts "    close_simulation"
    puts "==================================================================="

# =============================================================================
# ── MODELSIM / QUESTA path ────────────────────────────────────────────────────
# =============================================================================
} else {

    # ── Work library ──────────────────────────────────────────────────────────
    if {[file exists work]} {
        puts "\[INFO\]  Removing existing 'work' library..."
        vdel -lib work -all
    }
    vlib work
    vmap work work
    puts "\[INFO\]  'work' library created."

    # ── RTL sources ───────────────────────────────────────────────────────────
    puts ""
    puts "\[COMPILE\]  RTL sources..."
    vlog -sv +incdir+$rtl_dir \
        $rtl_dir/defines.v    \
        $rtl_dir/alu.v        \
        $rtl_dir/control.v    \
        $rtl_dir/reg_file.v   \
        $rtl_dir/cond_check.v \
        $rtl_dir/data_mem.v   \
        $rtl_dir/inst_mem.v   \
        $rtl_dir/cpu_top.v

    if {$errorCode ne "NONE"} {
        puts "\[ERROR\]  RTL compilation failed. Stopping."
        return
    }
    puts "\[INFO\]  RTL compiled OK (8 files)."

    # ── Testbenches ───────────────────────────────────────────────────────────
    puts ""
    puts "\[COMPILE\]  Testbenches..."
    vlog -sv +incdir+$rtl_dir   \
        $tb_dir/tb_memcpy.sv    \
        $tb_dir/tb_array_sum.sv \
        $tb_dir/tb_minmax.sv    \
        $tb_dir/tb_sort.sv      \
        $tb_dir/tb_factorial.sv \
        $tb_dir/tb_bitops.sv    \
        $tb_dir/tb_gcd.sv       \
        $tb_dir/tb_power.sv     \
        $tb_dir/tb_isqrt.sv     \
        $tb_dir/tb_collatz.sv   \
        $tb_dir/tb_fibonacci.sv \
        $tb_dir/tb_bsearch.sv   \
        $tb_dir/tb_cpu.sv

    if {$errorCode ne "NONE"} {
        puts "\[ERROR\]  Testbench compilation failed. Stopping."
        return
    }
    puts "\[INFO\]  Testbenches compiled OK (12 files)."

    puts ""
    puts "==================================================================="
    puts "  Setup complete (ModelSim/Questa).  Run simulations with:"
    puts "    source run_all.tcl"
    puts "  Or individually:"
    puts "    source run_memcpy.tcl   source run_array_sum.tcl"
    puts "    source run_minmax.tcl   source run_sort.tcl"
    puts "    source run_factorial.tcl source run_bitops.tcl"
    puts "    source run_gcd.tcl      source run_power.tcl"
    puts "    source run_isqrt.tcl    source run_collatz.tcl"
    puts "    source run_fibonacci.tcl source run_bsearch.tcl"
    puts "==================================================================="
}

puts ""
