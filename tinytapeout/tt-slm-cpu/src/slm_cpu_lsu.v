/*
 * slm_cpu_lsu — load/store unit: alignment, sign/zero extension, and the
 * SLB master FSM for the CPU data port.
 *
 * One access at a time: `start` (1-cycle pulse, MEM stage) latches the
 * operation, the FSM then holds req_valid with stable fields until
 * req_ready, waits for the single rsp_valid pulse, registers the
 * lane-selected and extended load data, and pulses `done` for one cycle.
 * funct3 encodes size/sign exactly as in the ISA (lb/lh/lw/lbu/lhu,
 * sb/sh/sw). Byte strobes and write-data lane replication are derived from
 * addr[1:0]. Misaligned accesses do not trap (firmware avoids them —
 * sign-off caveat per SPEC 6.3); the strobes simply follow addr[1:0].
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md sections 3 and 6.3.
 */
`default_nettype none

module slm_cpu_lsu (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  // MEM-stage command
  input  wire        start,        // 1-cycle pulse: begin access
  input  wire        is_write,     // 1 = store, 0 = load
  input  wire [2:0]  funct3,       // size/sign per ISA encoding
  input  wire [31:0] addr,         // byte address
  input  wire [31:0] wdata,        // raw rs2 store value
  output wire        busy,         // access in flight
  output reg         done,         // 1-cycle pulse, load_data valid
  output reg  [31:0] load_data,    // extended load result (registered)
  // SLB master port
  output wire        d_req_valid,  // request valid
  input  wire        d_req_ready,  // slave accepts request
  output wire        d_req_write,  // 1 = write
  output wire [31:0] d_req_addr,   // byte address
  output wire [31:0] d_req_wdata,  // write data (lane-replicated)
  output wire [3:0]  d_req_wstrb,  // byte strobes
  input  wire        d_rsp_valid,  // single response pulse
  input  wire [31:0] d_rsp_rdata  // read data
);

  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_REQ  = 2'd1;
  localparam [1:0] S_WAIT = 2'd2;

  reg [1:0]  state;
  reg        write_r;
  reg [2:0]  funct3_r;
  reg [31:0] addr_r;
  reg [31:0] wdata_r;
  reg [3:0]  wstrb_r;

  // Write lane replication / strobes from size and addr[1:0].
  reg [31:0] wdata_al;
  reg [3:0]  wstrb_al;
  always @(*) begin
    case (funct3[1:0])
      2'b00: begin // sb
        wdata_al = {4{wdata[7:0]}};
        wstrb_al = 4'b0001 << addr[1:0];
      end
      2'b01: begin // sh
        wdata_al = {2{wdata[15:0]}};
        wstrb_al = addr[1] ? 4'b1100 : 4'b0011;
      end
      default: begin // sw
        wdata_al = wdata;
        wstrb_al = 4'b1111;
      end
    endcase
  end

  // Read lane select + extension.
  reg [31:0] rd_ext;
  reg [7:0]  rd_b;
  reg [15:0] rd_h;
  always @(*) begin
    case (addr_r[1:0])
      2'b00:   rd_b = d_rsp_rdata[7:0];
      2'b01:   rd_b = d_rsp_rdata[15:8];
      2'b10:   rd_b = d_rsp_rdata[23:16];
      default: rd_b = d_rsp_rdata[31:24];
    endcase
    rd_h = addr_r[1] ? d_rsp_rdata[31:16] : d_rsp_rdata[15:0];
    case (funct3_r)
      3'b000:  rd_ext = {{24{rd_b[7]}}, rd_b};   // lb
      3'b001:  rd_ext = {{16{rd_h[15]}}, rd_h};  // lh
      3'b100:  rd_ext = {24'b0, rd_b};           // lbu
      3'b101:  rd_ext = {16'b0, rd_h};           // lhu
      default: rd_ext = d_rsp_rdata;             // lw
    endcase
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      write_r   <= 1'b0;
      funct3_r  <= 3'b0;
      addr_r    <= 32'b0;
      wdata_r   <= 32'b0;
      wstrb_r   <= 4'b0;
      done      <= 1'b0;
      load_data <= 32'b0;
    end else begin
      done <= 1'b0;
      case (state)
        S_IDLE: begin
          if (start) begin
            write_r  <= is_write;
            funct3_r <= funct3;
            addr_r   <= addr;
            wdata_r  <= is_write ? wdata_al : 32'b0;
            wstrb_r  <= is_write ? wstrb_al : 4'b0;
            state    <= S_REQ;
          end
        end
        S_REQ: begin
          if (d_req_ready)
            state <= S_WAIT;
        end
        default: begin // S_WAIT
          if (d_rsp_valid) begin
            load_data <= rd_ext;
            done      <= 1'b1;
            state     <= S_IDLE;
          end
        end
      endcase
    end
  end

  assign d_req_valid = (state == S_REQ);
  assign d_req_write = write_r;
  assign d_req_addr  = addr_r;
  assign d_req_wdata = wdata_r;
  assign d_req_wstrb = wstrb_r;
  assign busy        = (state != S_IDLE);

endmodule

`default_nettype wire
