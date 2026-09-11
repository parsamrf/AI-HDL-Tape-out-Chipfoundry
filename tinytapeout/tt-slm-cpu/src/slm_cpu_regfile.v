/*
 * slm_cpu_regfile — 32 x 32-bit register file, 2 read / 1 write.
 *
 * x0 is hardwired to zero (writes to x0 are dropped, reads return 0).
 * Combinational reads with same-cycle write bypass so that a value being
 * written back in WB is visible to a decode-stage read in the same cycle.
 * All registers are synchronously cleared on reset to keep simulation X-free.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.3.
 */
`default_nettype none

module slm_cpu_regfile (
  input  wire        clk,      // clock
  input  wire        rst_n,    // synchronous active-low reset
  input  wire        we,       // write enable (WB stage)
  input  wire [4:0]  waddr,    // write register index
  input  wire [31:0] wdata,    // write data
  input  wire [4:0]  raddr1,   // read port 1 index (rs1)
  input  wire [4:0]  raddr2,   // read port 2 index (rs2)
  output wire [31:0] rdata1,   // read port 1 data
  output wire [31:0] rdata2   // read port 2 data
);

  reg [31:0] regs [0:31];
  integer i;

  always @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < 32; i = i + 1)
        regs[i] <= 32'b0;
    end else if (we && (waddr != 5'd0)) begin
      regs[waddr] <= wdata;
    end
  end

  wire wr_act = we && (waddr != 5'd0);

  assign rdata1 = (raddr1 == 5'd0)             ? 32'b0 :
                  (wr_act && (waddr == raddr1)) ? wdata :
                                                  regs[raddr1];

  assign rdata2 = (raddr2 == 5'd0)             ? 32'b0 :
                  (wr_act && (waddr == raddr2)) ? wdata :
                                                  regs[raddr2];

endmodule

`default_nettype wire
