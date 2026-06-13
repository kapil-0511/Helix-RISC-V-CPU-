`timescale 1ns/1ps
`include "defines.v"
// tb_array_sum.sv — C[i] = A[i] + B[i] for i=0..24  (N=25)
// Helix adaptation: halt detected only when stage==4 (WB); timeout ×5

module tb_array_sum;

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

    task automatic load_program();
        int addr;
        $display("[APB] Loading array-sum program (N=25)...");
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));
        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'd256)); addr += 4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd512)); addr += 4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd768)); addr += 4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd3, 4'd0, 16'd25));  addr += 4;
        // loop top (word 36)
        apb_write(addr, enc_load(4'd4, 4'd0, 16'd0));                      addr += 4;
        apb_write(addr, enc_load(4'd5, 4'd1, 16'd0));                      addr += 4;
        apb_write(addr, enc_r(`FR_ADD, 4'd6, 4'd4, 4'd5));                addr += 4;
        apb_write(addr, enc_store(4'd6, 4'd2, 16'd0));                     addr += 4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd0, 4'd0, 16'd4));             addr += 4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd1, 4'd1, 16'd4));             addr += 4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd2, 4'd2, 16'd4));             addr += 4;
        apb_write(addr, enc_u(`FU_DEC, 4'd3));                             addr += 4;
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFF8));                    addr += 4; // BNE -8
        apb_write(addr, enc_b(`COND_AL, 25'd0));
        $display("[APB] Program load complete");
    endtask

    task automatic load_arrays();
        dut.u_dmem.mem[64]  = 32'd427; dut.u_dmem.mem[65]  = 32'd83;
        dut.u_dmem.mem[66]  = 32'd612; dut.u_dmem.mem[67]  = 32'd951;
        dut.u_dmem.mem[68]  = 32'd38;  dut.u_dmem.mem[69]  = 32'd776;
        dut.u_dmem.mem[70]  = 32'd245; dut.u_dmem.mem[71]  = 32'd18;
        dut.u_dmem.mem[72]  = 32'd534; dut.u_dmem.mem[73]  = 32'd889;
        dut.u_dmem.mem[74]  = 32'd162; dut.u_dmem.mem[75]  = 32'd723;
        dut.u_dmem.mem[76]  = 32'd57;  dut.u_dmem.mem[77]  = 32'd398;
        dut.u_dmem.mem[78]  = 32'd841; dut.u_dmem.mem[79]  = 32'd127;
        dut.u_dmem.mem[80]  = 32'd690; dut.u_dmem.mem[81]  = 32'd315;
        dut.u_dmem.mem[82]  = 32'd472; dut.u_dmem.mem[83]  = 32'd936;
        dut.u_dmem.mem[84]  = 32'd204; dut.u_dmem.mem[85]  = 32'd581;
        dut.u_dmem.mem[86]  = 32'd743; dut.u_dmem.mem[87]  = 32'd29;
        dut.u_dmem.mem[88]  = 32'd667;
        dut.u_dmem.mem[128] = 32'd312; dut.u_dmem.mem[129] = 32'd758;
        dut.u_dmem.mem[130] = 32'd44;  dut.u_dmem.mem[131] = 32'd629;
        dut.u_dmem.mem[132] = 32'd891; dut.u_dmem.mem[133] = 32'd155;
        dut.u_dmem.mem[134] = 32'd483; dut.u_dmem.mem[135] = 32'd726;
        dut.u_dmem.mem[136] = 32'd367; dut.u_dmem.mem[137] = 32'd52;
        dut.u_dmem.mem[138] = 32'd814; dut.u_dmem.mem[139] = 32'd298;
        dut.u_dmem.mem[140] = 32'd641; dut.u_dmem.mem[141] = 32'd175;
        dut.u_dmem.mem[142] = 32'd523; dut.u_dmem.mem[143] = 32'd869;
        dut.u_dmem.mem[144] = 32'd431; dut.u_dmem.mem[145] = 32'd77;
        dut.u_dmem.mem[146] = 32'd918; dut.u_dmem.mem[147] = 32'd286;
        dut.u_dmem.mem[148] = 32'd643; dut.u_dmem.mem[149] = 32'd109;
        dut.u_dmem.mem[150] = 32'd854; dut.u_dmem.mem[151] = 32'd462;
        dut.u_dmem.mem[152] = 32'd733;
        $display("[TB]  A[0..24] and B[0..24] loaded");
    endtask

    task automatic verify();
        int pass, fail;
        logic [31:0] a, b, c, expected;
        pass = 0; fail = 0;
        $display("----------------------------------------------------");
        $display("  i |    A |    B |  A+B | C[i] | result");
        $display("----------------------------------------------------");
        for (int i = 0; i < 25; i++) begin
            a        = dut.u_dmem.mem[64  + i];
            b        = dut.u_dmem.mem[128 + i];
            c        = dut.u_dmem.mem[192 + i];
            expected = a + b;
            if (c === expected) begin
                $display(" %2d | %4d | %4d | %4d | %4d | PASS", i, a, b, expected, c);
                pass++;
            end else begin
                $display(" %2d | %4d | %4d | %4d | %4d | FAIL ***", i, a, b, expected, c);
                fail++;
            end
        end
        $display("----------------------------------------------------");
        if (fail == 0) $display("*** ALL 25 ELEMENTS CORRECT ***");
        else           $display("!!! %0d ELEMENTS WRONG !!!", fail);
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
        load_arrays();

        @(negedge clk); rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting  (CPI=5, timeout=4000 cycles)");

        fork
            begin
                repeat(4000) @(posedge clk);
                $display("TIMEOUT: 4000 cycles");
                $stop;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.stage == 3'd4)) begin
                        if (dut.pc === prev_pc) begin
                            @(posedge clk);
                            $display("=== ARRAY SUM COMPLETE ===");
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

    always_ff @(posedge clk)
        if (rst_n) cycle_count++;

    initial begin
        $dumpfile("tb_array_sum.vcd");
        $dumpvars(0, tb_array_sum);
    end

endmodule
