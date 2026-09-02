/*
 * slm_kv_bank — single-port synchronous-read KV-cache bank RAM.
 *
 * Behavioral 32-bit RAM with per-byte write enables. One access per cycle:
 * when en is high and any we bit is set the selected bytes of mem[addr] are
 * written; when en is high and we == 4'h0 the word at addr is captured into
 * rdata (available the next cycle). rdata holds its value across writes and
 * idle cycles. Storage is zero-initialized in an initial block (synthesis-
 * benign for behavioral RAM; keeps simulation X-free).
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.11 (port list fixed).
 */
`default_nettype none

module slm_kv_bank #(
  parameter WORDS = 512,
  parameter AW    = 9
) (
  input  wire          clk,     // clock
  input  wire          en,      // access enable
  input  wire [3:0]    we,      // byte enables (0 = read)
  input  wire [AW-1:0] addr,    // word address within the bank
  input  wire [31:0]   wdata,   // write data
  output reg  [31:0]   rdata    // sync read data, 1 cycle after en
);

  reg [31:0] mem [0:WORDS-1];

  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1)
      mem[i] = 32'h0;
  end

  always @(posedge clk) begin
    if (en) begin
      if (we[0]) mem[addr][7:0]   <= wdata[7:0];
      if (we[1]) mem[addr][15:8]  <= wdata[15:8];
      if (we[2]) mem[addr][23:16] <= wdata[23:16];
      if (we[3]) mem[addr][31:24] <= wdata[31:24];
      if (we == 4'h0)
        rdata <= mem[addr];
    end
  end

endmodule

`default_nettype wire
