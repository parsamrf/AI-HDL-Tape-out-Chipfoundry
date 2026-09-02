/*
 * slm_bus_xbar — 1-master / 11-slave SLB crossbar (address decoder).
 *
 * Decode per docs/SPEC.md section 4: addr[31:28] selects the region, then
 * addr[17:16] selects the sub-window inside 0x3xxx_xxxx / 0x4xxx_xxxx.
 * Request fields are broadcast; only the decoded slave sees req_valid.
 * Slaves receive the window-relative byte address addr[15:0]. Response
 * routing tracks the single outstanding target. Unmapped addresses hit an
 * internal default slave that responds 32'hDEADBEEF on the next cycle
 * (writes get a plain response and are dropped).
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md sections 4 and 6.5.
 */
`default_nettype none

module slm_bus_xbar (
  input  wire         clk,              // clock
  input  wire         rst_n,            // synchronous active-low reset
  // upstream master
  input  wire         m_req_valid,      // request valid
  output wire         m_req_ready,      // request accepted this cycle
  input  wire         m_req_write,      // 1 = write, 0 = read
  input  wire [31:0]  m_req_addr,       // byte address
  input  wire [31:0]  m_req_wdata,      // write data
  input  wire [3:0]   m_req_wstrb,      // byte strobes
  output wire         m_rsp_valid,      // response pulse
  output wire [31:0]  m_rsp_rdata,      // read data
  // 11 slaves: broadcast fields + per-slave handshake
  output wire [10:0]  s_req_valid,      // per-slave request valid
  input  wire [10:0]  s_req_ready,      // per-slave request ready
  output wire         s_req_write,      // broadcast write flag
  output wire [15:0]  s_req_addr,       // broadcast window-relative address
  output wire [31:0]  s_req_wdata,      // broadcast write data
  output wire [3:0]   s_req_wstrb,      // broadcast byte strobes
  input  wire [10:0]  s_rsp_valid,      // per-slave response pulse
  input  wire [351:0] s_rsp_rdata_flat  // {slave10, ..., slave0}, 32b each
);

  localparam [31:0] DEF_RDATA = 32'hDEADBEEF;

  // ---------------------------------------------------------------------
  // Address decode (combinational)
  // ---------------------------------------------------------------------
  reg [3:0] dec_idx;  // decoded slave index 0..10
  reg       dec_def;  // 1 = unmapped, use internal default slave

  always @* begin
    dec_idx = 4'd0;
    dec_def = 1'b0;
    case (m_req_addr[31:28])
      4'h0:    dec_idx = 4'd0;                                  // IMEM
      4'h1:    dec_idx = 4'd1;                                  // DMEM
      4'h2:    dec_idx = 4'd2;                                  // KV-cache
      4'h3:    dec_idx = 4'd3 + {2'b00, m_req_addr[17:16]};     // GEMM..DMA
      4'h4:    dec_idx = 4'd7 + {2'b00, m_req_addr[17:16]};     // UART..GPIO
      default: dec_def = 1'b1;                                  // unmapped
    endcase
  end

  // ---------------------------------------------------------------------
  // Outstanding-transaction tracking
  // ---------------------------------------------------------------------
  reg       busy;     // accepted request awaiting response
  reg [3:0] tgt;      // slave index of the outstanding request
  reg       tgt_def;  // outstanding request went to the default slave
  reg       def_rsp;  // default-slave response pulse (next cycle)

  // zero-extended handshake vectors so 4-bit indexing is always in range
  wire [15:0] rdy_ext  = {5'b00000, s_req_ready};
  wire [15:0] rspv_ext = {5'b00000, s_rsp_valid};

  wire sel_ready = dec_def ? 1'b1 : rdy_ext[dec_idx];

  assign m_req_ready = ~busy & sel_ready;
  assign s_req_valid = (m_req_valid && !busy && !dec_def)
                       ? (11'h001 << dec_idx) : 11'h000;
  assign s_req_write = m_req_write;
  assign s_req_addr  = m_req_addr[15:0];
  assign s_req_wdata = m_req_wdata;
  assign s_req_wstrb = m_req_wstrb;

  // response mux
  reg [31:0] tgt_rdata;
  always @* begin
    case (tgt)
      4'd0:    tgt_rdata = s_rsp_rdata_flat[31:0];
      4'd1:    tgt_rdata = s_rsp_rdata_flat[63:32];
      4'd2:    tgt_rdata = s_rsp_rdata_flat[95:64];
      4'd3:    tgt_rdata = s_rsp_rdata_flat[127:96];
      4'd4:    tgt_rdata = s_rsp_rdata_flat[159:128];
      4'd5:    tgt_rdata = s_rsp_rdata_flat[191:160];
      4'd6:    tgt_rdata = s_rsp_rdata_flat[223:192];
      4'd7:    tgt_rdata = s_rsp_rdata_flat[255:224];
      4'd8:    tgt_rdata = s_rsp_rdata_flat[287:256];
      4'd9:    tgt_rdata = s_rsp_rdata_flat[319:288];
      4'd10:   tgt_rdata = s_rsp_rdata_flat[351:320];
      default: tgt_rdata = DEF_RDATA;
    endcase
  end

  wire tgt_rsp = tgt_def ? def_rsp : rspv_ext[tgt];

  assign m_rsp_valid = busy & tgt_rsp;
  assign m_rsp_rdata = tgt_def ? DEF_RDATA : tgt_rdata;

  always @(posedge clk) begin
    if (!rst_n) begin
      busy    <= 1'b0;
      tgt     <= 4'd0;
      tgt_def <= 1'b0;
      def_rsp <= 1'b0;
    end else begin
      def_rsp <= 1'b0;
      if (busy) begin
        if (tgt_rsp)
          busy <= 1'b0;
      end else if (m_req_valid && m_req_ready) begin
        busy    <= 1'b1;
        tgt     <= dec_idx;
        tgt_def <= dec_def;
        if (dec_def)
          def_rsp <= 1'b1;  // default slave responds next cycle
      end
    end
  end

  wire _unused = &{1'b0, m_req_addr[27:18]};

endmodule

`default_nettype wire
