/*
 * slm_softmax — fixed-point softmax accelerator (SLB CSR slave, window
 * 0x3001_0000).
 *
 * p_i = floor( e_i * 255 / sum_j e_j ) with e_i = 2^((x_i - max)/16),
 * x_i signed INT8, N = 2..64 elements. Three-pass FSM over the scratch RAM:
 *   pass 1: signed max-reduce over x
 *   pass 2: exponentiate d_i = x_i - max through slm_exp_unit (Q1.16) and
 *           accumulate the sum
 *   pass 3: per element, slm_recip_div computes (e_i * 255) / sum and the
 *           8-bit quotient is written back to scratch byte 0
 *
 * Register map (window-relative):
 *   0x0000 CTRL   (W)  b0 start (ignored while busy), b1 clear_done
 *   0x0004 STATUS (R)  b0 busy, b1 done (sticky)
 *   0x0008 CFG    (RW) [6:0] N = 2..64, b8 irq_en
 *   0x0100-0x01FC scratch, one element per word: input signed INT8 in [7:0];
 *                 after done, [7:0] = unsigned probability (upper bytes are
 *                 preserved as written)
 * Undefined offsets read 0. irq = done & irq_en (level).
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.9.
 */
`default_nettype none

module slm_softmax (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  input  wire        s_req_valid,  // CSR request valid
  output wire        s_req_ready,  // CSR request accept (tied high)
  input  wire        s_req_write,  // 1 = write, 0 = read
  input  wire [15:0] s_req_addr,   // window-relative byte address
  input  wire [31:0] s_req_wdata,  // write data
  input  wire [3:0]  s_req_wstrb,  // byte strobes
  output wire        s_rsp_valid,  // 1-cycle response pulse
  output wire [31:0] s_rsp_rdata,  // read data
  output wire        irq           // level: done & irq_en
);

  localparam [2:0] S_IDLE  = 3'd0;
  localparam [2:0] S_MAX   = 3'd1;
  localparam [2:0] S_EXP   = 3'd2;
  localparam [2:0] S_DIV   = 3'd3;
  localparam [2:0] S_DWAIT = 3'd4;

  reg [2:0]  state;
  reg        done_r;
  reg [6:0]  cfg_n;       // CFG[6:0]
  reg        cfg_irq_en;  // CFG[8]
  reg [6:0]  n_r;         // N latched at start
  reg signed [7:0] maxv;  // running max
  reg [31:0] sum;         // sum of e_i (max 64*65536 < 2^23)
  reg [6:0]  idx;         // element index (pass 1 / exp issue / divide)
  reg [6:0]  cap;         // exp capture index
  reg        iss_done;    // all exp inputs issued

  reg [31:0] scratch [0:63];  // element words
  reg [16:0] e_mem   [0:63];  // Q1.16 exponentials

  integer k;
  initial begin
    for (k = 0; k < 64; k = k + 1) begin
      scratch[k] = 32'd0;
      e_mem[k]   = 17'd0;
    end
  end

  wire busy = (state != S_IDLE);

  // ------------------------------------------------------------------ CSR
  assign s_req_ready = 1'b1;

  wire        csr_wr = s_req_valid & s_req_write;
  wire        csr_rd = s_req_valid & ~s_req_write;
  wire        is_scr = (s_req_addr[15:8] == 8'h01);
  wire        is_lo  = (s_req_addr[15:8] == 8'h00);
  wire [5:0]  scr_ix = s_req_addr[7:2];

  wire start_w = csr_wr & is_lo & (s_req_addr[7:2] == 6'd0) &
                 s_req_wstrb[0] & s_req_wdata[0];
  wire clrd_w  = csr_wr & is_lo & (s_req_addr[7:2] == 6'd0) &
                 s_req_wstrb[0] & s_req_wdata[1];

  reg [31:0] rd_mux;
  always @(*) begin
    rd_mux = 32'd0;
    if (is_scr)
      rd_mux = scratch[scr_ix];
    else if (is_lo) begin
      case (s_req_addr[7:2])
        6'd1:    rd_mux = {30'd0, done_r, busy};
        6'd2:    rd_mux = {23'd0, cfg_irq_en, 1'b0, cfg_n};
        default: rd_mux = 32'd0;
      endcase
    end
  end

  reg        rsp_v;
  reg [31:0] rsp_d;
  always @(posedge clk) begin
    if (!rst_n) begin
      rsp_v <= 1'b0;
      rsp_d <= 32'd0;
    end else begin
      rsp_v <= s_req_valid;
      if (csr_rd)
        rsp_d <= rd_mux;
    end
  end

  assign s_rsp_valid = rsp_v;
  assign s_rsp_rdata = rsp_d;

  // -------------------------------------------------------------- datapath
  wire signed [7:0] x_cur = scratch[idx[5:0]][7:0];
  wire signed [8:0] d_cur = {x_cur[7], x_cur} - {maxv[7], maxv};

  wire        exp_iv = (state == S_EXP) & ~iss_done;
  wire        exp_ov;
  wire [16:0] exp_oe;

  slm_exp_unit u_exp (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (exp_iv),
    .in_d      (d_cur),
    .out_valid (exp_ov),
    .out_e     (exp_oe)
  );

  wire [16:0] e_cur   = e_mem[idx[5:0]];
  wire [24:0] e255    = {e_cur, 8'd0} - {8'd0, e_cur};  // e_i * 255
  wire        div_go  = (state == S_DIV);
  wire        div_busy;
  wire        div_done;
  wire [31:0] div_quot;

  slm_recip_div u_div (
    .clk   (clk),
    .rst_n (rst_n),
    .start (div_go),
    .num   ({7'd0, e255}),
    .den   (sum),
    .busy  (div_busy),
    .done  (div_done),
    .quot  (div_quot)
  );

  // ------------------------------------------------------------------ FSM
  always @(posedge clk) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      done_r     <= 1'b0;
      cfg_n      <= 7'd8;
      cfg_irq_en <= 1'b0;
      n_r        <= 7'd8;
      maxv       <= -8'sd128;
      sum        <= 32'd0;
      idx        <= 7'd0;
      cap        <= 7'd0;
      iss_done   <= 1'b0;
    end else begin
      // CSR writes
      if (csr_wr) begin
        if (is_scr) begin
          if (s_req_wstrb[0]) scratch[scr_ix][7:0]   <= s_req_wdata[7:0];
          if (s_req_wstrb[1]) scratch[scr_ix][15:8]  <= s_req_wdata[15:8];
          if (s_req_wstrb[2]) scratch[scr_ix][23:16] <= s_req_wdata[23:16];
          if (s_req_wstrb[3]) scratch[scr_ix][31:24] <= s_req_wdata[31:24];
        end else if (is_lo && (s_req_addr[7:2] == 6'd2)) begin
          if (s_req_wstrb[0]) cfg_n      <= s_req_wdata[6:0];
          if (s_req_wstrb[1]) cfg_irq_en <= s_req_wdata[8];
        end
        if (clrd_w)
          done_r <= 1'b0;
      end

      case (state)
        S_IDLE: begin
          if (start_w) begin
            state    <= S_MAX;
            n_r      <= cfg_n;
            maxv     <= -8'sd128;
            sum      <= 32'd0;
            idx      <= 7'd0;
            cap      <= 7'd0;
            iss_done <= 1'b0;
            done_r   <= 1'b0;
          end
        end

        S_MAX: begin
          if (x_cur > maxv)
            maxv <= x_cur;
          if (idx == n_r - 7'd1) begin
            idx   <= 7'd0;
            state <= S_EXP;
          end else begin
            idx <= idx + 7'd1;
          end
        end

        S_EXP: begin
          if (!iss_done) begin
            if (idx == n_r - 7'd1)
              iss_done <= 1'b1;
            idx <= idx + 7'd1;
          end
          if (exp_ov) begin
            e_mem[cap[5:0]] <= exp_oe;
            sum             <= sum + {15'd0, exp_oe};
            if (cap == n_r - 7'd1) begin
              state <= S_DIV;
              idx   <= 7'd0;
            end else begin
              cap <= cap + 7'd1;
            end
          end
        end

        S_DIV: begin
          state <= S_DWAIT;
        end

        S_DWAIT: begin
          if (div_done) begin
            // Saturate the probability into the signed-INT8 range: the GEMM
            // array (and the KV path into it) multiplies activations as
            // signed, so an unclamped p_i >= 128 would alias negative and
            // corrupt the attention output (ERRATA A.7).
            scratch[idx[5:0]][7:0] <= (|div_quot[31:7]) ? 8'd127 : div_quot[7:0];
            if (idx == n_r - 7'd1) begin
              state  <= S_IDLE;
              done_r <= 1'b1;
            end else begin
              idx   <= idx + 7'd1;
              state <= S_DIV;
            end
          end
        end

        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

  assign irq = done_r & cfg_irq_en;

  wire _unused = &{1'b0, s_req_addr[1:0], div_busy, div_quot[31:8]};

endmodule

`default_nettype wire
