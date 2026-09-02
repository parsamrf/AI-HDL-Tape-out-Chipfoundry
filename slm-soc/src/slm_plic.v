/*
 * slm_plic — PLIC-lite: 8-source interrupt controller, SLB CSR slave.
 *
 * Each source has a rising-edge gateway: the pending bit is set on a 0->1
 * transition of src[i] while that source's gateway is open. A claim (read
 * of CLAIM) returns the lowest pending & enabled source as ID+1 (0 = none),
 * clears its pending bit and closes its gateway; a complete (write of ID+1
 * to CLAIM) reopens the gateway. While a gateway is closed, edges on that
 * source are ignored — level-type sources must be deasserted at the device
 * before completion, then re-pend on their next rising edge.
 * Register map (window-relative, see docs/SPEC.md section 6.7):
 *   0x00 PENDING (R), 0x04 ENABLE (RW b7:0), 0x08 CLAIM/COMPLETE (R/W).
 * meip = |(pending & enable) (level).
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md sections 5 and 6.7.
 */
`default_nettype none

module slm_plic (
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
  // interrupt fabric
  input  wire [7:0]  src,          // interrupt sources (see SPEC section 5)
  output wire        meip          // level: |(pending & enable)
);

  // register word offsets (s_req_addr[15:2])
  localparam [13:0] A_PENDING = 14'd0;
  localparam [13:0] A_ENABLE  = 14'd1;
  localparam [13:0] A_CLAIM   = 14'd2;

  reg [7:0] pending_q;
  reg [7:0] enable_q;
  reg [7:0] gate_open_q;  // 1 = gateway open (reset state)
  reg [7:0] src_prev;

  assign s_req_ready = 1'b1;
  assign meip        = |(pending_q & enable_q);

  wire [7:0] src_rise = src & ~src_prev;

  wire [13:0] csr_word = s_req_addr[15:2];
  wire        csr_wr   = s_req_valid & s_req_write;
  wire        csr_rd   = s_req_valid & ~s_req_write;

  // lowest pending & enabled source, as ID+1 (0 = none)
  integer k;
  reg [3:0] claim_id;
  always @* begin
    claim_id = 4'd0;
    for (k = 7; k >= 0; k = k - 1) begin
      if (pending_q[k] & enable_q[k])
        claim_id = k[3:0] + 4'd1;
    end
  end

  // claim: read of CLAIM with a nonzero claim_id
  wire       do_claim   = csr_rd && (csr_word == A_CLAIM) && (claim_id != 4'd0);
  wire [7:0] claim_mask = do_claim ? (8'h01 << (claim_id - 4'd1)) : 8'h00;

  // complete: write of ID+1 (1..8) to CLAIM
  wire [7:0] comp_val  = s_req_wdata[7:0];
  wire [7:0] comp_m1   = comp_val - 8'd1;
  wire       do_comp   = csr_wr && (csr_word == A_CLAIM) && s_req_wstrb[0] &&
                         (comp_val >= 8'd1) && (comp_val <= 8'd8);
  wire [7:0] comp_mask = do_comp ? (8'h01 << comp_m1[2:0]) : 8'h00;

  // read data mux
  reg [31:0] rd_mux;
  always @* begin
    case (csr_word)
      A_PENDING: rd_mux = {24'h000000, pending_q};
      A_ENABLE:  rd_mux = {24'h000000, enable_q};
      A_CLAIM:   rd_mux = {28'h0000000, claim_id};
      default:   rd_mux = 32'h0000_0000;
    endcase
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      s_rsp_valid <= 1'b0;
      s_rsp_rdata <= 32'h0000_0000;
      pending_q   <= 8'h00;
      enable_q    <= 8'h00;
      gate_open_q <= 8'hFF;
      src_prev    <= 8'h00;
    end else begin
      s_rsp_valid <= s_req_valid;
      s_rsp_rdata <= rd_mux;

      src_prev    <= src;
      // ~claim_mask also masks src_rise: a source edge coincident with its
      // own claim must not re-pend behind the now-closed gateway (it would
      // deliver one duplicate interrupt after complete).
      pending_q   <= (pending_q & ~claim_mask) | (src_rise & gate_open_q & ~claim_mask);
      gate_open_q <= (gate_open_q & ~claim_mask) | comp_mask;

      if (csr_wr && csr_word == A_ENABLE && s_req_wstrb[0])
        enable_q <= s_req_wdata[7:0];
    end
  end

  wire _unused = &{1'b0, s_req_wdata[31:8], s_req_wstrb[3:1], s_req_addr[1:0],
                   comp_m1[7:3]};

endmodule

`default_nettype wire
