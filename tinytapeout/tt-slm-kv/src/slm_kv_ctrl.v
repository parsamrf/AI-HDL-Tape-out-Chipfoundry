/*
 * slm_kv_ctrl — banked KV-cache controller (4 x slm_kv_bank, word-interleaved).
 *
 * Bank select = addr[3:2]; in-bank word address = addr[AW+3:4] (AW sized by
 * BANK_WORDS). Two requestor ports share the banks:
 *   - port 0: SLB CSR-style slave, read/write with byte strobes
 *   - port 1: GEMM read-only port
 * Per-bank fixed priority SLB > GEMM. Each port runs a small registered
 * 3-state flow (IDLE -> GRANT -> RESP): arbitration is evaluated while the
 * port is IDLE, the grant is registered, req_ready is asserted for exactly
 * the GRANT cycle (the bank access cycle), and rsp_valid pulses for the RESP
 * cycle. The losing requestor is simply not granted (its req_ready stays low)
 * and re-arbitrates the next cycle, at which point the winner is no longer
 * competing — so the GEMM port waits at most one extra cycle per conflict and
 * the design is deadlock- and starvation-free. req_ready/rsp_valid are pure
 * functions of registered state: no combinational valid/ready loops.
 *
 * Caveats: addr bits [1:0] are ignored (word access within a bank; byte lanes
 * come from wstrb); addr bits above AW+3 are ignored (space aliases). Requires
 * BANK_WORDS <= 2048 so the in-bank word select fits the 16-bit slave address.
 * Read data of a write response is don't-care per the SLB contract.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.11.
 */
