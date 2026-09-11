/*
 * slm_gemm_ctrl — INT8 weight-stationary systolic GEMM engine, top level.
 *
 * R[m][n] = requant( sum_k A[m][k] * W[k][n] ), A: Mx8 INT8 (M = 1..64),
 * W: 8x8 INT8, INT32 accumulate, requantized to INT8 through the shared
 * slm_requant (SCALE/SHIFT/ZP CSRs). Instantiates slm_gemm_array,
 * slm_gemm_acc, and slm_requant.
 *
 * Register map (window 0x3000_0000, offsets window-relative, SPEC 6.8):
 *   0x0000 CTRL   (W: b0 start, b1 clear_done)
 *   0x0004 STATUS (R: b0 busy, b1 done)
 *   0x0008 CFG    (RW: b0 src_sel 0=local act buffer 1=KV port, b1 irq_en)
 *   0x000C DIMS   (RW: [6:0] M)
 *   0x0010 SCALE  (RW, signed 32)
 *   0x0014 SHIFT  (RW, [4:0])
 *   0x0018 ZP     (RW, signed 8 in [7:0])
 *   0x001C KV_ADDR(RW, byte addr into KV window, word-aligned)
 *   0x0100-0x013C weight buffer, 16 words: word i byte j = W[f/8][f%8],
 *                 f = 4*i+j (row-major k,n)
 *   0x0200-0x03FC activation buffer, 128 words: row m in words {2m, 2m+1},
 *                 byte j = A[m][4*(word&1)+j]
 *   0x0400-0x05FC result buffer, 128 words, same packing (R)
 *
 * FSM: LOAD_W (8 cycles, one weight row per cycle) -> per activation row:
 * FETCH (local buffer, or KV0/KV1 word reads at KV_ADDR + 8*m, +4) -> FEED
 * (8 skewed west-edge injections) -> DRAIN (accumulator capture + requant
 * writeback) -> after M rows, DONE. start while busy is ignored; done is
 * sticky until clear_done; irq = done & irq_en (level).
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md sections 3 and 6.8.
 */
