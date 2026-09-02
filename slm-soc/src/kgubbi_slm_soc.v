/*
 * kgubbi_slm_soc — top level of the kgubbi SLM inference SoC.
 *
 * RV32IM_Zicsr 5-stage core + SLM accelerator subsystem (INT8 systolic GEMM,
 * fixed-point softmax, RMSNorm/LayerNorm, banked KV-cache, descriptor DMA)
 * on a 32-bit valid/ready bus (SLB): CPU and DMA master a 2:1 arbiter into
 * an 11-slave address-decoding crossbar. Generic sky130A macro.
 *
 * Memory sizing is decided here only: SLM_HARDEN_SMALL_MEM selects the
 * reduced depths used for the (best-effort, flop-RAM) LibreLane harden;
 * simulation and lint use the full sizes.
 *
 * Reset is synchronized internally (2-FF); uart_rx and gpio_in are
 * synchronized here before use.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md sections 4, 5, 6.13.
 */
`default_nettype none

module kgubbi_slm_soc (
  input  wire       clk,        // 25 MHz target
  input  wire       rst_n,      // asserted low externally; synchronized inside
  input  wire       uart_rx,
  output wire       uart_tx,
  input  wire [7:0] gpio_in,
  output wire [7:0] gpio_out,
  output wire       status_ok,  // firmware heartbeat (GPIO STATUS bit 0)
  output wire       irq_out     // debug: plic meip | timer mtip
);

`ifdef SLM_HARDEN_SMALL_MEM
  localparam IMEM_WORDS    = 256;
  localparam DMEM_WORDS    = 256;
  localparam KV_BANK_WORDS = 64;
