`timescale 1ns/1ps
`include "defines.v"
// cpu_top.v — Helix  |  Pipelined CPU
//
// Stages: IF(0) -> ID(1) -> EX(2) -> MEM(3) -> WB(4) -> IF(0) ...
// One instruction occupies the entire pipeline at a time.
// The next instruction enters IF only after WB completes.  CPI = 5.
// No data hazards, no structural hazards, no control hazards.
//
// Sub-modules (alu, control, reg_file, cond_check, inst_mem, data_mem)
// are identical to the single-cycle Impulse design.
//
// Datapath summary:
//   IF  : pc -> IMEM async read -> latch [ifid_pc, ifid_inst]
//   ID  : decode ifid_inst; read reg_file -> latch [idex_*]
//   EX  : ALU; branch/BL targets; cond_check; mem addr -> latch [exmem_*]
//   MEM : DMEM read/write (dmem_we gated to stage==3) -> latch [memwb_*]
//   WB  : rf write (gated to stage==4); update pc/sp/sr; stage -> 0

module cpu_top (
    input  clk,
    input  pclk,
    input  rst_n,    // CPU reset  (active low) - clears all state, PC=0
    input  prst_n,   // APB reset  (active low) - gates APB, no memory clear
    input  irq,
    input  fiq,
    input  [31:0] paddr,
    input         psel,
    input         penable,
    input         pwrite,
    input  [31:0] pwdata,
    output [31:0] prdata,
    output        pready,
    output        pslverr
);

// ── Architectural state ──────────────────────────────────────────────────
reg [31:0] pc;
reg [31:0] sp;
reg [5:0]  sr;          // [5:F][4:I][3:V][2:C][1:N][0:Z]
reg [2:0]  stage;       // 0=IF 1=ID 2=EX 3=MEM 4=WB
reg [1:0]  cpu_mode;    // 00=SYS 01=IRQ 10=FIQ
reg [31:0] lr_irq,  lr_fiq;
reg [5:0]  spsr_irq, spsr_fiq;

// ── IF/ID pipeline register ──────────────────────────────────────────────
reg [31:0] ifid_pc;
reg [31:0] ifid_inst;

// ── ID/EX pipeline register ──────────────────────────────────────────────
reg [31:0] idex_pc;
reg [31:0] idex_rfa;        // reg file port A (Rs1 or Rd via use_rd_src)
reg [31:0] idex_rfb;        // reg file port B (Rs2 or rd_field for STR)
reg [31:0] idex_imm32;      // sign-extended imm16
reg [3:0]  idex_rd_addr;    // inst[23:20]
reg [2:0]  idex_fmt;        // inst[31:29] - needed to select STR write data
// Branch / jump immediates
reg [3:0]  idex_br_cond;
reg [24:0] idex_br_imm25;
reg [19:0] idex_bl_imm20;
// Decoded control signals
reg        idex_use_imm;
reg        idex_reg_write;
reg        idex_mem_read;
reg        idex_mem_write;
reg [1:0]  idex_wb_sel;
reg        idex_branch;
reg        idex_bl_op;
reg        idex_bx_op;
reg        idex_push_op;
reg        idex_pop_op;
reg        idex_reti_op;
reg        idex_cmp_tst_op;
reg [3:0]  idex_alu_op;

// ── EX/MEM pipeline register ─────────────────────────────────────────────
reg [31:0] exmem_pc;
reg [31:0] exmem_alu_result;
reg [31:0] exmem_mem_addr;   // effective address (LDR/STR/PUSH/POP)
reg [31:0] exmem_mem_wdata;  // write data (STR/PUSH)
reg [3:0]  exmem_rd_addr;
reg        exmem_reg_write;
reg        exmem_mem_read;
reg        exmem_mem_write;
reg [1:0]  exmem_wb_sel;
reg [31:0] exmem_pc4;
reg        exmem_push_op;
reg        exmem_pop_op;
reg [31:0] exmem_sp_next;   // new SP computed from current sp in EX
reg        exmem_sp_we;
// Branch / jump resolution
reg        exmem_branch;
reg        exmem_bl_op;
reg        exmem_bx_op;
reg        exmem_reti_op;
reg        exmem_cond_pass;
reg [31:0] exmem_branch_target;
reg [31:0] exmem_bl_target;
reg [31:0] exmem_rfa;        // for BX: the jump-register value
// Flag update
reg        exmem_update_flags;
reg [3:0]  exmem_sr_flags;   // {V,C,N,Z}

