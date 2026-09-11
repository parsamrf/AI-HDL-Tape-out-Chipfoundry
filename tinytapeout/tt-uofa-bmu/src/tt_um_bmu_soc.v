/*
 * TinyTapeout wrapper for the PicoRV32 Bit Manipulation Unit demonstrator.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The core boots a hardwired ROM self-test exercising the BMU's LZC / TZC /
 * bit-reverse / popcount custom-0 instructions on 0x00F0F0F0 and latches
 * four 32-bit results. This wrapper exposes them through a byte-select mux:
 *
 *   ui_in[1:0] : byte select (0 = bits 7:0 ... 3 = bits 31:24)
 *   ui_in[3:2] : result select (0=LZC, 1=TZC, 2=REV, 3=POPCOUNT)
 *   uo_out     : selected result byte
 *   uio[0]     : test_done (output)
 *   uio[1]     : trap      (output)
 */
`default_nettype none

module tt_um_bmu_soc (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire        trap;
  wire        test_done;
  wire [31:0] r_lzc, r_tzc, r_rev, r_pop;

  bmu_demo_top core (
      .clk        (clk),
      .resetn     (rst_n),
      .trap       (trap),
      .test_done  (test_done),
      .result_lzc (r_lzc),
      .result_tzc (r_tzc),
      .result_rev (r_rev),
      .result_pop (r_pop)
  );

  reg [31:0] sel_word;
  always @(*) begin
    case (ui_in[3:2])
      2'd0: sel_word = r_lzc;
      2'd1: sel_word = r_tzc;
      2'd2: sel_word = r_rev;
      default: sel_word = r_pop;
    endcase
  end

  assign uo_out  = sel_word >> {ui_in[1:0], 3'b000};
  assign uio_out = {6'b0, trap, test_done};
  assign uio_oe  = 8'b0000_0011;

  wire _unused = &{ena, uio_in, ui_in[7:4], 1'b0};

endmodule