`default_nettype none

module slm_kv_ctrl #(
  parameter BANK_WORDS = 512
) (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  // port 0: SLB CSR-style slave (read/write)
  input  wire        s_req_valid,  // request valid
  output wire        s_req_ready,  // request accepted this cycle
  input  wire        s_req_write,  // 1 = write
  input  wire [15:0] s_req_addr,   // byte address (window-relative)
  input  wire [31:0] s_req_wdata,  // write data
  input  wire [3:0]  s_req_wstrb,  // byte strobes (writes)
  output wire        s_rsp_valid,  // 1-cycle response pulse
  output wire [31:0] s_rsp_rdata,  // read data
  // port 1: GEMM read-only
  input  wire        g_req_valid,  // request valid
  output wire        g_req_ready,  // request accepted this cycle
  input  wire [15:0] g_req_addr,   // byte address into KV space
  output wire        g_rsp_valid,  // 1-cycle response pulse
  output wire [31:0] g_rsp_rdata   // read data
);

  function integer clog2f;
    input integer value;
    integer v;
    begin
      v = value - 1;
      for (clog2f = 0; v > 0; clog2f = clog2f + 1)
        v = v >> 1;
    end
  endfunction

  localparam AW = clog2f(BANK_WORDS);

  // per-port flow states
  localparam [1:0] P_IDLE  = 2'd0;
  localparam [1:0] P_GRANT = 2'd1;
  localparam [1:0] P_RESP  = 2'd2;

  reg [1:0]    s_st;
  reg [1:0]    g_st;
  reg [1:0]    s_bank_q;
  reg [1:0]    g_bank_q;
  reg [AW-1:0] s_word_q;
  reg [AW-1:0] g_word_q;
  reg [31:0]   s_wdata_q;
  reg [3:0]    s_we_q;

  wire [1:0] s_bank_w = s_req_addr[3:2];
  wire [1:0] g_bank_w = g_req_addr[3:2];

  wire s_want    = (s_st == P_IDLE) && s_req_valid;
  wire g_want    = (g_st == P_IDLE) && g_req_valid;
  wire g_blocked = s_want && (s_bank_w == g_bank_w);  // fixed priority SLB > GEMM

  always @(posedge clk) begin
    if (!rst_n) begin
      s_st      <= P_IDLE;
      g_st      <= P_IDLE;
      s_bank_q  <= 2'd0;
      g_bank_q  <= 2'd0;
      s_word_q  <= {AW{1'b0}};
      g_word_q  <= {AW{1'b0}};
      s_wdata_q <= 32'h0;
      s_we_q    <= 4'h0;
    end else begin
      case (s_st)
        P_IDLE: begin
          if (s_want) begin
            s_st      <= P_GRANT;
            s_bank_q  <= s_bank_w;
            s_word_q  <= s_req_addr[AW+3:4];
            s_wdata_q <= s_req_wdata;
            s_we_q    <= s_req_write ? s_req_wstrb : 4'h0;
          end
        end
        P_GRANT: s_st <= P_RESP;
        default: s_st <= P_IDLE;
      endcase
      case (g_st)
        P_IDLE: begin
          if (g_want && !g_blocked) begin
            g_st     <= P_GRANT;
            g_bank_q <= g_bank_w;
            g_word_q <= g_req_addr[AW+3:4];
          end
        end
        P_GRANT: g_st <= P_RESP;
        default: g_st <= P_IDLE;
      endcase
    end
  end

  wire s_act = (s_st == P_GRANT);
  wire g_act = (g_st == P_GRANT);

  assign s_req_ready = s_act;
  assign g_req_ready = g_act;
  assign s_rsp_valid = (s_st == P_RESP);
  assign g_rsp_valid = (g_st == P_RESP);

  // bank instances — one access per bank per cycle; grants can never collide
  // on the same bank in the same cycle (see arbitration note above)
  wire [31:0] rdata0;
  wire [31:0] rdata1;
  wire [31:0] rdata2;
  wire [31:0] rdata3;

  wire ssel0 = s_act && (s_bank_q == 2'd0);
  wire ssel1 = s_act && (s_bank_q == 2'd1);
  wire ssel2 = s_act && (s_bank_q == 2'd2);
  wire ssel3 = s_act && (s_bank_q == 2'd3);
  wire gsel0 = g_act && (g_bank_q == 2'd0);
  wire gsel1 = g_act && (g_bank_q == 2'd1);
  wire gsel2 = g_act && (g_bank_q == 2'd2);
  wire gsel3 = g_act && (g_bank_q == 2'd3);

  slm_kv_bank #(.WORDS(BANK_WORDS), .AW(AW)) u_bank0 (
    .clk   (clk),
    .en    (ssel0 | gsel0),
    .we    (ssel0 ? s_we_q : 4'h0),
    .addr  (ssel0 ? s_word_q : g_word_q),
    .wdata (s_wdata_q),
    .rdata (rdata0)
  );

  slm_kv_bank #(.WORDS(BANK_WORDS), .AW(AW)) u_bank1 (
    .clk   (clk),
    .en    (ssel1 | gsel1),
    .we    (ssel1 ? s_we_q : 4'h0),
    .addr  (ssel1 ? s_word_q : g_word_q),
    .wdata (s_wdata_q),
    .rdata (rdata1)
  );

  slm_kv_bank #(.WORDS(BANK_WORDS), .AW(AW)) u_bank2 (
    .clk   (clk),
    .en    (ssel2 | gsel2),
    .we    (ssel2 ? s_we_q : 4'h0),
    .addr  (ssel2 ? s_word_q : g_word_q),
    .wdata (s_wdata_q),
    .rdata (rdata2)
  );

  slm_kv_bank #(.WORDS(BANK_WORDS), .AW(AW)) u_bank3 (
    .clk   (clk),
    .en    (ssel3 | gsel3),
    .we    (ssel3 ? s_we_q : 4'h0),
    .addr  (ssel3 ? s_word_q : g_word_q),
    .wdata (s_wdata_q),
    .rdata (rdata3)
  );

  // response data muxes (bank select registered at grant time)
  reg [31:0] s_rmux;
  reg [31:0] g_rmux;

  always @(*) begin
    case (s_bank_q)
      2'd0:    s_rmux = rdata0;
      2'd1:    s_rmux = rdata1;
      2'd2:    s_rmux = rdata2;
      default: s_rmux = rdata3;
    endcase
    case (g_bank_q)
      2'd0:    g_rmux = rdata0;
      2'd1:    g_rmux = rdata1;
      2'd2:    g_rmux = rdata2;
      default: g_rmux = rdata3;
    endcase
  end

  assign s_rsp_rdata = s_rmux;
  assign g_rsp_rdata = g_rmux;

  wire _unused = &{1'b0,
                   s_req_addr[15:AW+4],
                   s_req_addr[1:0],
                   g_req_addr[15:AW+4],
                   g_req_addr[1:0]};

endmodule

`default_nettype wire