`default_nettype none

module slm_gemm_ctrl (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  // CSR slave port (SLB, window-relative)
  input  wire        s_req_valid,  // request valid
  output wire        s_req_ready,  // request accepted (tied high)
  input  wire        s_req_write,  // 1 = write, 0 = read
  input  wire [15:0] s_req_addr,   // byte address
  input  wire [31:0] s_req_wdata,  // write data
  input  wire [3:0]  s_req_wstrb,  // byte strobes (writes)
  output wire        s_rsp_valid,  // 1-cycle response pulse
  output wire [31:0] s_rsp_rdata,  // read data
  // KV read-port master
  output wire        kv_req_valid, // KV read request valid
  input  wire        kv_req_ready, // KV accepts the request
  output wire [15:0] kv_req_addr,  // byte address into KV space
  input  wire        kv_rsp_valid, // KV read data valid (1 pulse/request)
  input  wire [31:0] kv_rsp_rdata, // KV read data
  output wire        irq           // level interrupt: done & irq_en
);

  // -------------------------------------------------------------------
  // FSM encodings
  // -------------------------------------------------------------------
  localparam [2:0] S_IDLE   = 3'd0;
  localparam [2:0] S_LOAD_W = 3'd1;
  localparam [2:0] S_FETCH  = 3'd2;
  localparam [2:0] S_KV0    = 3'd3;
  localparam [2:0] S_KV1    = 3'd4;
  localparam [2:0] S_FEED   = 3'd5;
  localparam [2:0] S_DRAIN  = 3'd6;
  localparam [2:0] S_DONE   = 3'd7;

  reg [2:0] state;

  // -------------------------------------------------------------------
  // CSRs and buffers
  // -------------------------------------------------------------------
  reg        cfg_src_sel;
  reg        cfg_irq_en;
  reg [6:0]  dims_m;
  reg [31:0] cfg_scale;
  reg [4:0]  cfg_shift;
  reg [7:0]  cfg_zp;
  reg [15:0] kv_base;
  reg        done_r;

  reg [31:0] wbuf [0:15];
  reg [31:0] abuf [0:127];
  reg [31:0] rbuf [0:127];

  integer ib;
  initial begin
    for (ib = 0; ib < 16; ib = ib + 1)
      wbuf[ib] = 32'h0;
    for (ib = 0; ib < 128; ib = ib + 1) begin
      abuf[ib] = 32'h0;
      rbuf[ib] = 32'h0;
    end
  end

  // -------------------------------------------------------------------
  // Sequencing state
  // -------------------------------------------------------------------
  reg [2:0]  wl_cnt;    // weight row being loaded
  reg [6:0]  m_cur;     // current activation row
  reg [2:0]  feed_cnt;  // skewed feed step
  reg [63:0] act_row;   // current row's 8 activation bytes
  reg        kv_issued; // KV request accepted, awaiting response
  reg        acc_clear; // pulse into slm_gemm_acc at start

  wire busy = (state != S_IDLE);

  // -------------------------------------------------------------------
  // CSR decode
  // -------------------------------------------------------------------
  wire sel_regs = (s_req_addr[15:5] == 11'd0);  // 0x0000..0x001F
  wire sel_wbuf = (s_req_addr[15:6] == 10'd4);  // 0x0100..0x013F
  wire sel_abuf = (s_req_addr[15:9] == 7'd1);   // 0x0200..0x03FF
  wire sel_rbuf = (s_req_addr[15:9] == 7'd2);   // 0x0400..0x05FF

  wire start_req = s_req_valid && s_req_write && sel_regs &&
                   (s_req_addr[4:2] == 3'd0) && s_req_wstrb[0] &&
                   s_req_wdata[0];

  reg [31:0] rd_data;
  always @(*) begin
    rd_data = 32'h0;
    if (sel_regs) begin
      case (s_req_addr[4:2])
        3'd1:    rd_data = {30'h0, done_r, busy};
        3'd2:    rd_data = {30'h0, cfg_irq_en, cfg_src_sel};
        3'd3:    rd_data = {25'h0, dims_m};
        3'd4:    rd_data = cfg_scale;
        3'd5:    rd_data = {27'h0, cfg_shift};
        3'd6:    rd_data = {24'h0, cfg_zp};
        3'd7:    rd_data = {16'h0, kv_base};
        default: rd_data = 32'h0;  // CTRL is write-only
      endcase
    end else if (sel_wbuf) begin
      rd_data = wbuf[s_req_addr[5:2]];
    end else if (sel_abuf) begin
      rd_data = abuf[s_req_addr[8:2]];
    end else if (sel_rbuf) begin
      rd_data = rbuf[s_req_addr[8:2]];
    end
  end

  reg        rsp_valid_r;
  reg [31:0] rsp_rdata_r;

  assign s_req_ready = 1'b1;
  assign s_rsp_valid = rsp_valid_r;
  assign s_rsp_rdata = rsp_rdata_r;

  // -------------------------------------------------------------------
  // Datapath instances
  // -------------------------------------------------------------------
  wire [63:0]  w_row_data = {wbuf[{wl_cnt, 1'b1}], wbuf[{wl_cnt, 1'b0}]};
  wire [7:0]   feed_byte  = act_row[{feed_cnt, 3'b000} +: 8];
  wire [7:0]   a_valid_in = (state == S_FEED) ? (8'h01 << feed_cnt) : 8'h00;

  wire [7:0]   col_valid;
  wire [255:0] col_psum_flat;
  wire         rq_in_valid;
  wire [31:0]  rq_in_acc;
  wire         rq_out_valid;
  wire [7:0]   rq_out_q;
  wire         res_valid;
  wire [2:0]   res_col;
  wire [7:0]   res_q;
  wire         row_done;

  slm_gemm_array u_array (
    .clk           (clk),
    .rst_n         (rst_n),
    .w_load        (state == S_LOAD_W),
    .w_row         (wl_cnt),
    .w_in_flat     (w_row_data),
    .a_valid_in    (a_valid_in),
    .a_in_flat     ({8{feed_byte}}),
    .col_valid     (col_valid),
    .col_psum_flat (col_psum_flat)
  );

  slm_gemm_acc u_acc (
    .clk           (clk),
    .rst_n         (rst_n),
    .clear         (acc_clear),
    .col_valid     (col_valid),
    .col_psum_flat (col_psum_flat),
    .rq_in_valid   (rq_in_valid),
    .rq_in_acc     (rq_in_acc),
    .rq_out_valid  (rq_out_valid),
    .rq_out_q      (rq_out_q),
    .res_valid     (res_valid),
    .res_col       (res_col),
    .res_q         (res_q),
    .row_done      (row_done)
  );

  slm_requant u_requant (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (rq_in_valid),
    .in_acc    (rq_in_acc),
    .cfg_scale (cfg_scale),
    .cfg_shift (cfg_shift),
    .cfg_zp    (cfg_zp),
    .out_valid (rq_out_valid),
    .out_q     (rq_out_q)
  );

  // -------------------------------------------------------------------
  // KV read-port master (activation fetch when src_sel = 1)
  // -------------------------------------------------------------------
  assign kv_req_valid = ((state == S_KV0) || (state == S_KV1)) && !kv_issued;
  assign kv_req_addr  = kv_base + {6'd0, m_cur, 3'd0} +
                        ((state == S_KV1) ? 16'd4 : 16'd0);

  assign irq = done_r & cfg_irq_en;

  // -------------------------------------------------------------------
  // Main FSM + CSR write handling
  // -------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      cfg_src_sel <= 1'b0;
      cfg_irq_en  <= 1'b0;
      dims_m      <= 7'd0;
      cfg_scale   <= 32'h0;
      cfg_shift   <= 5'd0;
      cfg_zp      <= 8'h0;
      kv_base     <= 16'h0;
      done_r      <= 1'b0;
      wl_cnt      <= 3'd0;
      m_cur       <= 7'd0;
      feed_cnt    <= 3'd0;
      act_row     <= 64'h0;
      kv_issued   <= 1'b0;
      acc_clear   <= 1'b0;
      rsp_valid_r <= 1'b0;
      rsp_rdata_r <= 32'h0;
    end else begin
      acc_clear <= 1'b0;

      case (state)
        S_IDLE: begin
          if (start_req) begin
            state     <= S_LOAD_W;
            wl_cnt    <= 3'd0;
            m_cur     <= 7'd0;
            acc_clear <= 1'b1;
          end
        end
        S_LOAD_W: begin
          wl_cnt <= wl_cnt + 3'd1;
          if (wl_cnt == 3'd7)
            state <= (dims_m == 7'd0) ? S_DONE : S_FETCH;
        end
        S_FETCH: begin
          if (!cfg_src_sel) begin
            act_row  <= {abuf[{m_cur[5:0], 1'b1}], abuf[{m_cur[5:0], 1'b0}]};
            feed_cnt <= 3'd0;
            state    <= S_FEED;
          end else begin
            kv_issued <= 1'b0;
            state     <= S_KV0;
          end
        end
        S_KV0: begin
          if (kv_req_valid && kv_req_ready)
            kv_issued <= 1'b1;
          if (kv_rsp_valid) begin
            act_row[31:0] <= kv_rsp_rdata;
            kv_issued     <= 1'b0;
            state         <= S_KV1;
          end
        end
        S_KV1: begin
          if (kv_req_valid && kv_req_ready)
            kv_issued <= 1'b1;
          if (kv_rsp_valid) begin
            act_row[63:32] <= kv_rsp_rdata;
            kv_issued      <= 1'b0;
            feed_cnt       <= 3'd0;
            state          <= S_FEED;
          end
        end
        S_FEED: begin
          feed_cnt <= feed_cnt + 3'd1;
          if (feed_cnt == 3'd7)
            state <= S_DRAIN;
        end
        S_DRAIN: begin
          if (row_done) begin
            m_cur <= m_cur + 7'd1;
            if (m_cur + 7'd1 == dims_m)
              state <= S_DONE;
            else
              state <= S_FETCH;
          end
        end
        S_DONE: begin
          done_r <= 1'b1;
          state  <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase

      // requantized result byte writeback into the result buffer
      if (res_valid) begin
        case (res_col[1:0])
          2'd0:    rbuf[{m_cur[5:0], res_col[2]}][7:0]   <= res_q;
          2'd1:    rbuf[{m_cur[5:0], res_col[2]}][15:8]  <= res_q;
          2'd2:    rbuf[{m_cur[5:0], res_col[2]}][23:16] <= res_q;
          default: rbuf[{m_cur[5:0], res_col[2]}][31:24] <= res_q;
        endcase
      end

      // CSR responses: every accepted request answers next cycle
      rsp_valid_r <= s_req_valid;
      rsp_rdata_r <= (s_req_valid && !s_req_write) ? rd_data : 32'h0;

      // CSR / buffer writes (start handled in the FSM above; while busy it
      // is ignored because only S_IDLE looks at start_req)
      if (s_req_valid && s_req_write) begin
        if (sel_regs) begin
          case (s_req_addr[4:2])
            3'd0: begin
              if (s_req_wstrb[0] && s_req_wdata[1])
                done_r <= 1'b0;  // clear_done
            end
            3'd2: begin
              if (s_req_wstrb[0]) begin
                cfg_src_sel <= s_req_wdata[0];
                cfg_irq_en  <= s_req_wdata[1];
              end
            end
            3'd3: begin
              if (s_req_wstrb[0])
                dims_m <= s_req_wdata[6:0];
            end
            3'd4: begin
              if (s_req_wstrb[0]) cfg_scale[7:0]   <= s_req_wdata[7:0];
              if (s_req_wstrb[1]) cfg_scale[15:8]  <= s_req_wdata[15:8];
              if (s_req_wstrb[2]) cfg_scale[23:16] <= s_req_wdata[23:16];
              if (s_req_wstrb[3]) cfg_scale[31:24] <= s_req_wdata[31:24];
            end
            3'd5: begin
              if (s_req_wstrb[0])
                cfg_shift <= s_req_wdata[4:0];
            end
            3'd6: begin
              if (s_req_wstrb[0])
                cfg_zp <= s_req_wdata[7:0];
            end
            3'd7: begin
              if (s_req_wstrb[0]) kv_base[7:0]  <= s_req_wdata[7:0];
              if (s_req_wstrb[1]) kv_base[15:8] <= s_req_wdata[15:8];
            end
            default: ;
          endcase
        end else if (sel_wbuf) begin
          if (s_req_wstrb[0]) wbuf[s_req_addr[5:2]][7:0]   <= s_req_wdata[7:0];
          if (s_req_wstrb[1]) wbuf[s_req_addr[5:2]][15:8]  <= s_req_wdata[15:8];
          if (s_req_wstrb[2]) wbuf[s_req_addr[5:2]][23:16] <= s_req_wdata[23:16];
          if (s_req_wstrb[3]) wbuf[s_req_addr[5:2]][31:24] <= s_req_wdata[31:24];
        end else if (sel_abuf) begin
          if (s_req_wstrb[0]) abuf[s_req_addr[8:2]][7:0]   <= s_req_wdata[7:0];
          if (s_req_wstrb[1]) abuf[s_req_addr[8:2]][15:8]  <= s_req_wdata[15:8];
          if (s_req_wstrb[2]) abuf[s_req_addr[8:2]][23:16] <= s_req_wdata[23:16];
          if (s_req_wstrb[3]) abuf[s_req_addr[8:2]][31:24] <= s_req_wdata[31:24];
        end
      end
    end
  end

  wire _unused = &{1'b0, s_req_addr[1:0]};

endmodule

`default_nettype wire
