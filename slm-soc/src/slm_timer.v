/*
 * slm_timer — CLINT-lite 64-bit machine timer, SLB CSR slave.
 *
 * mtime is a 64-bit counter free-running from reset; mtimecmp resets to
 * all-ones so no interrupt fires until firmware programs it.
 * Register map (window-relative, see docs/SPEC.md section 6.7):
 *   0x00 MTIME_LO    (R)
 *   0x04 MTIME_HI    (R)
 *   0x08 MTIMECMP_LO (RW, byte strobes honored)
 *   0x0C MTIMECMP_HI (RW, byte strobes honored)
 * mtip = (mtime >= mtimecmp), cleared by rewriting mtimecmp above mtime.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.7.
 */
`default_nettype none

module slm_timer (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  // SLB CSR slave port
  input  wire        s_req_valid,  // request valid
  output wire        s_req_ready,  // always ready
  input  wire        s_req_write,  // 1 = write, 0 = read
  input  wire [15:0] s_req_addr,   // window-relative byte address
  input  wire [31:0] s_req_wdata,  // write data
  input  wire [3:0]  s_req_wstrb,  // byte strobes
  output reg         s_rsp_valid,  // response pulse
  output reg  [31:0] s_rsp_rdata,  // read data
  // interrupt
  output wire        mtip          // level: mtime >= mtimecmp
);

  // register word offsets (s_req_addr[15:2])
  localparam [13:0] A_MTIME_LO    = 14'd0;
  localparam [13:0] A_MTIME_HI    = 14'd1;
  localparam [13:0] A_MTIMECMP_LO = 14'd2;
  localparam [13:0] A_MTIMECMP_HI = 14'd3;

  reg [63:0] mtime_q;
  reg [63:0] mtimecmp_q;

  assign s_req_ready = 1'b1;
  assign mtip        = (mtime_q >= mtimecmp_q);

  wire [13:0] csr_word = s_req_addr[15:2];
  wire        csr_wr   = s_req_valid & s_req_write;

  // read data mux
  reg [31:0] rd_mux;
  always @* begin
    case (csr_word)
      A_MTIME_LO:    rd_mux = mtime_q[31:0];
      A_MTIME_HI:    rd_mux = mtime_q[63:32];
      A_MTIMECMP_LO: rd_mux = mtimecmp_q[31:0];
      A_MTIMECMP_HI: rd_mux = mtimecmp_q[63:32];
      default:       rd_mux = 32'h0000_0000;
    endcase
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      s_rsp_valid <= 1'b0;
      s_rsp_rdata <= 32'h0000_0000;
      mtime_q     <= 64'd0;
      mtimecmp_q  <= {64{1'b1}};
    end else begin
      s_rsp_valid <= s_req_valid;
      s_rsp_rdata <= rd_mux;

      mtime_q <= mtime_q + 64'd1;

      if (csr_wr && csr_word == A_MTIMECMP_LO) begin
        if (s_req_wstrb[0]) mtimecmp_q[7:0]   <= s_req_wdata[7:0];
        if (s_req_wstrb[1]) mtimecmp_q[15:8]  <= s_req_wdata[15:8];
        if (s_req_wstrb[2]) mtimecmp_q[23:16] <= s_req_wdata[23:16];
        if (s_req_wstrb[3]) mtimecmp_q[31:24] <= s_req_wdata[31:24];
      end
      if (csr_wr && csr_word == A_MTIMECMP_HI) begin
        if (s_req_wstrb[0]) mtimecmp_q[39:32] <= s_req_wdata[7:0];
        if (s_req_wstrb[1]) mtimecmp_q[47:40] <= s_req_wdata[15:8];
        if (s_req_wstrb[2]) mtimecmp_q[55:48] <= s_req_wdata[23:16];
        if (s_req_wstrb[3]) mtimecmp_q[63:56] <= s_req_wdata[31:24];
      end
    end
  end

  wire _unused = &{1'b0, s_req_addr[1:0]};

endmodule

`default_nettype wire
