/*
 * slm_gpio — 8-bit GPIO with input-change interrupt, SLB CSR slave.
 *
 * gpio_in is synchronized at the SoC top level before reaching this block.
 * Register map (window-relative, see docs/SPEC.md section 6.7):
 *   0x00 IN       (R)  : current synchronized input
 *   0x04 OUT      (RW) : drives gpio_out
 *   0x08 STATUS   (RW) : b0 status_ok (firmware heartbeat)
 *   0x0C IRQ_EN   (RW) : b0 global input-change interrupt enable
 *   0x10 IRQ_PEND (R, W1C): per-bit, set on any change of the input
 * irq = |IRQ_PEND & IRQ_EN[0] (level).
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.7.
 */
`default_nettype none

module slm_gpio (
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
  // pins / status / interrupt
  input  wire [7:0]  gpio_in,      // inputs (pre-synchronized at top)
  output wire [7:0]  gpio_out,     // outputs (OUT register)
  output wire        status_ok,    // STATUS b0 (firmware heartbeat)
  output wire        irq           // level: |IRQ_PEND & IRQ_EN[0]
);

  // register word offsets (s_req_addr[15:2])
  localparam [13:0] A_IN      = 14'd0;
  localparam [13:0] A_OUT     = 14'd1;
  localparam [13:0] A_STATUS  = 14'd2;
  localparam [13:0] A_IRQEN   = 14'd3;
  localparam [13:0] A_IRQPEND = 14'd4;

  reg [7:0] out_q;
  reg       ok_q;
  reg       irq_en_q;
  reg [7:0] pend_q;
  reg [7:0] in_prev;

  assign s_req_ready = 1'b1;
  assign gpio_out    = out_q;
  assign status_ok   = ok_q;
  assign irq         = (|pend_q) & irq_en_q;

  wire [7:0] in_chg = gpio_in ^ in_prev;

  wire [13:0] csr_word = s_req_addr[15:2];
  wire        csr_wr   = s_req_valid & s_req_write;

  // W1C mask for IRQ_PEND
  wire [7:0] w1c_mask = (csr_wr && csr_word == A_IRQPEND && s_req_wstrb[0])
                        ? s_req_wdata[7:0] : 8'h00;

  // read data mux
  reg [31:0] rd_mux;
  always @* begin
    case (csr_word)
      A_IN:      rd_mux = {24'h000000, gpio_in};
      A_OUT:     rd_mux = {24'h000000, out_q};
      A_STATUS:  rd_mux = {31'd0, ok_q};
      A_IRQEN:   rd_mux = {31'd0, irq_en_q};
      A_IRQPEND: rd_mux = {24'h000000, pend_q};
      default:   rd_mux = 32'h0000_0000;
    endcase
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      s_rsp_valid <= 1'b0;
      s_rsp_rdata <= 32'h0000_0000;
      out_q       <= 8'h00;
      ok_q        <= 1'b0;
      irq_en_q    <= 1'b0;
      pend_q      <= 8'h00;
      in_prev     <= 8'h00;
    end else begin
      s_rsp_valid <= s_req_valid;
      s_rsp_rdata <= rd_mux;

      in_prev <= gpio_in;
      pend_q  <= (pend_q & ~w1c_mask) | in_chg;  // change set beats W1C

      if (csr_wr && csr_word == A_OUT && s_req_wstrb[0])
        out_q <= s_req_wdata[7:0];
      if (csr_wr && csr_word == A_STATUS && s_req_wstrb[0])
        ok_q <= s_req_wdata[0];
      if (csr_wr && csr_word == A_IRQEN && s_req_wstrb[0])
        irq_en_q <= s_req_wdata[0];
    end
  end

  wire _unused = &{1'b0, s_req_wdata[31:8], s_req_wstrb[3:1], s_req_addr[1:0]};

endmodule

`default_nettype wire
