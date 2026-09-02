/*
 * slm_uart — 8N1 UART with programmable 16-bit divisor, SLB CSR slave.
 *
 * Register map (window-relative, see docs/SPEC.md section 6.7):
 *   0x00 TXDATA (W)  : write while idle starts transmission; dropped if busy
 *   0x04 RXDATA (R)  : returns RX buffer and pops it (clears rx_valid)
 *   0x08 STATUS (R/W): R: b0 tx_busy, b1 rx_valid, b2 rx_overrun (sticky),
 *                      b3 tx_done (sticky); W: write 1 to b2/b3 clears
 *   0x0C DIV    (RW) : clocks per bit, reset 16'd217 (must be >= 2)
 *   0x10 IRQ_EN (RW) : b0 rx enable, b1 tx enable
 * irq_rx = rx_valid & IRQ_EN[0], irq_tx = tx_done & IRQ_EN[1] (levels).
 *
 * RX holding is 1-deep: if a new frame completes while rx_valid is still
 * set, the buffer is overwritten with the new byte and rx_overrun goes
 * sticky. Frames with a low stop bit (framing error) are discarded. The rx
 * input is re-synchronized internally through slm_sync (2 flops) as an
 * extra metastability guard; this only adds 2 clk cycles of latency.
 * Caveat: DIV values below 2 are not supported.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.7.
 */
