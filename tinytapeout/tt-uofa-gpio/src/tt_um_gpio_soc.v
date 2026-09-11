/*
 * TinyTapeout wrapper for the PicoRV32 + GPIO demonstrator.
 * SPDX-License-Identifier: Apache-2.0
 *
 *   ui_in[7:0] : GPIO input byte (fed to GPIO_IN bits 15:8)
 *   uo_out     : GPIO output byte (live, driven by the CPU program)
 *   uio[0]     : test_done (output)
 *   uio[1]     : trap      (output)
 */
`default_nettype none

module tt_um_gpio_soc (
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
  wire [31:0] result0;
  wire [31:0] gpio_o, gpio_oe_w;

  gpio_demo_top core (
      .clk      (clk),
      .resetn   (rst_n),
      .trap     (trap),
      .test_done(test_done),
      .result0  (result0),
      .gpio_o   (gpio_o),
      .gpio_oe  (gpio_oe_w),
      .gpio_i   ({16'b0, ui_in, 8'b0})
  );

  assign uo_out  = gpio_o[7:0];
  assign uio_out = {6'b0, trap, test_done};
  assign uio_oe  = 8'b0000_0011;

  wire _unused = &{ena, uio_in, gpio_oe_w, gpio_o[31:8], result0, 1'b0};

endmodule
