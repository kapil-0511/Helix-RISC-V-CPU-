# Helix — 5-Stage Pipelined 32-bit CPU

A 5-stage sequential pipeline CPU implemented in Verilog, executing the same custom 32-bit ISA as the single-cycle **Impulse** design. The pipeline stages (IF → ID → EX → MEM → WB) each take one clock cycle, giving a CPI of 5 with one instruction in flight at a time. No data hazards or structural hazards exist by design. The project includes 13 SystemVerilog testbenches covering a wide range of algorithms, all verified PASS.

---

## Features

- 32-bit custom RISC ISA (identical to Impulse)
- 5-stage sequential pipeline — IF / ID / EX / MEM / WB
- CPI = 5 (one instruction per 5 clocks)
- No hazards — one instruction in flight at any time
- 16 general-purpose 32-bit registers (R0–R15)
- Dedicated SP (R13), LR (R14), PC (R15 alias)
- ALU: ADD, SUB, MUL, AND, OR, XOR, NOT, LSL, LSR, CMP
- 7 condition codes: AL, EQ, NE, GT, LT, GE, LE
- APB slave interface for program and data loading
- IRQ / FIQ interrupt support with RETI return
- 256-word instruction memory and 256-word data memory
- 13 algorithm testbenches — all verified PASS

---

## Pipeline Architecture

```
 Clock:   0        1        2        3        4        5 ...
          ┌────────┬────────┬────────┬────────┬────────┐
 Instr N  │   IF   │   ID   │   EX   │  MEM   │   WB   │
          └────────┴────────┴────────┴────────┴────────┘
                            (next instruction enters IF only after WB)
```

| Stage | Index | Work Performed |
|---|---|---|
| IF — Instruction Fetch | 0 | Read IMEM[pc]; latch into IF/ID register |
| ID — Instruction Decode | 1 | Decode instruction; read register file; latch into ID/EX |
| EX — Execute | 2 | ALU operation; compute branch target; latch into EX/MEM |
| MEM — Memory Access | 3 | DMEM read (LDR) or write (STR); latch into MEM/WB |
| WB — Write Back | 4 | Write result to register file; update architectural PC |

> **Key point:** The architectural PC is updated only at WB (stage 4). All testbenches gate halt detection with `if (dut.stage == 3'd4)`.

| Property | Value |
|---|---|
| Architecture | 5-stage sequential pipeline |
| CPI | 5 |
| Pipeline registers | IF/ID, ID/EX, EX/MEM, MEM/WB |
| Hazards | None — single in-flight instruction |
| Register file | 16 × 32-bit, write gated to WB stage |
| DMEM write | Gated to MEM stage (stage == 3) |
| Interrupt modes | SYS / IRQ / FIQ |

---

## Instruction Set Summary

| Format | Instructions |
|---|---|
| R-type | ADD, SUB, MUL, AND, OR, XOR, NOT, LSL, LSR, CMP |
| I-type | MOVI, ADDI, SUBI |
| Load / Store | LDR, STR |
| Branch | B {cond}, BL, BX |
| Unary | INC, DEC, PUSH, POP |
| Control | NOP, RETI |

---

## Repository Structure

```
aria32_5stage/
├── rtl/
│   ├── cpu_top.v        # Top-level: 5-stage FSM + pipeline registers
│   ├── alu.v            # 32-bit ALU
│   ├── control.v        # Instruction decoder
│   ├── reg_file.v       # 16×32 register file
│   ├── cond_check.v     # Condition code evaluator
│   ├── inst_mem.v       # Instruction SRAM (APB-loaded)
│   ├── data_mem.v       # Data SRAM (write gated to MEM stage)
│   └── defines.v        # ISA constants and opcodes
├── tb/
│   ├── tb_cpu.sv        # ISA integration test
│   ├── tb_memcpy.sv     # Memory copy loop
│   ├── tb_array_sum.sv  # Element-wise vector addition
│   ├── tb_minmax.sv     # Min / max linear scan
│   ├── tb_sort.sv       # Bubble sort
│   ├── tb_factorial.sv  # Factorial via BL/BX subroutine
│   ├── tb_bitops.sv     # Bitwise operations
│   ├── tb_gcd.sv        # GCD (Euclidean)
│   ├── tb_power.sv      # Fast exponentiation
│   ├── tb_isqrt.sv      # Integer square root
│   ├── tb_collatz.sv    # Collatz sequence
│   ├── tb_fibonacci.sv  # Fibonacci sequence
│   └── tb_bsearch.sv    # Binary search
└── sim/
    ├── setup_project.tcl  # Vivado / ModelSim project setup
    └── run_all.tcl        # Run all 13 testbenches in sequence
```