// ── MEM/WB pipeline register ─────────────────────────────────────────────
reg [31:0] memwb_pc;
reg [31:0] memwb_mem_rdata;  // DMEM async read captured at end of MEM
reg [31:0] memwb_alu_result;
reg [31:0] memwb_pc4;
reg [3:0]  memwb_rd_addr;
reg        memwb_reg_write;
reg [1:0]  memwb_wb_sel;
reg [31:0] memwb_sp_next;
reg        memwb_sp_we;
reg        memwb_branch;
reg        memwb_bl_op;
reg        memwb_bx_op;
reg        memwb_reti_op;
reg        memwb_cond_pass;
reg [31:0] memwb_branch_target;
reg [31:0] memwb_bl_target;
reg [31:0] memwb_rfa;
reg        memwb_update_flags;
reg [3:0]  memwb_sr_flags;

// ────────────────────────────────────────────────────────────────────────
// Instruction Memory — async read driven by pc; APB write port
// ────────────────────────────────────────────────────────────────────────
wire [31:0] imem_inst;

inst_mem u_imem (
    .pclk    (pclk),    .prst_n  (prst_n),
    .cpu_addr(pc),      .cpu_inst(imem_inst),
    .paddr   (paddr),   .psel    (psel),    .penable(penable),
    .pwrite  (pwrite),  .pwdata  (pwdata),
    .prdata  (prdata),  .pready  (pready),  .pslverr(pslverr)
);

// ────────────────────────────────────────────────────────────────────────
// Control decoder — combinationally decodes ifid_inst (outputs used in ID)
// ────────────────────────────────────────────────────────────────────────
wire [2:0]  d_fmt      = ifid_inst[`FMT_MSB:`FMT_LSB];
wire [4:0]  d_funct    = ifid_inst[`FT_MSB:`FT_LSB];
wire [3:0]  d_rd_addr  = ifid_inst[`RD_MSB:`RD_LSB];
wire [3:0]  d_rs1_addr = ifid_inst[`RS1_MSB:`RS1_LSB];
wire [3:0]  d_rs2_addr = ifid_inst[`RS2_MSB:`RS2_LSB];
wire [15:0] d_imm16    = ifid_inst[`IMM16_MSB:`IMM16_LSB];
wire [3:0]  d_br_cond  = ifid_inst[`BR_COND_MSB:`BR_COND_LSB];
wire [24:0] d_br_imm25 = ifid_inst[`BR_IMM25_MSB:`BR_IMM25_LSB];
wire [19:0] d_bl_imm20 = ifid_inst[`BL_IMM20_MSB:`BL_IMM20_LSB];

wire        d_use_imm, d_use_rd_src, d_reg_write, d_mem_read, d_mem_write;
wire [1:0]  d_wb_sel;
wire        d_branch, d_bl_op, d_bx_op, d_push_op, d_pop_op;
wire        d_reti_op, d_cmp_tst_op;
wire [3:0]  d_alu_op;

control u_ctrl (
    .fmt       (d_fmt),       .funct     (d_funct),
    .use_imm   (d_use_imm),   .use_rd_src(d_use_rd_src),
    .reg_write (d_reg_write), .mem_read  (d_mem_read),
    .mem_write (d_mem_write), .wb_sel    (d_wb_sel),
    .branch    (d_branch),    .bl_op     (d_bl_op),
    .bx_op     (d_bx_op),    .push_op   (d_push_op),
    .pop_op    (d_pop_op),    .reti_op   (d_reti_op),
    .cmp_tst_op(d_cmp_tst_op),.alu_op   (d_alu_op)
);

