/*
 * slm_cpu_top — RV32IM + Zicsr 5-stage pipeline (IF/ID/EX/MEM/WB).
 *
 * Pipeline glue: hazard detection, forwarding, and flush control around
 * slm_cpu_ifu / decode / regfile / alu / muldiv / csr / lsu.
 *
 *  - Full forwarding MEM->EX and WB->EX; regfile read has a same-cycle
 *    WB write bypass, so all RAW distances are covered.
 *  - 1-bubble load-use interlock; the MEM-stage bus stall then holds EX
 *    until the load data is registered and forwardable.
 *  - Branches/jumps resolve in EX; taken -> flush IF/ID (2-cycle penalty).
 *  - M-extension ops run on the shared iterative unit and stall EX.
 *  - Exceptions (illegal = 2, ecall = 11, ebreak = 3) commit in EX;
 *    interrupts are taken at an instruction boundary when
 *    mstatus.MIE && (mip & mie) != 0, external before timer; mepc is the
 *    next unexecuted PC. WFI stalls in EX until (mip & mie) != 0
 *    (regardless of mstatus.MIE), then retires; a pending enabled
 *    interrupt is then taken on the following instruction.
 *  - fence / fence.i execute as NOPs.
 *
 * Sign-off caveats: misaligned data accesses do not trap (firmware avoids
 * them); unimplemented CSR addresses read 0 / ignore writes rather than
 * trapping.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.3.
 */
