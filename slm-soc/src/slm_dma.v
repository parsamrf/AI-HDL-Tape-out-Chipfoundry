/*
 * slm_dma — descriptor-chained single-channel word-copy DMA engine.
 *
 * Descriptor = 4 consecutive words at a word-aligned address:
 *   [0] src (byte address, word-aligned)
 *   [1] dst (byte address, word-aligned)
 *   [2] len (bytes, multiple of 4; 0 = skip the copy)
 *   [3] next_flags: b0 = next descriptor valid, b1 = raise done at chain stop;
 *       next descriptor address = next_flags & ~32'h3
 *
 * CTRL.start latches DESC_PTR (ignored while busy) and the engine fetches the
 * 4 descriptor words over the SLB master port, copies word-by-word
 * (read src+4i, then write dst+4i, one outstanding transaction), and follows
 * the chain while next_flags[0] is set. Misaligned src/dst/len (checked per
 * descriptor, before the len==0 skip) or a misaligned DESC_PTR at start set
 * STATUS.err and stop the engine. done and err are sticky until CTRL.clear.
 *
 * Spec-interpretation note (SPEC 6.12): the register map states
 * irq = done & irq_en, so for next_flags b1 to be meaningful the done flag is
 * set at the end of the chain only when the chain-stopping descriptor
 * (b0 = 0) has b1 = 1; a chain ending with b1 = 0 completes silently
 * (busy drops, done stays 0, no irq). Poll STATUS.busy for completion.
 *
 * Register map: 0x00 CTRL (W: b0 start, b1 clear done+err), 0x04 STATUS
 * (R: b0 busy, b1 done, b2 err), 0x08 DESC_PTR (RW), 0x0C CFG (RW: b0 irq_en).
 * CSR writes apply byte strobes; undefined offsets read as 0.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.12.
 */
