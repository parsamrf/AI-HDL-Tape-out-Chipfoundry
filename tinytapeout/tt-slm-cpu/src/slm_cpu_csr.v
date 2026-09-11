/*
 * slm_cpu_csr — M-mode CSR file with trap / interrupt entry and return.
 *
 * Implements: mstatus (MIE, MPIE; MPP reads 2'b11), mie (MSIE/MTIE/MEIE),
 * mip (read-only, from irq inputs), mtvec (direct mode, [1:0] read 0),
 * mepc, mcause, mscratch, mhartid (0), misa (RV32IM = 0x4000_1100),
 * mcycle/mcycleh (free-running, writable), minstret/minstreth (retired
 * instruction count, writable). Reads of unimplemented CSRs return 0 and
 * writes to them are ignored (no illegal-CSR trap — see sign-off caveats).
 *
 * Trap entry (trap_en): mepc <= trap_pc, mcause <= trap_cause,
 * MPIE <= MIE, MIE <= 0. Return (mret_en): MIE <= MPIE, MPIE <= 1.
 * irq_take_req = mstatus.MIE && (mip & mie) != 0, external over timer.
 * wfi_wake = (mip & mie) != 0 regardless of mstatus.MIE.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.3.
 */
`default_nettype none

module slm_cpu_csr (
  input  wire        clk,           // clock
  input  wire        rst_n,         // synchronous active-low reset
  // CSR instruction access (EX stage, retiring this cycle)
  input  wire        csr_en,        // CSR instruction executes this cycle
  input  wire [11:0] csr_addr,      // CSR address
  input  wire [1:0]  csr_op,        // funct3[1:0]: 1 RW, 2 RS, 3 RC
  input  wire        csr_wen,       // write side actually performed
  input  wire [31:0] csr_wdata,     // rs1 value or zero-extended zimm
  output wire [31:0] csr_rdata,     // read value (old CSR value)
  // retirement / trap control
  input  wire        instr_ret,     // one instruction retires this cycle
  input  wire        trap_en,       // take trap (exception or interrupt)
  input  wire [31:0] trap_cause,    // mcause value
  input  wire [31:0] trap_pc,       // PC saved into mepc
  input  wire        mret_en,       // execute MRET this cycle
  // interrupt lines (level)
  input  wire        irq_timer,     // -> mip.MTIP
  input  wire        irq_external,  // -> mip.MEIP
  // pipeline-facing status
  output wire [31:0] tvec_pc,       // trap vector (mtvec, direct)
  output wire [31:0] mepc_pc,       // mepc for MRET
  output wire        irq_take_req,  // enabled+pending irq, MIE gated
  output wire [31:0] irq_cause,     // cause of highest-priority pending irq
  output wire        wfi_wake      // (mip & mie) != 0, ignores mstatus.MIE
);

  localparam [11:0] A_MSTATUS  = 12'h300;
  localparam [11:0] A_MISA     = 12'h301;
  localparam [11:0] A_MIE      = 12'h304;
  localparam [11:0] A_MTVEC    = 12'h305;
  localparam [11:0] A_MSCRATCH = 12'h340;
  localparam [11:0] A_MEPC     = 12'h341;
  localparam [11:0] A_MCAUSE   = 12'h342;
  localparam [11:0] A_MIP      = 12'h344;
  localparam [11:0] A_MCYCLE   = 12'hB00;
  localparam [11:0] A_MINSTRET = 12'hB02;
  localparam [11:0] A_MCYCLEH  = 12'hB80;
  localparam [11:0] A_MINSTRH  = 12'hB82;
  localparam [11:0] A_MHARTID  = 12'hF14;

  reg        mstatus_mie;
  reg        mstatus_mpie;
  reg        mie_msie;
  reg        mie_mtie;
  reg        mie_meie;
  reg [31:0] mtvec;
  reg [31:0] mepc;
  reg [31:0] mcause;
  reg [31:0] mscratch;
  reg [63:0] mcycle;
  reg [63:0] minstret;

  wire [31:0] mip_val = {20'b0, irq_external, 3'b0, irq_timer, 7'b0};
  wire [31:0] mie_val = {20'b0, mie_meie, 3'b0, mie_mtie, 3'b0, mie_msie, 3'b0};
  wire [31:0] mstatus_val = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0,
                             mstatus_mie, 3'b0};

  // Read mux (old value, before any write this cycle).
  reg [31:0] rdata;
  always @(*) begin
    case (csr_addr)
      A_MSTATUS:  rdata = mstatus_val;
      A_MISA:     rdata = 32'h4000_1100;
      A_MIE:      rdata = mie_val;
      A_MTVEC:    rdata = mtvec;
      A_MSCRATCH: rdata = mscratch;
      A_MEPC:     rdata = mepc;
      A_MCAUSE:   rdata = mcause;
      A_MIP:      rdata = mip_val;
      A_MCYCLE:   rdata = mcycle[31:0];
      A_MINSTRET: rdata = minstret[31:0];
      A_MCYCLEH:  rdata = mcycle[63:32];
      A_MINSTRH:  rdata = minstret[63:32];
      A_MHARTID:  rdata = 32'b0;
      default:    rdata = 32'b0;
    endcase
  end
  assign csr_rdata = rdata;

  // Write value after RW/RS/RC modification.
  reg [31:0] wval;
  always @(*) begin
    case (csr_op)
      2'b01:   wval = csr_wdata;           // CSRRW
      2'b10:   wval = rdata | csr_wdata;   // CSRRS
      default: wval = rdata & ~csr_wdata;  // CSRRC
    endcase
  end

  wire do_write = csr_en && csr_wen;

  always @(posedge clk) begin
    if (!rst_n) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie_msie     <= 1'b0;
      mie_mtie     <= 1'b0;
      mie_meie     <= 1'b0;
      mtvec        <= 32'b0;
      mepc         <= 32'b0;
      mcause       <= 32'b0;
      mscratch     <= 32'b0;
      mcycle       <= 64'b0;
      minstret     <= 64'b0;
    end else begin
      // Free-running / retirement counters (CSR writes override below).
      mcycle   <= mcycle + 64'd1;
      minstret <= minstret + {63'b0, instr_ret};

      if (do_write) begin
        case (csr_addr)
          A_MSTATUS: begin
            mstatus_mie  <= wval[3];
            mstatus_mpie <= wval[7];
          end
          A_MIE: begin
            mie_msie <= wval[3];
            mie_mtie <= wval[7];
            mie_meie <= wval[11];
          end
          A_MTVEC:    mtvec    <= {wval[31:2], 2'b00};
          A_MSCRATCH: mscratch <= wval;
          A_MEPC:     mepc     <= {wval[31:1], 1'b0};
          A_MCAUSE:   mcause   <= wval;
          A_MCYCLE:   mcycle   <= {mcycle[63:32], wval};
          A_MINSTRET: minstret <= {minstret[63:32], wval};
          A_MCYCLEH:  mcycle   <= {wval, mcycle[31:0]};
          A_MINSTRH:  minstret <= {wval, minstret[31:0]};
          default: begin end // mip/misa/mhartid/unknown: ignore
        endcase
      end

      // Trap entry / return take priority over instruction writes.
      if (trap_en) begin
        mepc         <= {trap_pc[31:1], 1'b0};
        mcause       <= trap_cause;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
      end else if (mret_en) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
      end
    end
  end

  wire pend_ext = irq_external & mie_meie;
  wire pend_tim = irq_timer & mie_mtie;

  assign tvec_pc      = {mtvec[31:2], 2'b00};
  assign mepc_pc      = {mepc[31:1], 1'b0};
  assign wfi_wake     = pend_ext | pend_tim;
  assign irq_take_req = mstatus_mie & (pend_ext | pend_tim);
  assign irq_cause    = pend_ext ? 32'h8000_000B : 32'h8000_0007;

  wire _unused = &{1'b0, trap_pc[0]};

endmodule

`default_nettype wire