`else
  localparam IMEM_WORDS    = 2048;
  localparam DMEM_WORDS    = 2048;
  localparam KV_BANK_WORDS = 512;
`endif

  // xbar slave indices (docs/SPEC.md section 4)
  localparam SL_IMEM    = 0;
  localparam SL_DMEM    = 1;
  localparam SL_KV      = 2;
  localparam SL_GEMM    = 3;
  localparam SL_SOFTMAX = 4;
  localparam SL_RMSNORM = 5;
  localparam SL_DMA     = 6;
  localparam SL_UART    = 7;
  localparam SL_TIMER   = 8;
  localparam SL_PLIC    = 9;
  localparam SL_GPIO    = 10;

  // -------------------------------------------------------------------------
  // Reset and input synchronization
  // -------------------------------------------------------------------------
  wire rstn_i;                   // internal synchronized reset
  wire uart_rx_s;
  wire [7:0] gpio_in_s;

  slm_sync #(.WIDTH(1), .STAGES(2)) u_rst_sync (
    .clk   (clk),
    .rst_n (rst_n),
    .d     (1'b1),
    .q     (rstn_i)
  );

  slm_sync #(.WIDTH(1), .STAGES(2)) u_uart_rx_sync (
    .clk   (clk),
    .rst_n (rstn_i),
    .d     (uart_rx),
    .q     (uart_rx_s)
  );

  slm_sync #(.WIDTH(8), .STAGES(2)) u_gpio_in_sync (
    .clk   (clk),
    .rst_n (rstn_i),
    .d     (gpio_in),
    .q     (gpio_in_s)
  );

  // -------------------------------------------------------------------------
  // CPU
  // -------------------------------------------------------------------------
  wire [31:0] if_addr;
  wire [31:0] if_rdata;

  wire        cpu_req_valid;
  wire        cpu_req_ready;
  wire        cpu_req_write;
  wire [31:0] cpu_req_addr;
  wire [31:0] cpu_req_wdata;
  wire [3:0]  cpu_req_wstrb;
  wire        cpu_rsp_valid;
  wire [31:0] cpu_rsp_rdata;

  wire mtip;
  wire meip;

  slm_cpu_top #(.RESET_PC(32'h0000_0000)) u_cpu (
    .clk          (clk),
    .rst_n        (rstn_i),
    .if_addr      (if_addr),
    .if_rdata     (if_rdata),
    .d_req_valid  (cpu_req_valid),
    .d_req_ready  (cpu_req_ready),
    .d_req_write  (cpu_req_write),
    .d_req_addr   (cpu_req_addr),
    .d_req_wdata  (cpu_req_wdata),
    .d_req_wstrb  (cpu_req_wstrb),
    .d_rsp_valid  (cpu_rsp_valid),
    .d_rsp_rdata  (cpu_rsp_rdata),
    .irq_timer    (mtip),
    .irq_external (meip)
  );

  // -------------------------------------------------------------------------
  // DMA master + 2:1 arbiter -> crossbar
  // -------------------------------------------------------------------------
  wire        dma_m_req_valid;
  wire        dma_m_req_ready;
  wire        dma_m_req_write;
  wire [31:0] dma_m_req_addr;
  wire [31:0] dma_m_req_wdata;
  wire [3:0]  dma_m_req_wstrb;
  wire        dma_m_rsp_valid;
  wire [31:0] dma_m_rsp_rdata;

  wire        arb_req_valid;
  wire        arb_req_ready;
  wire        arb_req_write;
  wire [31:0] arb_req_addr;
  wire [31:0] arb_req_wdata;
  wire [3:0]  arb_req_wstrb;
  wire        arb_rsp_valid;
  wire [31:0] arb_rsp_rdata;

  slm_bus_arbiter u_arbiter (
    .clk          (clk),
    .rst_n        (rstn_i),
    .m0_req_valid (cpu_req_valid),
    .m0_req_ready (cpu_req_ready),
    .m0_req_write (cpu_req_write),
    .m0_req_addr  (cpu_req_addr),
    .m0_req_wdata (cpu_req_wdata),
    .m0_req_wstrb (cpu_req_wstrb),
    .m0_rsp_valid (cpu_rsp_valid),
    .m0_rsp_rdata (cpu_rsp_rdata),
    .m1_req_valid (dma_m_req_valid),
    .m1_req_ready (dma_m_req_ready),
    .m1_req_write (dma_m_req_write),
    .m1_req_addr  (dma_m_req_addr),
    .m1_req_wdata (dma_m_req_wdata),
    .m1_req_wstrb (dma_m_req_wstrb),
    .m1_rsp_valid (dma_m_rsp_valid),
    .m1_rsp_rdata (dma_m_rsp_rdata),
    .s_req_valid  (arb_req_valid),
    .s_req_ready  (arb_req_ready),
    .s_req_write  (arb_req_write),
    .s_req_addr   (arb_req_addr),
    .s_req_wdata  (arb_req_wdata),
    .s_req_wstrb  (arb_req_wstrb),
    .s_rsp_valid  (arb_rsp_valid),
    .s_rsp_rdata  (arb_rsp_rdata)
  );

  wire [10:0]  sl_req_valid;
  wire [10:0]  sl_req_ready;
  wire         sl_req_write;
  wire [15:0]  sl_req_addr;
  wire [31:0]  sl_req_wdata;
  wire [3:0]   sl_req_wstrb;
  wire [10:0]  sl_rsp_valid;
  wire [351:0] sl_rsp_rdata_flat;

  slm_bus_xbar u_xbar (
    .clk               (clk),
    .rst_n             (rstn_i),
    .m_req_valid       (arb_req_valid),
    .m_req_ready       (arb_req_ready),
    .m_req_write       (arb_req_write),
    .m_req_addr        (arb_req_addr),
    .m_req_wdata       (arb_req_wdata),
    .m_req_wstrb       (arb_req_wstrb),
    .m_rsp_valid       (arb_rsp_valid),
    .m_rsp_rdata       (arb_rsp_rdata),
    .s_req_valid       (sl_req_valid),
    .s_req_ready       (sl_req_ready),
    .s_req_write       (sl_req_write),
    .s_req_addr        (sl_req_addr),
    .s_req_wdata       (sl_req_wdata),
    .s_req_wstrb       (sl_req_wstrb),
    .s_rsp_valid       (sl_rsp_valid),
    .s_rsp_rdata_flat  (sl_rsp_rdata_flat)
  );

  // -------------------------------------------------------------------------
  // Memories
  // -------------------------------------------------------------------------
  slm_imem #(.WORDS(IMEM_WORDS)) u_imem (
    .clk         (clk),
    .rst_n       (rstn_i),
    .if_addr     (if_addr),
    .if_rdata    (if_rdata),
    .s_req_valid (sl_req_valid[SL_IMEM]),
    .s_req_ready (sl_req_ready[SL_IMEM]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_IMEM]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_IMEM +: 32])
  );

  slm_dmem #(.WORDS(DMEM_WORDS)) u_dmem (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_DMEM]),
    .s_req_ready (sl_req_ready[SL_DMEM]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_DMEM]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_DMEM +: 32])
  );

  // -------------------------------------------------------------------------
  // KV-cache (SLB port + GEMM read port)
  // -------------------------------------------------------------------------
  wire        gemm_kv_req_valid;
  wire        gemm_kv_req_ready;
  wire [15:0] gemm_kv_req_addr;
  wire        gemm_kv_rsp_valid;
  wire [31:0] gemm_kv_rsp_rdata;

  slm_kv_ctrl #(.BANK_WORDS(KV_BANK_WORDS)) u_kv (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_KV]),
    .s_req_ready (sl_req_ready[SL_KV]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_KV]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_KV +: 32]),
    .g_req_valid (gemm_kv_req_valid),
    .g_req_ready (gemm_kv_req_ready),
    .g_req_addr  (gemm_kv_req_addr),
    .g_rsp_valid (gemm_kv_rsp_valid),
    .g_rsp_rdata (gemm_kv_rsp_rdata)
  );

  // -------------------------------------------------------------------------
  // Accelerators
  // -------------------------------------------------------------------------
  wire gemm_irq;
  wire softmax_irq;
  wire rmsnorm_irq;
  wire dma_irq;

  slm_gemm_ctrl u_gemm (
    .clk          (clk),
    .rst_n        (rstn_i),
    .s_req_valid  (sl_req_valid[SL_GEMM]),
    .s_req_ready  (sl_req_ready[SL_GEMM]),
    .s_req_write  (sl_req_write),
    .s_req_addr   (sl_req_addr),
    .s_req_wdata  (sl_req_wdata),
    .s_req_wstrb  (sl_req_wstrb),
    .s_rsp_valid  (sl_rsp_valid[SL_GEMM]),
    .s_rsp_rdata  (sl_rsp_rdata_flat[32*SL_GEMM +: 32]),
    .kv_req_valid (gemm_kv_req_valid),
    .kv_req_ready (gemm_kv_req_ready),
    .kv_req_addr  (gemm_kv_req_addr),
    .kv_rsp_valid (gemm_kv_rsp_valid),
    .kv_rsp_rdata (gemm_kv_rsp_rdata),
    .irq          (gemm_irq)
  );

  slm_softmax u_softmax (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_SOFTMAX]),
    .s_req_ready (sl_req_ready[SL_SOFTMAX]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_SOFTMAX]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_SOFTMAX +: 32]),
    .irq         (softmax_irq)
  );

  slm_rmsnorm u_rmsnorm (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_RMSNORM]),
    .s_req_ready (sl_req_ready[SL_RMSNORM]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_RMSNORM]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_RMSNORM +: 32]),
    .irq         (rmsnorm_irq)
  );

  slm_dma u_dma (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_DMA]),
    .s_req_ready (sl_req_ready[SL_DMA]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_DMA]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_DMA +: 32]),
    .m_req_valid (dma_m_req_valid),
    .m_req_ready (dma_m_req_ready),
    .m_req_write (dma_m_req_write),
    .m_req_addr  (dma_m_req_addr),
    .m_req_wdata (dma_m_req_wdata),
    .m_req_wstrb (dma_m_req_wstrb),
    .m_rsp_valid (dma_m_rsp_valid),
    .m_rsp_rdata (dma_m_rsp_rdata),
    .irq         (dma_irq)
  );

  // -------------------------------------------------------------------------
  // Peripherals
  // -------------------------------------------------------------------------
  wire uart_irq_rx;
  wire uart_irq_tx;
  wire gpio_irq;

  slm_uart u_uart (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_UART]),
    .s_req_ready (sl_req_ready[SL_UART]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_UART]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_UART +: 32]),
    .rx          (uart_rx_s),
    .tx          (uart_tx),
    .irq_rx      (uart_irq_rx),
    .irq_tx      (uart_irq_tx)
  );

  slm_timer u_timer (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_TIMER]),
    .s_req_ready (sl_req_ready[SL_TIMER]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_TIMER]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_TIMER +: 32]),
    .mtip        (mtip)
  );

  // interrupt source map (docs/SPEC.md section 5)
  wire [7:0] plic_src = {1'b0,        // 7 spare
                         gpio_irq,    // 6
                         rmsnorm_irq, // 5
                         softmax_irq, // 4
                         gemm_irq,    // 3
                         dma_irq,     // 2
                         uart_irq_tx, // 1
                         uart_irq_rx};// 0

  slm_plic u_plic (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_PLIC]),
    .s_req_ready (sl_req_ready[SL_PLIC]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_PLIC]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_PLIC +: 32]),
    .src         (plic_src),
    .meip        (meip)
  );

  slm_gpio u_gpio (
    .clk         (clk),
    .rst_n       (rstn_i),
    .s_req_valid (sl_req_valid[SL_GPIO]),
    .s_req_ready (sl_req_ready[SL_GPIO]),
    .s_req_write (sl_req_write),
    .s_req_addr  (sl_req_addr),
    .s_req_wdata (sl_req_wdata),
    .s_req_wstrb (sl_req_wstrb),
    .s_rsp_valid (sl_rsp_valid[SL_GPIO]),
    .s_rsp_rdata (sl_rsp_rdata_flat[32*SL_GPIO +: 32]),
    .gpio_in     (gpio_in_s),
    .gpio_out    (gpio_out),
    .status_ok   (status_ok),
    .irq         (gpio_irq)
  );

  assign irq_out = meip | mtip;

endmodule

`default_nettype wire
