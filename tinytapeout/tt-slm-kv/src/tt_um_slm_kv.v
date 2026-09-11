/*
 * TinyTapeout tile: banked KV-cache controller from an SLM inference SoC.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Four word-interleaved single-port RAM banks (bank = addr[3:2]) behind a
 * two-port arbiter (CPU/SLB port + GEMM read port, SLB priority). The SLB
 * port is exposed through a 32-bit SPI register bridge, so the tile is fully
 * exercisable stand-alone — and the same SLB port could be bus-connected if
 * inter-tile wiring is available. The GEMM read port is tied off (no
 * requests) in this tile.
 *
 * Bank size is reduced to 16 words per bank (256 B total KV space) to keep
 * the tile small; the controller is parametric and unchanged.
 *
 * Pins (same convention as the other bridge tiles):
 *   uio[4] CS_n (in) · uio[5] SCK (in) · uio[6] MOSI (in) · uio[3] MISO (out)
 */
`default_nettype none

module tt_um_slm_kv (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire        s_req_valid, s_req_ready, s_req_write, s_rsp_valid;
  wire [15:0] s_req_addr;
  wire [31:0] s_req_wdata, s_rsp_rdata;
  wire [3:0]  s_req_wstrb;
  wire        spi_miso;

  slb_spi_bridge u_bridge (
      .clk        (clk),
      .rst_n      (rst_n),
      .spi_cs_n   (uio_in[4]),
      .spi_clk    (uio_in[5]),
      .spi_mosi   (uio_in[6]),
      .spi_miso   (spi_miso),
      .s_req_valid(s_req_valid),
      .s_req_ready(s_req_ready),
      .s_req_write(s_req_write),
      .s_req_addr (s_req_addr),
      .s_req_wdata(s_req_wdata),
      .s_req_wstrb(s_req_wstrb),
      .s_rsp_valid(s_rsp_valid),
      .s_rsp_rdata(s_rsp_rdata)
  );

  slm_kv_ctrl #(
      .BANK_WORDS(16)
  ) u_kv (
      .clk        (clk),
      .rst_n      (rst_n),
      .s_req_valid(s_req_valid),
      .s_req_ready(s_req_ready),
      .s_req_write(s_req_write),
      .s_req_addr (s_req_addr),
      .s_req_wdata(s_req_wdata),
      .s_req_wstrb(s_req_wstrb),
      .s_rsp_valid(s_rsp_valid),
      .s_rsp_rdata(s_rsp_rdata),
      .g_req_valid(1'b0),
      .g_req_ready(),
      .g_req_addr (16'h0),
      .g_rsp_valid(),
      .g_rsp_rdata()
  );

  assign uo_out  = 8'b0;
  assign uio_out = {4'b0, spi_miso, 3'b0};
  assign uio_oe  = 8'b0000_1000;

  wire _unused = &{ena, ui_in, uio_in[7], uio_in[3:0], 1'b0};

endmodule
