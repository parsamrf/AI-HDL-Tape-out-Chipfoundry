/*
 * slm_dmem — data memory, SLB slave with per-byte write strobes.
 *
 * Single SLB slave port: always ready, response pulses on the cycle after
 * acceptance for both reads and writes. Writes apply the four byte strobes
 * individually (sb/sh/sw). The storage array is named `mem` (testbenches
 * preload/inspect data via hierarchical references) and is zero-initialized
 * in an initial block (synthesis-benign for behavioral RAM; keeps
 * simulation X-free). Word-addressed: byte address bits [1:0] are ignored
 * and addresses beyond WORDS alias (the xbar decode guarantees an 8 KiB
 * window in sim).
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.6.
 */
`default_nettype none

module slm_dmem #(
  parameter WORDS = 2048
) (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  input  wire        s_req_valid,  // request valid
  output wire        s_req_ready,  // always ready
  input  wire        s_req_write,  // 1 = write, 0 = read
  input  wire [15:0] s_req_addr,   // window-relative byte address
  input  wire [31:0] s_req_wdata,  // write data
  input  wire [3:0]  s_req_wstrb,  // byte strobes (writes)
  output reg         s_rsp_valid,  // response pulse (reads and writes)
  output reg  [31:0] s_rsp_rdata   // read data
);

  // constant-function clog2 (Verilog-2001 friendly)
  function integer clog2;
    input integer value;
    integer v;
    begin
      v = value - 1;
      for (clog2 = 0; v > 0; clog2 = clog2 + 1)
        v = v >> 1;
    end
  endfunction

  localparam AW = clog2(WORDS);

  reg [31:0] mem [0:WORDS-1];

  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1)
      mem[i] = 32'h0000_0000;
  end

  wire [13:0]   s_word = s_req_addr[15:2];
  wire [AW-1:0] s_idx  = s_word[AW-1:0];

  assign s_req_ready = 1'b1;

  always @(posedge clk) begin
    if (!rst_n) begin
      s_rsp_valid <= 1'b0;
      s_rsp_rdata <= 32'h0000_0000;
    end else begin
      s_rsp_valid <= s_req_valid;
      s_rsp_rdata <= mem[s_idx];
      if (s_req_valid && s_req_write) begin
        if (s_req_wstrb[0]) mem[s_idx][7:0]   <= s_req_wdata[7:0];
        if (s_req_wstrb[1]) mem[s_idx][15:8]  <= s_req_wdata[15:8];
        if (s_req_wstrb[2]) mem[s_idx][23:16] <= s_req_wdata[23:16];
        if (s_req_wstrb[3]) mem[s_idx][31:24] <= s_req_wdata[31:24];
      end
    end
  end

  wire _unused = &{1'b0, s_req_addr[1:0], s_word};

endmodule

`default_nettype wire