// ────────────────────────────────────────────────────────────────────────
// Register file — async read driven by ifid_inst fields (used in ID)
// Port A: Rs1 normally; Rd for UNARY/BX (use_rd_src)
// Port B: Rs2 normally; Rd field for FMT_STORE (to carry store-source data)
// Write: gated to WB stage (stage==4) via rf_we
// ────────────────────────────────────────────────────────────────────────
wire [3:0]  d_rfa_addr = d_use_rd_src ? d_rd_addr : d_rs1_addr;
wire [3:0]  d_rfb_addr = (d_fmt == `FMT_STORE) ? d_rd_addr : d_rs2_addr;
wire [31:0] d_rfa_data, d_rfb_data;

wire        rf_we;
wire [3:0]  rf_wr_addr;
wire [31:0] rf_wr_data;

reg_file u_rf (
    .clk      (clk),        .rst_n    (rst_n),
    .wr_addr  (rf_wr_addr), .wr_data  (rf_wr_data), .wr_en(rf_we),
    .rd_addr_a(d_rfa_addr), .rd_data_a(d_rfa_data),
    .rd_addr_b(d_rfb_addr), .rd_data_b(d_rfb_data)
);

// ────────────────────────────────────────────────────────────────────────
// ALU — driven by ID/EX register (valid / used in EX stage)
// ────────────────────────────────────────────────────────────────────────
wire [31:0] ex_alu_b = idex_use_imm ? idex_imm32 : idex_rfb;
wire [31:0] alu_result;
wire        alu_Z, alu_N, alu_C, alu_V, alu_flags_we;

alu u_alu (
    .alu_op  (idex_alu_op), .a(idex_rfa),    .b(ex_alu_b),
    .result  (alu_result),  .alu_Z(alu_Z),   .alu_N(alu_N),
    .alu_C   (alu_C),       .alu_V(alu_V),   .flags_we(alu_flags_we)
);

// ────────────────────────────────────────────────────────────────────────
// Condition check — driven by ID/EX register and current SR (used in EX)
// SR is always current: previous instruction completed WB before this IF.
// ────────────────────────────────────────────────────────────────────────
wire ex_cond_pass;
cond_check u_cond (
    .cond(idex_br_cond),
    .Z(sr[`SR_Z]), .N(sr[`SR_N]), .C(sr[`SR_C]), .V(sr[`SR_V]),
    .pass(ex_cond_pass)
);

// EX-stage combinational values (latched into EX/MEM register at end of EX)
wire [31:0] ex_pc4           = idex_pc + 32'd4;
wire [31:0] ex_branch_target = idex_pc + {{5{idex_br_imm25[24]}},  idex_br_imm25,  2'b00};
wire [31:0] ex_bl_target     = idex_pc + {{10{idex_bl_imm20[19]}}, idex_bl_imm20,  2'b00};

// Memory address: PUSH uses sp-4, POP uses sp, otherwise ALU result
wire [31:0] ex_mem_addr  = idex_push_op ? (sp - 32'd4) :
                           idex_pop_op  ? sp            :
                           alu_result;

// Write data: STR source is rfb (rd_field mapped to port B); PUSH source is rfa (Rd)
wire [31:0] ex_mem_wdata = (idex_fmt == `FMT_STORE) ? idex_rfb : idex_rfa;

// SP update: computed from current sp in EX (no overlap, sp is always current)
wire [31:0] ex_sp_next = idex_push_op ? (sp - 32'd4) : (sp + 32'd4);
wire        ex_sp_we   = idex_push_op | idex_pop_op;

// Flags update: any flag-setting instruction except FMT_BRANCH itself
wire ex_update_flags = alu_flags_we & (idex_fmt != `FMT_BRANCH);

// ────────────────────────────────────────────────────────────────────────
// Data Memory — addr/data from EX/MEM register
// Write enable GATED to MEM stage only (stage==3) to prevent spurious writes
// Async read is always active; result captured into memwb_mem_rdata in MEM
// ────────────────────────────────────────────────────────────────────────
wire [31:0] mem_rdata;
wire        dmem_we = exmem_mem_write & (stage == 3'd3);

data_mem u_dmem (
    .clk  (clk),  .addr(exmem_mem_addr),  .wdata(exmem_mem_wdata),
    .we   (dmem_we),                        .rdata(mem_rdata)
);

// ────────────────────────────────────────────────────────────────────────
// WB: result mux and register file write (gated to WB stage)
// ────────────────────────────────────────────────────────────────────────
wire [31:0] wb_data    = (memwb_wb_sel == `WB_MEM) ? memwb_mem_rdata :
                         (memwb_wb_sel == `WB_PC4) ? memwb_pc4       :
                         memwb_alu_result;

// BL writes PC+4 to R14 regardless of rd_addr field
wire [3:0]  wb_rd_addr = memwb_bl_op ? 4'd14 : memwb_rd_addr;

assign rf_we      = memwb_reg_write & (stage == 3'd4);
assign rf_wr_addr = wb_rd_addr;
assign rf_wr_data = wb_data;

// ────────────────────────────────────────────────────────────────────────
// WB: next-PC computation
// Interrupts evaluated here so they coincide with the architectural PC update.
// Since instructions do not overlap, SR/mode are always current in WB.
// ────────────────────────────────────────────────────────────────────────
wire [31:0] reti_pc = (cpu_mode == `MODE_FIQ) ? lr_fiq : lr_irq;

// Normal (non-interrupt) next PC
wire [31:0] normal_next_pc =
    memwb_reti_op                   ? reti_pc              :
    memwb_bx_op                     ? memwb_rfa            :
    memwb_bl_op                     ? memwb_bl_target       :
    (memwb_branch & memwb_cond_pass)? memwb_branch_target  :
    memwb_pc + 32'd4;

// Interrupts: checked only during WB so the entire instruction completes first
wire fiq_taken = fiq & sr[`SR_F] & (cpu_mode == `MODE_SYS) & (stage == 3'd4);
wire irq_taken = irq & sr[`SR_I] & (cpu_mode == `MODE_SYS) & (stage == 3'd4) & ~fiq_taken;

wire [31:0] next_pc =
    fiq_taken ? `FIQ_VEC :
    irq_taken ? `IRQ_VEC :
    normal_next_pc;

// ────────────────────────────────────────────────────────────────────────
// Stage sequencer
// ────────────────────────────────────────────────────────────────────────
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Architectural registers
        pc       <= 32'd0;
        sp       <= `SP_INIT;
        sr       <= 6'b11_0000;   // F=1 I=1 (both interrupt classes enabled)
        stage    <= 3'd0;
        cpu_mode <= `MODE_SYS;
        lr_irq   <= 32'd0;    lr_fiq   <= 32'd0;
        spsr_irq <= 6'd0;     spsr_fiq <= 6'd0;
        // IF/ID
        ifid_pc   <= 32'd0;   ifid_inst <= 32'd0;
        // ID/EX
        idex_pc        <= 32'd0;
        idex_rfa       <= 32'd0;   idex_rfb      <= 32'd0;
        idex_imm32     <= 32'd0;   idex_rd_addr  <= 4'd0;
        idex_fmt       <= 3'd0;
        idex_br_cond   <= 4'd0;    idex_br_imm25 <= 25'd0;
        idex_bl_imm20  <= 20'd0;
        idex_use_imm   <= 1'b0;    idex_reg_write  <= 1'b0;
        idex_mem_read  <= 1'b0;    idex_mem_write  <= 1'b0;
        idex_wb_sel    <= 2'd0;
        idex_branch    <= 1'b0;    idex_bl_op    <= 1'b0;
        idex_bx_op     <= 1'b0;    idex_push_op  <= 1'b0;
        idex_pop_op    <= 1'b0;    idex_reti_op  <= 1'b0;
        idex_cmp_tst_op<= 1'b0;   idex_alu_op   <= 4'd0;
        // EX/MEM
        exmem_pc           <= 32'd0;
        exmem_alu_result   <= 32'd0;   exmem_mem_addr  <= 32'd0;
        exmem_mem_wdata    <= 32'd0;   exmem_rd_addr   <= 4'd0;
        exmem_reg_write    <= 1'b0;    exmem_mem_read  <= 1'b0;
        exmem_mem_write    <= 1'b0;    exmem_wb_sel    <= 2'd0;
        exmem_pc4          <= 32'd0;
        exmem_push_op      <= 1'b0;    exmem_pop_op    <= 1'b0;
        exmem_sp_next      <= 32'd0;   exmem_sp_we     <= 1'b0;
        exmem_branch       <= 1'b0;    exmem_bl_op     <= 1'b0;
        exmem_bx_op        <= 1'b0;    exmem_reti_op   <= 1'b0;
        exmem_cond_pass    <= 1'b0;
        exmem_branch_target<= 32'd0;   exmem_bl_target <= 32'd0;
        exmem_rfa          <= 32'd0;
        exmem_update_flags <= 1'b0;    exmem_sr_flags  <= 4'd0;
        // MEM/WB
        memwb_pc           <= 32'd0;
        memwb_mem_rdata    <= 32'd0;   memwb_alu_result<= 32'd0;
        memwb_pc4          <= 32'd0;   memwb_rd_addr   <= 4'd0;
        memwb_reg_write    <= 1'b0;    memwb_wb_sel    <= 2'd0;
        memwb_sp_next      <= 32'd0;   memwb_sp_we     <= 1'b0;
        memwb_branch       <= 1'b0;    memwb_bl_op     <= 1'b0;
        memwb_bx_op        <= 1'b0;    memwb_reti_op   <= 1'b0;
        memwb_cond_pass    <= 1'b0;
        memwb_branch_target<= 32'd0;   memwb_bl_target <= 32'd0;
        memwb_rfa          <= 32'd0;
        memwb_update_flags <= 1'b0;    memwb_sr_flags  <= 4'd0;
    end else begin
        case (stage)

        // ── Stage 0: IF — fetch instruction from IMEM ────────────────
        3'd0: begin
            ifid_inst <= imem_inst;   // IMEM async read of current pc
            ifid_pc   <= pc;
            stage     <= 3'd1;
        end

        // ── Stage 1: ID — decode and read register file ───────────────
        3'd1: begin
            idex_pc         <= ifid_pc;
            idex_rfa        <= d_rfa_data;
            idex_rfb        <= d_rfb_data;
            idex_imm32      <= {{16{d_imm16[15]}}, d_imm16};
            idex_rd_addr    <= d_rd_addr;
            idex_fmt        <= d_fmt;
            idex_br_cond    <= d_br_cond;
            idex_br_imm25   <= d_br_imm25;
            idex_bl_imm20   <= d_bl_imm20;
            idex_use_imm    <= d_use_imm;
            idex_reg_write  <= d_reg_write;
            idex_mem_read   <= d_mem_read;
            idex_mem_write  <= d_mem_write;
            idex_wb_sel     <= d_wb_sel;
            idex_branch     <= d_branch;
            idex_bl_op      <= d_bl_op;
            idex_bx_op      <= d_bx_op;
            idex_push_op    <= d_push_op;
            idex_pop_op     <= d_pop_op;
            idex_reti_op    <= d_reti_op;
            idex_cmp_tst_op <= d_cmp_tst_op;
            idex_alu_op     <= d_alu_op;
            stage           <= 3'd2;
        end

        // ── Stage 2: EX — ALU, branch targets, condition check ────────
        3'd2: begin
            exmem_pc            <= idex_pc;
            exmem_alu_result    <= alu_result;
            exmem_mem_addr      <= ex_mem_addr;
            exmem_mem_wdata     <= ex_mem_wdata;
            exmem_rd_addr       <= idex_rd_addr;
            exmem_reg_write     <= idex_reg_write & ~idex_cmp_tst_op;
            exmem_mem_read      <= idex_mem_read;
            exmem_mem_write     <= idex_mem_write;
            exmem_wb_sel        <= idex_wb_sel;
            exmem_pc4           <= ex_pc4;
            exmem_push_op       <= idex_push_op;
            exmem_pop_op        <= idex_pop_op;
            exmem_sp_next       <= ex_sp_next;
            exmem_sp_we         <= ex_sp_we;
            exmem_branch        <= idex_branch;
            exmem_bl_op         <= idex_bl_op;
            exmem_bx_op         <= idex_bx_op;
            exmem_reti_op       <= idex_reti_op;
            exmem_cond_pass     <= ex_cond_pass;
            exmem_branch_target <= ex_branch_target;
            exmem_bl_target     <= ex_bl_target;
            exmem_rfa           <= idex_rfa;
            exmem_update_flags  <= ex_update_flags;
            exmem_sr_flags      <= {alu_V, alu_C, alu_N, alu_Z};
            stage               <= 3'd3;
        end

        // ── Stage 3: MEM — data memory access ────────────────────────
        // dmem_we is asserted combinationally (stage==3 & exmem_mem_write).
        // The write fires at this posedge clk. Async rdata is valid now.
        3'd3: begin
            memwb_pc            <= exmem_pc;
            memwb_mem_rdata     <= mem_rdata;     // async read of exmem_mem_addr
            memwb_alu_result    <= exmem_alu_result;
            memwb_pc4           <= exmem_pc4;
            memwb_rd_addr       <= exmem_rd_addr;
            memwb_reg_write     <= exmem_reg_write;
            memwb_wb_sel        <= exmem_wb_sel;
            memwb_sp_next       <= exmem_sp_next;
            memwb_sp_we         <= exmem_sp_we;
            memwb_branch        <= exmem_branch;
            memwb_bl_op         <= exmem_bl_op;
            memwb_bx_op         <= exmem_bx_op;
            memwb_reti_op       <= exmem_reti_op;
            memwb_cond_pass     <= exmem_cond_pass;
            memwb_branch_target <= exmem_branch_target;
            memwb_bl_target     <= exmem_bl_target;
            memwb_rfa           <= exmem_rfa;
            memwb_update_flags  <= exmem_update_flags;
            memwb_sr_flags      <= exmem_sr_flags;
            stage               <= 3'd4;
        end

        // ── Stage 4: WB — write back; update pc / sp / sr ─────────────
        // rf_we is asserted combinationally (stage==4 & memwb_reg_write).
        // The register file write fires at this posedge clk.
        3'd4: begin
            pc <= next_pc;

            if (memwb_sp_we)
                sp <= memwb_sp_next;

            if (memwb_update_flags)
                sr[3:0] <= memwb_sr_flags;   // {V,C,N,Z}

            // RETI: restore saved SR and return to SYS mode
            if (memwb_reti_op) begin
                case (cpu_mode)
                    `MODE_FIQ: begin sr <= spsr_fiq; cpu_mode <= `MODE_SYS; end
                    `MODE_IRQ: begin sr <= spsr_irq; cpu_mode <= `MODE_SYS; end
                    default: ;
                endcase
            end

            // Interrupt entry (after instruction retires cleanly)
            if (fiq_taken) begin
                lr_fiq    <= normal_next_pc;  // save where we would have gone
                spsr_fiq  <= sr;
                sr[`SR_F] <= 1'b0;
                sr[`SR_I] <= 1'b0;
                cpu_mode  <= `MODE_FIQ;
            end else if (irq_taken) begin
                lr_irq    <= normal_next_pc;
                spsr_irq  <= sr;
                sr[`SR_I] <= 1'b0;
                cpu_mode  <= `MODE_IRQ;
            end

            stage <= 3'd0;
        end

        default: stage <= 3'd0;
        endcase
    end
end

endmodule
