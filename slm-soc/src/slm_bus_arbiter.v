/*
 * slm_bus_arbiter — 2-master SLB arbiter with fixed priority.
 *
 * Master 0 (CPU LSU) has strict priority over master 1 (DMA) when both
 * present a request in the same idle cycle. Once a request has been
 * accepted downstream the arbiter locks to the granted master until the
 * single outstanding response (s_rsp_valid) returns; the other master is
 * back-pressured via its req_ready. A grant that is presented downstream
 * but not yet accepted (ready back-pressure) is latched, so the request
 * fields presented to the slave stay stable per the SLB rules even if the
 * higher-priority master arrives mid-wait.
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.4.
 */
`default_nettype none

module slm_bus_arbiter (
  input  wire        clk,           // clock
  input  wire        rst_n,         // synchronous active-low reset
  // master 0 (CPU) — higher priority
  input  wire        m0_req_valid,  // M0 request valid
  output wire        m0_req_ready,  // M0 request accepted this cycle
  input  wire        m0_req_write,  // M0 1 = write, 0 = read
  input  wire [31:0] m0_req_addr,   // M0 byte address
  input  wire [31:0] m0_req_wdata,  // M0 write data
  input  wire [3:0]  m0_req_wstrb,  // M0 byte strobes
  output wire        m0_rsp_valid,  // M0 response pulse
  output wire [31:0] m0_rsp_rdata,  // M0 read data
  // master 1 (DMA)
  input  wire        m1_req_valid,  // M1 request valid
  output wire        m1_req_ready,  // M1 request accepted this cycle
  input  wire        m1_req_write,  // M1 1 = write, 0 = read
  input  wire [31:0] m1_req_addr,   // M1 byte address
  input  wire [31:0] m1_req_wdata,  // M1 write data
  input  wire [3:0]  m1_req_wstrb,  // M1 byte strobes
  output wire        m1_rsp_valid,  // M1 response pulse
  output wire [31:0] m1_rsp_rdata,  // M1 read data
  // downstream (to xbar)
  output wire        s_req_valid,   // downstream request valid
  input  wire        s_req_ready,   // downstream request accepted
  output wire        s_req_write,   // downstream write flag
  output wire [31:0] s_req_addr,    // downstream byte address
  output wire [31:0] s_req_wdata,   // downstream write data
  output wire [3:0]  s_req_wstrb,   // downstream byte strobes
  input  wire        s_rsp_valid,   // downstream response pulse
  input  wire [31:0] s_rsp_rdata    // downstream read data
);

  // arbitration / lock state
  reg busy;      // request accepted downstream, awaiting rsp_valid
  reg owner;     // master owning the outstanding transaction (0 = M0)
  reg held;      // grant presented but not yet accepted: hold selection
  reg held_sel;  // latched grant selection while held

  // current grant selection: latched grant wins, else fixed priority M0 > M1
  wire cur_sel   = held ? held_sel : (m0_req_valid ? 1'b0 : 1'b1);
  wire cur_valid = cur_sel ? m1_req_valid : m0_req_valid;

  // downstream request mux (blocked while a transaction is outstanding)
  assign s_req_valid = cur_valid & ~busy;
  assign s_req_write = cur_sel ? m1_req_write : m0_req_write;
  assign s_req_addr  = cur_sel ? m1_req_addr  : m0_req_addr;
  assign s_req_wdata = cur_sel ? m1_req_wdata : m0_req_wdata;
  assign s_req_wstrb = cur_sel ? m1_req_wstrb : m0_req_wstrb;

  assign m0_req_ready = ~busy & ~cur_sel & s_req_ready;
  assign m1_req_ready = ~busy &  cur_sel & s_req_ready;

  // response routing to the locked owner
  assign m0_rsp_valid = s_rsp_valid & busy & ~owner;
  assign m1_rsp_valid = s_rsp_valid & busy &  owner;
  assign m0_rsp_rdata = s_rsp_rdata;
  assign m1_rsp_rdata = s_rsp_rdata;

  always @(posedge clk) begin
    if (!rst_n) begin
      busy     <= 1'b0;
      owner    <= 1'b0;
      held     <= 1'b0;
      held_sel <= 1'b0;
    end else begin
      if (busy) begin
        if (s_rsp_valid)
          busy <= 1'b0;
      end else if (s_req_valid) begin
        if (s_req_ready) begin
          busy  <= 1'b1;
          owner <= cur_sel;
          held  <= 1'b0;
        end else begin
          held     <= 1'b1;
          held_sel <= cur_sel;
        end
      end
    end
  end

endmodule

`default_nettype wire
