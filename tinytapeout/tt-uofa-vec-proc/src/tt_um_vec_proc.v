/*
 * TinyTapeout wrapper for the PicoRV32 SIMD vector processor demonstrator.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The core boots a hardwired ROM self-test exercising VADD8 / VSADD8 /
 * VMUL8 / VDOT8 plus an SRAM round-trip, and latches five 32-bit results.
 * This wrapper exposes them through a byte-select mux:
 *
 *   ui_in[1:0] : byte select (0 = bits 7:0 ... 3 = bits 31:24)
 *   ui_in[4:2] : result select (0=VADD8, 1=VSADD8, 2=VMUL8, 3=VDOT8, 4=SRAM)
 *   uo_out     : selected result byte
 *   uio[0]     : test_done (output)
 *   uio[1]     : trap      (output)
 */
`default_nettype none

module tt_um_vec_proc (
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
  wire [31:0] r_vadd8, r_vsadd8, r_vmul8, r_vdot8, r_sram;

  picorv32_vec_proc_top core (
      .clk           (clk),
      .resetn        (rst_n),
      .trap          (trap),
      .test_done     (test_done),
      .result_vadd8  (r_vadd8),
      .result_vsadd8 (r_vsadd8),
      .result_vmul8  (r_vmul8),
      .result_vdot8  (r_vdot8),
      .result_sram   (r_sram)
  );

  reg [31:0] sel_word;
  always @(*) begin
    case (ui_in[4:2])
      3'd0: sel_word = r_vadd8;
      3'd1: sel_word = r_vsadd8;
      3'd2: sel_word = r_vmul8;
      3'd3: sel_word = r_vdot8;
      default: sel_word = r_sram;
    endcase
  end

  assign uo_out  = sel_word >> {ui_in[1:0], 3'b000};
  assign uio_out = {6'b0, trap, test_done};
  assign uio_oe  = 8'b0000_0011;

  wire _unused = &{ena, uio_in, ui_in[7:5], 1'b0};

endmodule
