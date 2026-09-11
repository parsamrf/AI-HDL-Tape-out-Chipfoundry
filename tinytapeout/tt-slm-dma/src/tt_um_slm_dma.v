/*
 * TinyTapeout tile: descriptor-chained DMA engine from an SLM inference SoC.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Single-channel word-copy DMA with chained 4-word descriptors. The tile
 * pairs the engine with a 64-word scratch RAM: the SPI register bridge can
 * write descriptors and payload into the RAM, start the DMA through its
 * CSRs, and read the copied data back — the full descriptor-fetch /
 * copy / chain-follow path runs exactly as in the SoC. The same SLB ports
 * could be bus-connected if inter-tile wiring is available.
 *
 * Bridge address map (16-bit SPI address):
 *   0x0000-0x0FFF  DMA CSRs (CTRL/STATUS/DESC_PTR/CFG at 0x00/04/08/0C)
 *   0x1000-0x10FF  scratch RAM, 64 words (word index = addr[7:2])
 * The DMA master port sees the same RAM at any address (index = addr[7:2]),
 * so DESC_PTR/src/dst values like 0x0000_10xx address it naturally.
 *
 * Pins (same convention as the other bridge tiles):
 *   uio[4] CS_n (in) · uio[5] SCK (in) · uio[6] MOSI (in) · uio[3] MISO (out)
 *   uio[0] irq (out) — DMA done (when enabled in CFG)
 */
`default_nettype none

module tt_um_slm_dma (
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
  wire        irq, spi_miso;

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

  // ------------------------------------------------------------------
  // Bridge address decode: bit 12 selects RAM window over DMA CSRs
  // ------------------------------------------------------------------
  wire csr_sel = ~s_req_addr[12];
  wire csr_v   = s_req_valid & csr_sel;
  wire ram_v   = s_req_valid & ~csr_sel;

  wire        dma_rsp_valid;
  wire [31:0] dma_rsp_rdata;

  // DMA SLB master port
  wire        m_req_valid, m_req_write;
  wire [31:0] m_req_addr, m_req_wdata;
  wire [3:0]  m_req_wstrb;
  reg         m_rsp_valid_q;
  reg         br_rsp_q;
  reg  [31:0] ram_rdata_q;

  // RAM arbitration: DMA master has priority; the bridge holds its request
  wire br_grant = ram_v & ~m_req_valid;

  assign s_req_ready = csr_sel ? 1'b1 : br_grant;
  assign s_rsp_valid = dma_rsp_valid | br_rsp_q;
  assign s_rsp_rdata = dma_rsp_valid ? dma_rsp_rdata : ram_rdata_q;

  // ------------------------------------------------------------------
  // 64-word scratch RAM, two requestors
  // ------------------------------------------------------------------
  reg [31:0] ram [0:63];
  integer i;
  initial for (i = 0; i < 64; i = i + 1) ram[i] = 32'h0;

  wire        acc_en    = m_req_valid | ram_v;
  wire        acc_write = m_req_valid ? m_req_write : s_req_write;
  wire [5:0]  acc_idx   = m_req_valid ? m_req_addr[7:2] : s_req_addr[7:2];
  wire [31:0] acc_wdata = m_req_valid ? m_req_wdata : s_req_wdata;
  wire [3:0]  acc_wstrb = m_req_valid ? m_req_wstrb : s_req_wstrb;

  always @(posedge clk) begin
    if (!rst_n) begin
      m_rsp_valid_q <= 1'b0;
      br_rsp_q      <= 1'b0;
    end else begin
      m_rsp_valid_q <= m_req_valid;
      br_rsp_q      <= br_grant;
      if (acc_en) begin
        if (acc_write) begin
          if (acc_wstrb[0]) ram[acc_idx][ 7: 0] <= acc_wdata[ 7: 0];
          if (acc_wstrb[1]) ram[acc_idx][15: 8] <= acc_wdata[15: 8];
          if (acc_wstrb[2]) ram[acc_idx][23:16] <= acc_wdata[23:16];
          if (acc_wstrb[3]) ram[acc_idx][31:24] <= acc_wdata[31:24];
        end else begin
          ram_rdata_q <= ram[acc_idx];
        end
      end
    end
  end

  slm_dma u_dma (
      .clk        (clk),
      .rst_n      (rst_n),
      .s_req_valid(csr_v),
      .s_req_ready(),
      .s_req_write(s_req_write),
      .s_req_addr (s_req_addr),
      .s_req_wdata(s_req_wdata),
      .s_req_wstrb(s_req_wstrb),
      .s_rsp_valid(dma_rsp_valid),
      .s_rsp_rdata(dma_rsp_rdata),
      .m_req_valid(m_req_valid),
      .m_req_ready(1'b1),
      .m_req_write(m_req_write),
      .m_req_addr (m_req_addr),
      .m_req_wdata(m_req_wdata),
      .m_req_wstrb(m_req_wstrb),
      .m_rsp_valid(m_rsp_valid_q),
      .m_rsp_rdata(ram_rdata_q),
      .irq        (irq)
  );

  assign uo_out  = 8'b0;
  assign uio_out = {4'b0, spi_miso, 2'b0, irq};
  assign uio_oe  = 8'b0000_1001;

  wire _unused = &{ena, ui_in, uio_in[7], uio_in[3:0], m_req_addr[31:8], m_req_addr[1:0], 1'b0};

endmodule