`default_nettype none

module slm_uart (
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
  // serial pins / interrupts
  input  wire        rx,           // serial in (idle high)
  output wire        tx,           // serial out (idle high)
  output wire        irq_rx,       // level: rx_valid & IRQ_EN[0]
  output wire        irq_tx        // level: tx_done & IRQ_EN[1]
);

  // register word offsets (s_req_addr[15:2])
  localparam [13:0] A_TXDATA = 14'd0;
  localparam [13:0] A_RXDATA = 14'd1;
  localparam [13:0] A_STATUS = 14'd2;
  localparam [13:0] A_DIV    = 14'd3;
  localparam [13:0] A_IRQEN  = 14'd4;

  // RX FSM states
  localparam [1:0] R_IDLE  = 2'd0;
  localparam [1:0] R_START = 2'd1;
  localparam [1:0] R_DATA  = 2'd2;
  localparam [1:0] R_STOP  = 2'd3;

  // CSRs
  reg [15:0] div_q;     // clocks per bit
  reg [1:0]  irq_en_q;  // b0 rx, b1 tx

  // TX engine
  reg        tx_busy_q;
  reg        tx_done_q;
  reg [9:0]  tx_sh;     // {stop, data[7:0], start}
  reg [3:0]  tx_bits;
  reg [15:0] tx_cnt;

  // RX engine
  reg [1:0]  rx_state;
  reg [15:0] rx_cnt;
  reg [2:0]  rx_bit;
  reg [7:0]  rx_sh;
  reg [7:0]  rx_data_q;
  reg        rx_valid_q;
  reg        rx_ovr_q;
  reg        rx_prev;

  // rx re-synchronization (extra metastability guard)
  wire rx_s;
  slm_sync #(
    .WIDTH  (1),
    .STAGES (2)
  ) u_rx_sync (
    .clk   (clk),
    .rst_n (rst_n),
    .d     (rx),
    .q     (rx_s)
  );

  assign s_req_ready = 1'b1;
  assign tx          = tx_busy_q ? tx_sh[0] : 1'b1;
  assign irq_rx      = rx_valid_q & irq_en_q[0];
  assign irq_tx      = tx_done_q  & irq_en_q[1];

  wire [13:0] csr_word = s_req_addr[15:2];
  wire        csr_wr   = s_req_valid & s_req_write;
  wire        csr_rd   = s_req_valid & ~s_req_write;
  wire        tx_start = csr_wr && (csr_word == A_TXDATA) && s_req_wstrb[0];

  // read data mux
  reg [31:0] rd_mux;
  always @* begin
    case (csr_word)
      A_RXDATA: rd_mux = {24'h000000, rx_data_q};
      A_STATUS: rd_mux = {28'h0000000, tx_done_q, rx_ovr_q, rx_valid_q, tx_busy_q};
      A_DIV:    rd_mux = {16'h0000, div_q};
      A_IRQEN:  rd_mux = {30'd0, irq_en_q};
      default:  rd_mux = 32'h0000_0000;  // includes write-only TXDATA
    endcase
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      s_rsp_valid <= 1'b0;
      s_rsp_rdata <= 32'h0000_0000;
      div_q       <= 16'd217;
      irq_en_q    <= 2'b00;
      tx_busy_q   <= 1'b0;
      tx_done_q   <= 1'b0;
      tx_sh       <= 10'h3FF;
      tx_bits     <= 4'd0;
      tx_cnt      <= 16'd0;
      rx_state    <= R_IDLE;
      rx_cnt      <= 16'd0;
      rx_bit      <= 3'd0;
      rx_sh       <= 8'h00;
      rx_data_q   <= 8'h00;
      rx_valid_q  <= 1'b0;
      rx_ovr_q    <= 1'b0;
      rx_prev     <= 1'b0;
    end else begin
      // ----------------------------------------------------------------
      // CSR response (1 cycle after acceptance)
      // ----------------------------------------------------------------
      s_rsp_valid <= s_req_valid;
      s_rsp_rdata <= rd_mux;

      // ----------------------------------------------------------------
      // CSR writes / read side effects (engine updates below take
      // precedence on same-cycle conflicts)
      // ----------------------------------------------------------------
      if (csr_wr) begin
        if (csr_word == A_STATUS && s_req_wstrb[0]) begin
          if (s_req_wdata[2]) rx_ovr_q  <= 1'b0;  // W1C overrun
          if (s_req_wdata[3]) tx_done_q <= 1'b0;  // W1C tx_done
        end
        if (csr_word == A_DIV) begin
          if (s_req_wstrb[0]) div_q[7:0]  <= s_req_wdata[7:0];
          if (s_req_wstrb[1]) div_q[15:8] <= s_req_wdata[15:8];
        end
        if (csr_word == A_IRQEN && s_req_wstrb[0])
          irq_en_q <= s_req_wdata[1:0];
      end
      if (csr_rd && csr_word == A_RXDATA)
        rx_valid_q <= 1'b0;  // pop RX buffer

      // ----------------------------------------------------------------
      // TX engine: 10 bits (start, 8 data LSB-first, stop), div_q clocks
      // per bit; TXDATA writes while busy are dropped
      // ----------------------------------------------------------------
      if (tx_busy_q) begin
        if (tx_cnt == 16'd0) begin
          if (tx_bits == 4'd1) begin
            tx_busy_q <= 1'b0;
            tx_done_q <= 1'b1;
          end else begin
            tx_sh   <= {1'b1, tx_sh[9:1]};
            tx_bits <= tx_bits - 4'd1;
            tx_cnt  <= div_q - 16'd1;
          end
        end else begin
          tx_cnt <= tx_cnt - 16'd1;
        end
      end else if (tx_start) begin
        tx_sh     <= {1'b1, s_req_wdata[7:0], 1'b0};
        tx_bits   <= 4'd10;
        tx_cnt    <= div_q - 16'd1;
        tx_busy_q <= 1'b1;
      end

      // ----------------------------------------------------------------
      // RX engine: start on falling edge, sample mid-bit
      // ----------------------------------------------------------------
      rx_prev <= rx_s;
      case (rx_state)
        R_IDLE: begin
          if (rx_prev && !rx_s) begin
            rx_state <= R_START;
            rx_cnt   <= {1'b0, div_q[15:1]} - 16'd1;  // half bit to mid-start
          end
        end
        R_START: begin
          if (rx_cnt == 16'd0) begin
            if (!rx_s) begin
              rx_state <= R_DATA;
              rx_cnt   <= div_q - 16'd1;
              rx_bit   <= 3'd0;
            end else begin
              rx_state <= R_IDLE;  // glitch, abandon
            end
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end
        R_DATA: begin
          if (rx_cnt == 16'd0) begin
            rx_sh  <= {rx_s, rx_sh[7:1]};  // LSB first
            rx_cnt <= div_q - 16'd1;
            if (rx_bit == 3'd7)
              rx_state <= R_STOP;
            else
              rx_bit <= rx_bit + 3'd1;
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end
        R_STOP: begin
          if (rx_cnt == 16'd0) begin
            rx_state <= R_IDLE;
            if (rx_s) begin  // good stop bit
              rx_data_q  <= rx_sh;
              rx_valid_q <= 1'b1;
              if (rx_valid_q)
                rx_ovr_q <= 1'b1;  // buffer still full: overrun
            end
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end
        default: rx_state <= R_IDLE;
      endcase
    end
  end

  wire _unused = &{1'b0, s_req_wdata[31:16], s_req_wstrb[3:2], s_req_addr[1:0]};

endmodule

`default_nettype wire
