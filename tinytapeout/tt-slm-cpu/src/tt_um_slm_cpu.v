/*
 * TinyTapeout tile: RV32IM CPU core from an SLM inference SoC.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The core boots from a hardwired ROM and runs an RV32IM self-test
 * (multiply, signed divide/remainder, store/load round-trip through a
 * small data RAM). The four 32-bit results are readable a byte at a
 * time on uo_out, selected by ui_in[3:0]:
 *
 *   ui_in[3:2] : result index (0=MUL, 1=DIV, 2=REM, 3=LW round-trip)
 *   ui_in[1:0] : byte lane within that result (0 = bits 7:0)
 *   uo_out     : selected byte
 *   uio[0]     : test_done (out)
 */
`default_nettype none

module tt_um_slm_cpu (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire        test_done;
  wire [31:0] result0, result1, result2, result3;

  cpu_demo_top core (
      .clk      (clk),
      .rst_n    (rst_n),
      .test_done(test_done),
      .result0  (result0),
      .result1  (result1),
      .result2  (result2),
      .result3  (result3)
  );

  reg [31:0] res_sel;
  always @(*) begin
    case (ui_in[3:2])
      2'd0: res_sel = result0;
      2'd1: res_sel = result1;
      2'd2: res_sel = result2;
      2'd3: res_sel = result3;
    endcase
  end

  assign uo_out  = res_sel >> (8 * ui_in[1:0]);
  assign uio_out = {7'b0, test_done};
  assign uio_oe  = 8'b0000_0001;

  wire _unused = &{ena, ui_in[7:4], uio_in, 1'b0};

endmodule