`default_nettype none

module slm_cpu_top #(
  parameter RESET_PC = 32'h0000_0000
) (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  // instruction fetch: private synchronous-read port (1-cycle, always ready)
  output wire [31:0] if_addr,      // word-aligned fetch address
  input  wire [31:0] if_rdata,     // instruction at if_addr, valid next cycle
  // data port: SLB master
  output wire        d_req_valid,  // request valid
  input  wire        d_req_ready,  // slave accepts request
  output wire        d_req_write,  // 1 = write
  output wire [31:0] d_req_addr,   // byte address
  output wire [31:0] d_req_wdata,  // write data
  output wire [3:0]  d_req_wstrb,  // byte strobes
  input  wire        d_rsp_valid,  // single response pulse
  input  wire [31:0] d_rsp_rdata,  // read data
  // interrupts (level)
  input  wire        irq_timer,    // -> mip.MTIP
  input  wire        irq_external  // -> mip.MEIP
);

  // ---------------------------------------------------------------- IF --
  wire        stall_if;
  wire        redirect;
  wire [31:0] redirect_pc;
  wire [31:0] id_pc;
  wire        id_valid;
  wire [31:0] fetch_pc;

  slm_cpu_ifu #(
    .RESET_PC(RESET_PC)
  ) u_ifu (
    .clk         (clk),
    .rst_n       (rst_n),
    .stall       (stall_if),
    .redirect    (redirect),
    .redirect_pc (redirect_pc),
    .if_addr     (if_addr),
    .fetch_pc    (fetch_pc),
    .id_pc       (id_pc),
    .id_valid    (id_valid)
  );

  // ---------------------------------------------------------------- ID --
  wire [4:0]  dec_rs1, dec_rs2, dec_rd;
  wire [2:0]  dec_funct3;
  wire [31:0] dec_imm;
  wire [3:0]  dec_alu_op;
  wire        dec_alu_a_pc, dec_alu_b_imm;
  wire        dec_is_lui, dec_is_jal, dec_is_jalr, dec_is_branch;
  wire        dec_is_load, dec_is_store, dec_is_muldiv, dec_is_csr;
  wire        dec_csr_use_imm, dec_csr_wen;
  wire        dec_is_ecall, dec_is_ebreak, dec_is_mret, dec_is_wfi;
  wire        dec_writes_rd, dec_uses_rs1, dec_uses_rs2, dec_illegal;

  slm_cpu_decode u_dec (
    .instr       (if_rdata),
    .rs1         (dec_rs1),
    .rs2         (dec_rs2),
    .rd          (dec_rd),
    .funct3      (dec_funct3),
    .imm         (dec_imm),
    .alu_op      (dec_alu_op),
    .alu_a_pc    (dec_alu_a_pc),
    .alu_b_imm   (dec_alu_b_imm),
    .is_lui      (dec_is_lui),
    .is_jal      (dec_is_jal),
    .is_jalr     (dec_is_jalr),
    .is_branch   (dec_is_branch),
    .is_load     (dec_is_load),
    .is_store    (dec_is_store),
    .is_muldiv   (dec_is_muldiv),
    .is_csr      (dec_is_csr),
    .csr_use_imm (dec_csr_use_imm),
    .csr_wen     (dec_csr_wen),
    .is_ecall    (dec_is_ecall),
    .is_ebreak   (dec_is_ebreak),
    .is_mret     (dec_is_mret),
    .is_wfi      (dec_is_wfi),
    .writes_rd   (dec_writes_rd),
    .uses_rs1    (dec_uses_rs1),
    .uses_rs2    (dec_uses_rs2),
    .illegal     (dec_illegal)
  );

  wire        rf_we;
  wire [4:0]  rf_waddr;
  wire [31:0] rf_wdata;
  wire [31:0] rf_rdata1, rf_rdata2;

  slm_cpu_regfile u_rf (
    .clk    (clk),
    .rst_n  (rst_n),
    .we     (rf_we),
    .waddr  (rf_waddr),
    .wdata  (rf_wdata),
    .raddr1 (dec_rs1),
    .raddr2 (dec_rs2),
    .rdata1 (rf_rdata1),
    .rdata2 (rf_rdata2)
  );

  // ------------------------------------------------------ ID/EX register
  reg         ex_valid;
  reg  [31:0] ex_pc;
  reg  [31:0] ex_rs1_val, ex_rs2_val;
  reg  [4:0]  ex_rs1, ex_rs2, ex_rd;
  reg  [31:0] ex_imm;
  reg  [3:0]  ex_alu_op;
  reg         ex_alu_a_pc, ex_alu_b_imm;
  reg  [2:0]  ex_funct3;
  reg         ex_is_lui, ex_is_jal, ex_is_jalr, ex_is_branch;
  reg         ex_is_load, ex_is_store, ex_is_muldiv, ex_is_csr;
  reg         ex_csr_use_imm, ex_csr_wen;
  reg         ex_is_ecall, ex_is_ebreak, ex_is_mret, ex_is_wfi;
  reg         ex_writes_rd, ex_illegal;

  // ----------------------------------------------------- EX/MEM register
  reg         mem_valid;
  reg  [4:0]  mem_rd;
  reg         mem_wen;
  reg  [31:0] mem_result;
  reg         mem_is_load, mem_is_store;
  reg  [2:0]  mem_funct3;
  reg  [31:0] mem_addr;
  reg  [31:0] mem_wdata;

  // ----------------------------------------------------- MEM/WB register
  reg         wb_valid;
  reg  [4:0]  wb_rd;
  reg         wb_wen;
  reg  [31:0] wb_data;

  // ---------------------------------------------------------------- EX --
  // Forwarding: MEM stage first (younger), then WB stage.
  wire        lsu_done;
  wire [31:0] lsu_load_data;
  wire [31:0] mem_fwd_val = mem_is_load ? lsu_load_data : mem_result;

  wire [31:0] fwd_rs1 =
      (mem_valid && mem_wen && (mem_rd == ex_rs1)) ? mem_fwd_val :
      (wb_valid  && wb_wen  && (wb_rd  == ex_rs1)) ? wb_data     :
                                                     ex_rs1_val;
  wire [31:0] fwd_rs2 =
      (mem_valid && mem_wen && (mem_rd == ex_rs2)) ? mem_fwd_val :
      (wb_valid  && wb_wen  && (wb_rd  == ex_rs2)) ? wb_data     :
                                                     ex_rs2_val;

  wire [31:0] alu_a = ex_alu_a_pc  ? ex_pc  : fwd_rs1;
  wire [31:0] alu_b = ex_alu_b_imm ? ex_imm : fwd_rs2;

  wire [31:0] alu_result;
  wire        alu_eq, alu_lt, alu_ltu;

  slm_cpu_alu u_alu (
    .in_a   (alu_a),
    .in_b   (alu_b),
    .op     (ex_alu_op),
    .result (alu_result),
    .eq     (alu_eq),
    .lt     (alu_lt),
    .ltu    (alu_ltu)
  );

  // Branch condition from comparison flags.
  reg br_cond;
  always @(*) begin
    case (ex_funct3)
      3'b000:  br_cond = alu_eq;    // beq
      3'b001:  br_cond = ~alu_eq;   // bne
      3'b100:  br_cond = alu_lt;    // blt
      3'b101:  br_cond = ~alu_lt;   // bge
      3'b110:  br_cond = alu_ltu;   // bltu
      3'b111:  br_cond = ~alu_ltu;  // bgeu
      default: br_cond = 1'b0;
    endcase
  end

  wire [31:0] br_target   = ex_pc + ex_imm;                 // branch / jal
  wire [31:0] jalr_target = {alu_result[31:1], 1'b0};       // (rs1+imm)&~1

  // --------------------------------------------------------- mul/div ----
  reg  md_run;   // operation started, still in flight
  reg  md_fin;   // result captured, waiting for EX to advance
  wire md_busy, md_done;
  wire [31:0] md_result;
  wire irq_take;

  wire stall_mem;
  wire md_start = ex_valid && ex_is_muldiv && !md_run && !md_fin &&
                  !md_done && !irq_take && !stall_mem;

  slm_cpu_muldiv u_md (
    .clk    (clk),
    .rst_n  (rst_n),
    .start  (md_start),
    .op     (ex_funct3),
    .in_a   (fwd_rs1),
    .in_b   (fwd_rs2),
    .busy   (md_busy),
    .done   (md_done),
    .result (md_result)
  );

  // --------------------------------------------------------- stalls -----
  wire mem_is_memop = mem_is_load || mem_is_store;
  assign stall_mem = mem_valid && mem_is_memop && !lsu_done;

  wire md_wait  = ex_valid && ex_is_muldiv && !md_fin && !md_done;
  wire wfi_wake;
  wire wfi_wait = ex_valid && ex_is_wfi && !wfi_wake;

  wire stall_ex = stall_mem || md_wait || wfi_wait;

  wire loaduse = id_valid && ex_valid && ex_is_load && (ex_rd != 5'd0) &&
                 ((dec_uses_rs1 && (dec_rs1 == ex_rd)) ||
                  (dec_uses_rs2 && (dec_rs2 == ex_rd)));

  wire stall_id = stall_ex || loaduse;
  assign stall_if = stall_id;

  // ------------------------------------------------- traps / interrupts
  wire        irq_take_req;
  wire [31:0] irq_cause;
  wire [31:0] tvec_pc, mepc_pc;
  wire [31:0] csr_rdata;

  // Interrupts wait for: no in-flight memory op, no in-flight muldiv, and
  // never pre-empt a WFI sitting in EX (it retires first, so mepc after a
  // WFI wake is wfi_pc + 4).
  assign irq_take = irq_take_req && !stall_mem && !md_run &&
                    !(ex_valid && ex_is_wfi);

  wire ex_exc = ex_valid && (ex_illegal || ex_is_ecall || ex_is_ebreak);
  wire [31:0] exc_cause = ex_illegal  ? 32'd2 :
                          ex_is_ecall ? 32'd11 : 32'd3;

  wire trap_en = irq_take || (ex_exc && !stall_ex);

  // Next unexecuted PC for interrupt entry.
  wire [31:0] irq_epc = ex_valid ? ex_pc :
                        id_valid ? id_pc : fetch_pc;

  wire [31:0] trap_cause = irq_take ? irq_cause : exc_cause;
  wire [31:0] trap_pc    = irq_take ? irq_epc   : ex_pc;

  wire ex_complete = ex_valid && !stall_ex;

  wire mret_en = ex_complete && ex_is_mret && !irq_take;

  wire branch_taken = ex_complete && !irq_take && !ex_exc &&
                      (ex_is_jal || ex_is_jalr || (ex_is_branch && br_cond));

  assign redirect    = trap_en || mret_en || branch_taken;
  assign redirect_pc = trap_en    ? tvec_pc     :
                       mret_en    ? mepc_pc     :
                       ex_is_jalr ? jalr_target : br_target;

  // ------------------------------------------------------------- CSR ----
  wire csr_en = ex_complete && ex_is_csr && !irq_take;
  wire [31:0] csr_wdata = ex_csr_use_imm ? {27'b0, ex_rs1} : fwd_rs1;

  slm_cpu_csr u_csr (
    .clk          (clk),
    .rst_n        (rst_n),
    .csr_en       (csr_en),
    .csr_addr     (ex_imm[11:0]),
    .csr_op       (ex_funct3[1:0]),
    .csr_wen      (ex_csr_wen),
    .csr_wdata    (csr_wdata),
    .csr_rdata    (csr_rdata),
    .instr_ret    (wb_valid),
    .trap_en      (trap_en),
    .trap_cause   (trap_cause),
    .trap_pc      (trap_pc),
    .mret_en      (mret_en),
    .irq_timer    (irq_timer),
    .irq_external (irq_external),
    .tvec_pc      (tvec_pc),
    .mepc_pc      (mepc_pc),
    .irq_take_req (irq_take_req),
    .irq_cause    (irq_cause),
    .wfi_wake     (wfi_wake)
  );

  // EX result (what reaches rd for non-load instructions).
  wire [31:0] ex_result =
      ex_is_muldiv               ? md_result       :
      ex_is_csr                  ? csr_rdata       :
      (ex_is_jal || ex_is_jalr)  ? (ex_pc + 32'd4) :
      ex_is_lui                  ? ex_imm          :
                                   alu_result;

  // --------------------------------------------------------------- LSU --
  reg lsu_started;
  wire lsu_start = mem_valid && mem_is_memop && !lsu_started;
  wire lsu_busy;

  slm_cpu_lsu u_lsu (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (lsu_start),
    .is_write    (mem_is_store),
    .funct3      (mem_funct3),
    .addr        (mem_addr),
    .wdata       (mem_wdata),
    .busy        (lsu_busy),
    .done        (lsu_done),
    .load_data   (lsu_load_data),
    .d_req_valid (d_req_valid),
    .d_req_ready (d_req_ready),
    .d_req_write (d_req_write),
    .d_req_addr  (d_req_addr),
    .d_req_wdata (d_req_wdata),
    .d_req_wstrb (d_req_wstrb),
    .d_rsp_valid (d_rsp_valid),
    .d_rsp_rdata (d_rsp_rdata)
  );

  always @(posedge clk) begin
    if (!rst_n)
      lsu_started <= 1'b0;
    else if (!stall_mem)
      lsu_started <= 1'b0;
    else if (lsu_start)
      lsu_started <= 1'b1;
  end

  // ------------------------------------------------ muldiv bookkeeping --
  always @(posedge clk) begin
    if (!rst_n) begin
      md_run <= 1'b0;
      md_fin <= 1'b0;
    end else begin
      if (md_start)
        md_run <= 1'b1;
      else if (md_done)
        md_run <= 1'b0;

      if (!stall_ex)
        md_fin <= 1'b0;         // EX advances: consume the result
      else if (md_done)
        md_fin <= 1'b1;         // finished but EX held by a MEM stall
    end
  end

  // --------------------------------------------- pipeline registers -----
  // ID/EX
  always @(posedge clk) begin
    if (!rst_n) begin
      ex_valid       <= 1'b0;
      ex_pc          <= RESET_PC;
      ex_rs1_val     <= 32'b0;
      ex_rs2_val     <= 32'b0;
      ex_rs1         <= 5'b0;
      ex_rs2         <= 5'b0;
      ex_rd          <= 5'b0;
      ex_imm         <= 32'b0;
      ex_alu_op      <= 4'b0;
      ex_alu_a_pc    <= 1'b0;
      ex_alu_b_imm   <= 1'b0;
      ex_funct3      <= 3'b0;
      ex_is_lui      <= 1'b0;
      ex_is_jal      <= 1'b0;
      ex_is_jalr     <= 1'b0;
      ex_is_branch   <= 1'b0;
      ex_is_load     <= 1'b0;
      ex_is_store    <= 1'b0;
      ex_is_muldiv   <= 1'b0;
      ex_is_csr      <= 1'b0;
      ex_csr_use_imm <= 1'b0;
      ex_csr_wen     <= 1'b0;
      ex_is_ecall    <= 1'b0;
      ex_is_ebreak   <= 1'b0;
      ex_is_mret     <= 1'b0;
      ex_is_wfi      <= 1'b0;
      ex_writes_rd   <= 1'b0;
      ex_illegal     <= 1'b0;
    end else if (!stall_ex) begin
      if (id_valid && !loaduse && !redirect) begin
        ex_valid       <= 1'b1;
        ex_pc          <= id_pc;
        ex_rs1_val     <= rf_rdata1;
        ex_rs2_val     <= rf_rdata2;
        ex_rs1         <= dec_rs1;
        ex_rs2         <= dec_rs2;
        ex_rd          <= dec_rd;
        ex_imm         <= dec_imm;
        ex_alu_op      <= dec_alu_op;
        ex_alu_a_pc    <= dec_alu_a_pc;
        ex_alu_b_imm   <= dec_alu_b_imm;
        ex_funct3      <= dec_funct3;
        ex_is_lui      <= dec_is_lui;
        ex_is_jal      <= dec_is_jal;
        ex_is_jalr     <= dec_is_jalr;
        ex_is_branch   <= dec_is_branch;
        ex_is_load     <= dec_is_load;
        ex_is_store    <= dec_is_store;
        ex_is_muldiv   <= dec_is_muldiv;
        ex_is_csr      <= dec_is_csr;
        ex_csr_use_imm <= dec_csr_use_imm;
        ex_csr_wen     <= dec_csr_wen;
        ex_is_ecall    <= dec_is_ecall;
        ex_is_ebreak   <= dec_is_ebreak;
        ex_is_mret     <= dec_is_mret;
        ex_is_wfi      <= dec_is_wfi;
        ex_writes_rd   <= dec_writes_rd;
        ex_illegal     <= dec_illegal;
      end else begin
        ex_valid <= 1'b0;
      end
    end else begin
      // EX stage held. An interrupt can still kill the (not yet started)
      // instruction in EX; and operand copies must stay fresh: a producer
      // draining past WB during the stall writes the regfile and vanishes
      // from the forwarding network, so latch its value here.
      if (redirect)
        ex_valid <= 1'b0;
      if (wb_valid && wb_wen && (wb_rd == ex_rs1))
        ex_rs1_val <= wb_data;
      if (wb_valid && wb_wen && (wb_rd == ex_rs2))
        ex_rs2_val <= wb_data;
    end
  end

  // EX/MEM
  always @(posedge clk) begin
    if (!rst_n) begin
      mem_valid    <= 1'b0;
      mem_rd       <= 5'b0;
      mem_wen      <= 1'b0;
      mem_result   <= 32'b0;
      mem_is_load  <= 1'b0;
      mem_is_store <= 1'b0;
      mem_funct3   <= 3'b0;
      mem_addr     <= 32'b0;
      mem_wdata    <= 32'b0;
    end else if (!stall_mem) begin
      if (ex_complete && !irq_take && !ex_exc) begin
        mem_valid    <= 1'b1;
        mem_rd       <= ex_rd;
        mem_wen      <= ex_writes_rd && (ex_rd != 5'd0);
        mem_result   <= ex_result;
        mem_is_load  <= ex_is_load;
        mem_is_store <= ex_is_store;
        mem_funct3   <= ex_funct3;
        mem_addr     <= alu_result;
        mem_wdata    <= fwd_rs2;
      end else begin
        mem_valid    <= 1'b0;
        mem_wen      <= 1'b0;
        mem_is_load  <= 1'b0;
        mem_is_store <= 1'b0;
      end
    end
  end

  // MEM/WB
  always @(posedge clk) begin
    if (!rst_n) begin
      wb_valid <= 1'b0;
      wb_rd    <= 5'b0;
      wb_wen   <= 1'b0;
      wb_data  <= 32'b0;
    end else if (!stall_mem) begin
      wb_valid <= mem_valid;
      wb_rd    <= mem_rd;
      wb_wen   <= mem_wen;
      wb_data  <= mem_is_load ? lsu_load_data : mem_result;
    end else begin
      wb_valid <= 1'b0;
      wb_wen   <= 1'b0;
    end
  end

  assign rf_we    = wb_valid && wb_wen;
  assign rf_waddr = wb_rd;
  assign rf_wdata = wb_data;

  wire _unused = &{1'b0, md_busy, lsu_busy};

endmodule

`default_nettype wire