---

## Getting Started

### Requirements

- Vivado 2020.1 or later (for xsim behavioral simulation)  
  **or** ModelSim / Questa

### Vivado (GUI or Tcl console)

```tcl
# 1. Open Vivado, then in the Tcl console:
source C:/path/to/aria32_5stage/sim/setup_project.tcl

# 2. Run all testbenches:
source C:/path/to/aria32_5stage/sim/run_all.tcl
```

### ModelSim / Questa

```tcl
vsim -c -do "source sim/setup_project.tcl" -do "quit -f"
vsim -c -do "source sim/run_all.tcl"       -do "quit -f"
```

### Run a single testbench manually (Vivado)

```tcl
set_property top tb_sort [get_filesets sim_1]
launch_simulation
run all
close_simulation
```

---

## Testbench Results

| # | Testbench | Description | Timeout | Result |
|---|---|---|---|---|
| 1 | tb_cpu | ISA integration — all instruction categories | 2500 cycles | PASS |
| 2 | tb_memcpy | 10-word memory copy loop | 2500 cycles | PASS |
| 3 | tb_array_sum | C[i] = A[i] + B[i], N=25 | 4000 cycles | PASS |
| 4 | tb_minmax | Min / max scan, N=25 | 3500 cycles | PASS |
| 5 | tb_sort | Bubble sort ascending, N=25 | 15000 cycles | PASS |
| 6 | tb_factorial | 0! through 12! via BL/BX subroutine | 7000 cycles | PASS |
| 7 | tb_bitops | AND/OR/XOR/NOT/LSL/LSR × 8 inputs | 2500 cycles | PASS |
| 8 | tb_gcd | Euclidean GCD × 6 pairs | 5000 cycles | PASS |
| 9 | tb_power | Binary exponentiation × 8 pairs | 6000 cycles | PASS |
| 10 | tb_isqrt | Integer square root × 10 values | 18000 cycles | PASS |
| 11 | tb_collatz | Collatz steps-to-1 × 8 values | 20000 cycles | PASS |
| 12 | tb_fibonacci | Fibonacci F(n) × 8 values | 5000 cycles | PASS |
| 13 | tb_bsearch | Binary search, 16 queries / 150-element array | 30000 cycles | PASS |

Timeouts are ×5 relative to the single-cycle Impulse design (CPI = 5).  
All 13 testbenches verified using Vivado 2025.1 xsim behavioral simulation.

---

## Simulation Notes

- Programs are loaded into instruction memory via the APB interface while `rst_n = 0`, `prst_n = 1`.
- Set `rst_n = 1` to start CPU execution.
- All testbenches call `$stop` (not `$finish`) so Vivado can cleanly close the simulation session between runs.
- Halt is detected when `dut.pc` is unchanged between two consecutive WB completions (`dut.stage == 3'd4`).
- Do **not** sample `dut.pc` at stages 0–3 — the value is stale or speculative until WB commits it.
- VCD waveform files are generated automatically for each testbench.

---

## Comparison with Impulse (Single-Cycle)

| Property | Impulse | Helix |
|---|---|---|
| Stages | 1 (combinational) | 5 (IF/ID/EX/MEM/WB) |
| CPI | 1 | 5 |
| Pipeline registers | None | IF/ID, ID/EX, EX/MEM, MEM/WB |
| Halt detection | Any posedge clk | Only at stage == 4 (WB) |
| Testbench timeouts | Baseline | ×5 |
| RTL files | Identical submodules | Same submodules + FSM wrapper |

---

## License

This project is released for educational and academic use.