`default_nettype none

module slm_dma (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  // CSR slave port (window 0x3003_0000)
  input  wire        s_req_valid,  // request valid
  output wire        s_req_ready,  // tied 1 (simple CSR slave)
  input  wire        s_req_write,  // 1 = write
  input  wire [15:0] s_req_addr,   // window-relative byte address
  input  wire [31:0] s_req_wdata,  // write data
  input  wire [3:0]  s_req_wstrb,  // byte strobes
  output reg         s_rsp_valid,  // 1-cycle response pulse
  output reg  [31:0] s_rsp_rdata,  // read data
  // SLB master port
  output wire        m_req_valid,  // request valid (held until ready)
  input  wire        m_req_ready,  // slave accepts this cycle
  output wire        m_req_write,  // 1 = write
  output wire [31:0] m_req_addr,   // byte address
  output wire [31:0] m_req_wdata,  // write data
  output wire [3:0]  m_req_wstrb,  // byte strobes (writes)
  input  wire        m_rsp_valid,  // 1-cycle response pulse
  input  wire [31:0] m_rsp_rdata,  // read data
  // interrupt
  output wire        irq           // level: done & irq_en
);

  localparam [2:0] S_IDLE  = 3'd0;
  localparam [2:0] S_FETCH = 3'd1;
  localparam [2:0] S_CHECK = 3'd2;
  localparam [2:0] S_RD    = 3'd3;
  localparam [2:0] S_WR    = 3'd4;
  localparam [2:0] S_NEXT  = 3'd5;

  reg [2:0]  state;
  reg        busy_q;
  reg        done_q;
  reg        err_q;
  reg        irqen_q;
  reg [31:0] desc_q;   // DESC_PTR CSR register
  reg [31:0] dptr;     // latched descriptor pointer (current descriptor)
  reg [1:0]  didx;     // descriptor word being fetched
  reg [31:0] dsrc;
  reg [31:0] ddst;
  reg [31:0] dlen;
  reg [31:0] dnext;
  reg [31:0] off;      // byte offset within current copy

  // SLB master issue registers
  reg        mv;       // request valid
  reg        mw;       // request is a write
  reg [31:0] maddr;
  reg [31:0] mwd;

  // CSR decode (simple CSR slave: always ready, response next cycle)
  assign s_req_ready = 1'b1;

  wire csr_acc    = s_req_valid;
  wire csr_wr     = csr_acc && s_req_write;
  wire sel_ctrl   = (s_req_addr[15:2] == 14'd0);
  wire sel_status = (s_req_addr[15:2] == 14'd1);
  wire sel_desc   = (s_req_addr[15:2] == 14'd2);
  wire sel_cfg    = (s_req_addr[15:2] == 14'd3);
  wire start_req  = csr_wr && sel_ctrl && s_req_wstrb[0] && s_req_wdata[0];
  wire clear_req  = csr_wr && sel_ctrl && s_req_wstrb[0] && s_req_wdata[1];

  always @(posedge clk) begin
    if (!rst_n) begin
      s_rsp_valid <= 1'b0;
      s_rsp_rdata <= 32'h0;
    end else begin
      s_rsp_valid <= csr_acc;
      s_rsp_rdata <= 32'h0;
      if (csr_acc && !s_req_write) begin
        if (sel_status)    s_rsp_rdata <= {29'h0, err_q, done_q, busy_q};
        else if (sel_desc) s_rsp_rdata <= desc_q;
        else if (sel_cfg)  s_rsp_rdata <= {31'h0, irqen_q};
      end
    end
  end

  wire [1:0] didx_p1 = didx + 2'd1;

  // Master-port address filter (security): the DMA may only touch memory
  // (IMEM/DMEM/KV, regions 0x0-0x2) and the accelerator buffer windows
  // (0x3000/0x3001/0x3002_xxxx). Peripheral CSRs (all of 0x4xxx_xxxx, and
  // the DMA's own window 0x3003_xxxx) have read side effects (PLIC claim,
  // UART RX pop), so a descriptor naming them aborts with STATUS.err
  // instead of silently draining interrupts or RX bytes.
  function dma_addr_ok(input [31:0] a);
    dma_addr_ok = (a[31:28] <= 4'h2) ||
                  ((a[31:28] == 4'h3) && (a[17:16] != 2'b11));
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      busy_q  <= 1'b0;
      done_q  <= 1'b0;
      err_q   <= 1'b0;
      irqen_q <= 1'b0;
      desc_q  <= 32'h0;
      dptr    <= 32'h0;
      didx    <= 2'd0;
      dsrc    <= 32'h0;
      ddst    <= 32'h0;
      dlen    <= 32'h0;
      dnext   <= 32'h0;
      off     <= 32'h0;
      mv      <= 1'b0;
      mw      <= 1'b0;
      maddr   <= 32'h0;
      mwd     <= 32'h0;
    end else begin
      // CSR register writes
      if (csr_wr && sel_desc) begin
        if (s_req_wstrb[0]) desc_q[7:0]   <= s_req_wdata[7:0];
        if (s_req_wstrb[1]) desc_q[15:8]  <= s_req_wdata[15:8];
        if (s_req_wstrb[2]) desc_q[23:16] <= s_req_wdata[23:16];
        if (s_req_wstrb[3]) desc_q[31:24] <= s_req_wdata[31:24];
      end
      if (csr_wr && sel_cfg && s_req_wstrb[0])
        irqen_q <= s_req_wdata[0];
      if (clear_req) begin
        done_q <= 1'b0;
        err_q  <= 1'b0;
      end

      // master request accepted: drop valid (response may come later)
      if (mv && m_req_ready)
        mv <= 1'b0;

      case (state)
        S_IDLE: begin
          if (start_req) begin
            if ((desc_q[1:0] != 2'b00) || !dma_addr_ok(desc_q)) begin
              err_q <= 1'b1;          // misaligned or out-of-range descriptor pointer
            end else begin
              busy_q <= 1'b1;
              dptr   <= desc_q;
              didx   <= 2'd0;
              mv     <= 1'b1;
              mw     <= 1'b0;
              maddr  <= desc_q;
              state  <= S_FETCH;
            end
          end
        end
        S_FETCH: begin
          if (m_rsp_valid) begin
            case (didx)
              2'd0:    dsrc  <= m_rsp_rdata;
              2'd1:    ddst  <= m_rsp_rdata;
              2'd2:    dlen  <= m_rsp_rdata;
              default: dnext <= m_rsp_rdata;
            endcase
            if (didx == 2'd3) begin
              state <= S_CHECK;
            end else begin
              didx  <= didx_p1;
              mv    <= 1'b1;
              mw    <= 1'b0;
              maddr <= dptr + {28'h0, didx_p1, 2'b00};
            end
          end
        end
        S_CHECK: begin
          if ((dsrc[1:0] != 2'b00) || (ddst[1:0] != 2'b00) ||
              (dlen[1:0] != 2'b00)) begin
            err_q  <= 1'b1;
            busy_q <= 1'b0;
            state  <= S_IDLE;
          end else if (dlen == 32'h0) begin
            state <= S_NEXT;          // len 0 = skip the copy
          end else if (!dma_addr_ok(dsrc) || !dma_addr_ok(ddst) ||
                       !dma_addr_ok(dsrc + dlen - 32'd4) ||
                       !dma_addr_ok(ddst + dlen - 32'd4)) begin
            err_q  <= 1'b1;           // src/dst window outside DMA-legal space
            busy_q <= 1'b0;
            state  <= S_IDLE;
          end else begin
            off   <= 32'h0;
            mv    <= 1'b1;
            mw    <= 1'b0;
            maddr <= dsrc;
            state <= S_RD;
          end
        end
        S_RD: begin
          if (m_rsp_valid) begin
            mv    <= 1'b1;
            mw    <= 1'b1;
            mwd   <= m_rsp_rdata;
            maddr <= ddst + off;
            state <= S_WR;
          end
        end
        S_WR: begin
          if (m_rsp_valid) begin
            if (off + 32'd4 == dlen) begin
              state <= S_NEXT;
            end else begin
              off   <= off + 32'd4;
              mv    <= 1'b1;
              mw    <= 1'b0;
              maddr <= dsrc + off + 32'd4;
              state <= S_RD;
            end
          end
        end
        S_NEXT: begin
          if (dnext[0] && !dma_addr_ok({dnext[31:2], 2'b00})) begin
            err_q  <= 1'b1;           // chained descriptor outside DMA-legal space
            busy_q <= 1'b0;
            state  <= S_IDLE;
          end else if (dnext[0]) begin
            dptr  <= {dnext[31:2], 2'b00};
            didx  <= 2'd0;
            mv    <= 1'b1;
            mw    <= 1'b0;
            maddr <= {dnext[31:2], 2'b00};
            state <= S_FETCH;
          end else begin
            busy_q <= 1'b0;
            if (dnext[1])
              done_q <= 1'b1;
            state <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  assign m_req_valid = mv;
  assign m_req_write = mw;
  assign m_req_addr  = maddr;
  assign m_req_wdata = mwd;
  assign m_req_wstrb = mw ? 4'hF : 4'h0;

  assign irq = done_q & irqen_q;

  wire _unused = &{1'b0, s_req_addr[1:0]};

endmodule

`default_nettype wire
