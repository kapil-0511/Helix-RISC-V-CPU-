`timescale 1ns/1ps
`include "defines.v"
// tb_factorial.sv — Iterative factorial via BL/BX subroutine, n=0..12
// Helix adaptation: halt detected only when stage==4 (WB); timeout ×5

module tb_factorial;

    logic        clk, pclk, rst_n, prst_n, irq, fiq;
    logic [31:0] paddr, pwdata, prdata;
    logic        psel, penable, pwrite, pready, pslverr;

    cpu_top dut (
        .clk(clk), .pclk(pclk), .rst_n(rst_n), .prst_n(prst_n),
        .irq(irq), .fiq(fiq),
        .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr)
    );

    initial clk  = 0; always #5  clk  = ~clk;
    initial pclk = 0; always #8  pclk = ~pclk;

    task automatic apb_write(input logic [31:0] addr, data);
        @(negedge pclk);
        paddr = addr; pwdata = data; pwrite = 1'b1; psel = 1'b1; penable = 1'b0;
        @(negedge pclk); penable = 1'b1;
        @(posedge pclk); while (!pready) @(posedge pclk);
        @(negedge pclk); psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    endtask

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
    function automatic logic [31:0] enc_ctrl(input logic [4:0] funct);
        return {`FMT_CTRL, funct, 24'd0};
    endfunction
    function automatic logic [31:0] enc_bl(input logic [19:0] imm20);
        return {`FMT_JUMP, `FJ_BL, 4'b0, imm20};
    endfunction
    function automatic logic [31:0] enc_bx(input logic [3:0] rd);
        return {`FMT_JUMP, `FJ_BX, rd, 20'b0};
    endfunction

    task automatic load_program();
        int addr;
        $display("[APB] Loading factorial program (n=0..12)...");
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));
        // Main (word 32)
        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd256)); addr += 4; // MOVI R5,#256
        apb_write(addr, enc_i(`FI_MOVI, 4'd6, 4'd0, 16'd512)); addr += 4; // MOVI R6,#512
        apb_write(addr, enc_i(`FI_MOVI, 4'd7, 4'd0, 16'd13));  addr += 4; // MOVI R7,#13
        // loop top (word 35)
        apb_write(addr, enc_load(4'd0, 4'd5, 16'd0));           addr += 4; // LDR  R0,[R5,0]
        apb_write(addr, enc_bl(20'd7));                          addr += 4; // BL +7 → word 43
        // return path (word 37)
        apb_write(addr, enc_store(4'd1, 4'd6, 16'd0));          addr += 4; // STR  R1,[R6,0]
        apb_write(addr, enc_i(`FI_ADDI, 4'd5, 4'd5, 16'd4));   addr += 4; // ADDI R5,R5,#4
        apb_write(addr, enc_i(`FI_ADDI, 4'd6, 4'd6, 16'd4));   addr += 4; // ADDI R6,R6,#4
        apb_write(addr, enc_u(`FU_DEC, 4'd7));                  addr += 4; // DEC  R7
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFFA));          addr += 4; // BNE -6 → word 35
        apb_write(addr, enc_b(`COND_AL, 25'd0));                addr += 4; // halt
        // addr = 0x0AC = word 43 — subroutine
        apb_write(addr, enc_u(`FU_PUSH, 4'd14));                addr += 4; // PUSH R14
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd1));   addr += 4; // MOVI R1,#1
        apb_write(addr, enc_r(`FR_TST, 4'd0, 4'd0, 4'd0));     addr += 4; // TST  R0,R0
        apb_write(addr, enc_b(`COND_EQ, 25'd4));                addr += 4; // BEQ +4 → pop/ret
        // inner loop (word 47)
        apb_write(addr, enc_r(`FR_MUL, 4'd1, 4'd1, 4'd0));     addr += 4; // MUL  R1,R1,R0
        apb_write(addr, enc_u(`FU_DEC, 4'd0));                  addr += 4; // DEC  R0
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFFE));          addr += 4; // BNE -2 → word 47
        // word 50
        apb_write(addr, enc_u(`FU_POP, 4'd14));                 addr += 4; // POP  R14
        apb_write(addr, enc_bx(4'd14));                                     // BX   R14
        $display("[APB] Program load complete");
    endtask

    task automatic load_inputs();
        for (int i = 0; i <= 12; i++)
            dut.u_dmem.mem[64 + i] = 32'(i);
        $display("[TB]  n=0..12 loaded into DMEM[64..76]");
    endtask

    localparam logic [31:0] EXPECTED [0:12] = '{
        32'd1, 32'd1, 32'd2, 32'd6, 32'd24, 32'd120, 32'd720,
        32'd5040, 32'd40320, 32'd362880, 32'd3628800, 32'd39916800, 32'd479001600
    };

    task automatic verify();
        int fail;
        logic [31:0] got;
        fail = 0;
        $display("---------------------------------------------");
        $display("  n | expected    | actual      | result");
        $display("---------------------------------------------");
        for (int n = 0; n <= 12; n++) begin
            got = dut.u_dmem.mem[128 + n];
            if (got === EXPECTED[n])
                $display(" %2d | %11d | %11d | PASS", n, EXPECTED[n], got);
            else begin
                $display(" %2d | %11d | %11d | FAIL ***", n, EXPECTED[n], got);
                fail++;
            end
        end
        $display("---------------------------------------------");
        if (fail == 0) $display("*** PASS — all 13 factorials correct (0!..12!) ***");
        else           $display("!!! FAIL — %0d factorials wrong !!!", fail);
    endtask

    int          cycle_count;
    logic [31:0] prev_pc;

    initial begin
        irq = 0; fiq = 0;
        rst_n = 0; prst_n = 1;
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        cycle_count = 0;
        prev_pc = 32'hFFFF_FFFF;

        repeat(2) @(posedge pclk); #1;
        load_program();
        load_inputs();

        @(negedge clk); rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting  (CPI=5, timeout=7000 cycles)");

        fork
            begin
                repeat(7000) @(posedge clk);
                $display("TIMEOUT: 7000 cycles");
                $stop;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.stage == 3'd4)) begin
                        if (dut.pc === prev_pc) begin
                            @(posedge clk);
                            $display("=== FACTORIAL COMPLETE ===");
                            $display("PC stopped at : 0x%08h", dut.pc);
                            $display("Cycles        : %0d", cycle_count);
                            verify();
                            $stop;
                        end
                        prev_pc = dut.pc;
                    end
                end
            end
        join
    end

    always_ff @(posedge clk) if (rst_n) cycle_count++;

    initial begin
        $dumpfile("tb_factorial.vcd");
        $dumpvars(0, tb_factorial);
    end

endmodule
