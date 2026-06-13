`timescale 1ns/1ps
`include "defines.v"
// tb_cpu.sv — Helix | General CPU integration test
//
// Covers: arithmetic (ADD/SUB/MUL), bitwise (AND/OR/XOR/NOT/LSL/LSR),
//         branch taken/not-taken (BGT/BNE), load/store round-trip,
//         INC/DEC, PUSH/POP, BL/BX subroutine, interrupt vector table.
//
// Timeout: 2500 cycles (single-cycle was 500; CPI=5 → ×5).
// Halt detection: PC sampled only at stage==4 (WB), when PC is architectural.

module tb_cpu;

    // ── DUT signals ──────────────────────────────────────────────────────────
    logic        clk, pclk, rst_n, prst_n, irq, fiq;
    logic [31:0] paddr, pwdata, prdata;
    logic        psel, penable, pwrite, pready, pslverr;

    cpu_top dut (
        .clk     (clk),
        .pclk    (pclk),
        .rst_n   (rst_n),
        .prst_n  (prst_n),
        .irq     (irq),
        .fiq     (fiq),
        .paddr   (paddr),
        .psel    (psel),
        .penable (penable),
        .pwrite  (pwrite),
        .pwdata  (pwdata),
        .prdata  (prdata),
        .pready  (pready),
        .pslverr (pslverr)
    );

    initial clk  = 0; always #5  clk  = ~clk;
    initial pclk = 0; always #8  pclk = ~pclk;

    // ── APB master task ───────────────────────────────────────────────────────
    task automatic apb_write(input logic [31:0] addr, data);
        @(negedge pclk);
        paddr = addr; pwdata = data; pwrite = 1'b1; psel = 1'b1; penable = 1'b0;
        @(negedge pclk);
        penable = 1'b1;
        @(posedge pclk);
        while (!pready) @(posedge pclk);
        @(negedge pclk);
        psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    endtask

    // ── Encoding helpers ──────────────────────────────────────────────────────
    function automatic logic [31:0] enc_r(input logic [4:0] funct, input logic [3:0] rd, rs1, rs2);
        return {`FMT_R, funct, rd, rs1, rs2, 12'd0};
    endfunction
    function automatic logic [31:0] enc_i(input logic [4:0] funct, input logic [3:0] rd, rs1, input logic [15:0] imm);
        return {`FMT_I, funct, rd, rs1, imm};
    endfunction
    function automatic logic [31:0] enc_load(input logic [3:0] rd, rb, input logic [15:0] off);
        return {`FMT_LOAD, `FL_LDR, rd, rb, off};
    endfunction
    function automatic logic [31:0] enc_store(input logic [3:0] rs, rb, input logic [15:0] off);
        return {`FMT_STORE, `FS_STR, rs, rb, off};
    endfunction
    function automatic logic [31:0] enc_b(input logic [3:0] cond, input logic [24:0] imm25);
        return {`FMT_BRANCH, cond, imm25};
    endfunction
    function automatic logic [31:0] enc_u(input logic [4:0] funct, input logic [3:0] rd);
        return {`FMT_UNARY, funct, rd, 20'd0};
    endfunction
    function automatic logic [31:0] enc_bl(input logic [19:0] imm20);
        return {`FMT_JUMP, `FJ_BL, 4'd0, imm20};
    endfunction
    function automatic logic [31:0] enc_bx(input logic [3:0] rd);
        return {`FMT_JUMP, `FJ_BX, rd, 20'd0};
    endfunction
    function automatic logic [31:0] enc_ctrl(input logic [4:0] funct);
        return {`FMT_CTRL, funct, 24'd0};
    endfunction

    // ── Program loader ────────────────────────────────────────────────────────
    // Word layout:
    //   Word  0 = 0x000  B AL → word 32 (main)
    //   Word  6 = 0x018  IRQ handler: RETI
    //   Word  7 = 0x01C  FIQ handler: RETI
    //   Word 32 = 0x080  main: arithmetic, bitwise, branch, ld/st, stack, BL
    //   Word 57 = 0x0E4  B AL #0 (halt loop)
    //   Word 58 = 0x0E8  sub_add2: INC R2
    //   Word 59 = 0x0EC  sub_add2: INC R2
    //   Word 60 = 0x0F0  sub_add2: BX R14

    task automatic load_program();
        int addr;
        $display("[APB] Loading program...");

        // Vector table
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));   // B AL → word 32
        apb_write(32'h018, enc_ctrl(`FC_RETI));          // IRQ handler: RETI
        apb_write(32'h01C, enc_ctrl(`FC_RETI));          // FIQ handler: RETI

        // Main (word 32 = 0x080)
        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'd10));    addr += 4; // MOVI R0, #10
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd3));     addr += 4; // MOVI R1, #3
        apb_write(addr, enc_r(`FR_ADD,  4'd2, 4'd0, 4'd1));      addr += 4; // ADD  R2, R0, R1 → 13
        apb_write(addr, enc_r(`FR_SUB,  4'd3, 4'd0, 4'd1));      addr += 4; // SUB  R3, R0, R1 → 7
        apb_write(addr, enc_r(`FR_MUL,  4'd4, 4'd0, 4'd1));      addr += 4; // MUL  R4, R0, R1 → 30
        apb_write(addr, enc_r(`FR_AND,  4'd7,  4'd2, 4'd1));     addr += 4; // AND  R7,  R2, R1 → 1
        apb_write(addr, enc_r(`FR_OR,   4'd8,  4'd2, 4'd1));     addr += 4; // OR   R8,  R2, R1 → 15
        apb_write(addr, enc_r(`FR_XOR,  4'd9,  4'd2, 4'd1));     addr += 4; // XOR  R9,  R2, R1 → 14
        apb_write(addr, enc_r(`FR_NOT,  4'd10, 4'd2, 4'd0));     addr += 4; // NOT  R10, R2     → ~13
        apb_write(addr, enc_r(`FR_LSL,  4'd11, 4'd1, 4'd1));     addr += 4; // LSL  R11, R1, R1 → 24
        apb_write(addr, enc_r(`FR_LSR,  4'd12, 4'd4, 4'd1));     addr += 4; // LSR  R12, R4, R1 → 3
        // Branch test: 13 > 7 → BGT taken, skips FAIL word
        apb_write(addr, enc_r(`FR_CMP,  4'd0,  4'd2, 4'd3));     addr += 4; // CMP  R2, R3
        apb_write(addr, enc_b(`COND_GT, 25'd2));                  addr += 4; // BGT  +2 → skip FAIL
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd0));     addr += 4; // MOVI R5, #0     (FAIL)
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'h0BEF));  addr += 4; // MOVI R5, #0xBEF (PASS)
        // Load/store round-trip
        apb_write(addr, enc_store(4'd5, 4'd0, 16'd0));            addr += 4; // STR  R5, [R0]
        apb_write(addr, enc_load (4'd6, 4'd0, 16'd0));            addr += 4; // LDR  R6, [R0]
        apb_write(addr, enc_r(`FR_CMP,  4'd0,  4'd5, 4'd6));     addr += 4; // CMP  R5, R6 → Z=1
        // BNE not taken (Z=1)
        apb_write(addr, enc_b(`COND_NE, 25'd2));                  addr += 4; // BNE  +2 (not taken)
        apb_write(addr, enc_u(`FU_INC,  4'd2));                   addr += 4; // INC  R2 → 14
        apb_write(addr, enc_u(`FU_DEC,  4'd2));                   addr += 4; // DEC  R2 → 13
        // Stack: PUSH R5 → POP R15 (R15 should == R5 == 0xBEF)
        apb_write(addr, enc_u(`FU_PUSH, 4'd5));                   addr += 4; // PUSH R5
        apb_write(addr, enc_u(`FU_POP,  4'd15));                  addr += 4; // POP  R15
        // BL sub_add2 (+2 words ahead relative to BL's PC+4)
        apb_write(addr, enc_bl(20'd2));                            addr += 4; // BL   sub_add2
        apb_write(addr, enc_b(`COND_AL, 25'd0));                  addr += 4; // B AL #0 (halt)
        // sub_add2 (called via BL above → R2 ends at 15)
        apb_write(addr, enc_u(`FU_INC,  4'd2));                   addr += 4; // INC  R2 → 14
        apb_write(addr, enc_u(`FU_INC,  4'd2));                   addr += 4; // INC  R2 → 15
        apb_write(addr, enc_bx(4'd14));                                       // BX   R14

        $display("[APB] Program load complete");
    endtask

    // ── Verify and display results ────────────────────────────────────────────
    task automatic verify();
        $display("=== CPU INTEGRATION TEST COMPLETE ===");
        $display("PC stopped at : 0x%08h", dut.pc);
        $display("R0  = %0d  (expected 10)",   dut.u_rf.r0);
        $display("R1  = %0d  (expected 3)",    dut.u_rf.r1);
        $display("R2  = %0d  (expected 15)",   dut.u_rf.r2);
        $display("R3  = %0d  (expected 7)",    dut.u_rf.r3);
        $display("R4  = %0d  (expected 30)",   dut.u_rf.r4);
        $display("R5  = %0d  (expected 3055)", dut.u_rf.r5);
        $display("R6  = %0d  (expected 3055)", dut.u_rf.r6);
        $display("R7  = %0d  (expected 1)",    dut.u_rf.r7);
        $display("R8  = %0d  (expected 15)",   dut.u_rf.r8);
        $display("R9  = %0d  (expected 14)",   dut.u_rf.r9);
        $display("R11 = %0d  (expected 24)",   dut.u_rf.r11);
        $display("R12 = %0d  (expected 3)",    dut.u_rf.r12);
        $display("R15 = %0d  (expected 3055)", dut.u_rf.r15);
        $display("SP  = 0x%08h (expected 0x%08h)", dut.sp, `SP_INIT);
        $display("SR  = 0b%06b", dut.sr);

        if (dut.u_rf.r2  == 32'd15   &&
            dut.u_rf.r5  == dut.u_rf.r6  &&
            dut.u_rf.r15 == dut.u_rf.r5  &&
            dut.sp       == `SP_INIT)
            $display("*** ALL CHECKS PASSED ***");
        else
            $display("!!! SOME CHECKS FAILED !!!");
    endtask

    // ── Cycle counter (counts only when CPU is running) ───────────────────────
    int cycle_count;
    always_ff @(posedge clk)
        if (rst_n) cycle_count++;

    // ── Main driver ──────────────────────────────────────────────────────────
    logic [31:0] prev_pc;

    initial begin
        irq = 0; fiq = 0;
        rst_n = 0; prst_n = 1;
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        cycle_count = 0;
        prev_pc = 32'hFFFF_FFFF;

        repeat(2) @(posedge pclk); #1;
        load_program();

        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting  (CPI=5, timeout=2500 cycles)");

        fork
            // Timeout watchdog
            begin
                repeat(2500) @(posedge clk);
                $display("TIMEOUT: 2500 cycles elapsed without halt");
                $stop;
            end
            // Halt detection: sample PC only at WB (stage==4)
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.stage == 3'd4)) begin
                        if (dut.pc === prev_pc) begin
                            @(posedge clk);
                            verify();
                            $stop;
                        end
                        prev_pc = dut.pc;
                    end
                end
            end
        join
    end

    // ── IRQ pulse at cycle ~500 in SYS mode ──────────────────────────────────
    initial begin
        repeat(500) @(posedge clk);
        if (dut.cpu_mode == `MODE_SYS) begin
            irq = 1;
            @(posedge clk);
            irq = 0;
            $display("[TB]  IRQ pulsed at cycle ~500");
        end
    end

    initial begin
        $dumpfile("tb_cpu.vcd");
        $dumpvars(0, tb_cpu);
    end

endmodule
