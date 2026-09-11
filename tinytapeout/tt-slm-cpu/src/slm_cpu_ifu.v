/*
 * slm_cpu_ifu — instruction fetch unit: PC, fetch address, redirect.
 *
 * Drives the private 1-cycle synchronous-read instruction port. `if_addr`
 * is the address of the instruction that will occupy the ID slot next
 * cycle: on a stall the current ID instruction address is re-fetched so
 * `if_rdata` stays coherent with `id_pc`; otherwise the next sequential PC
 * is fetched. A redirect (taken branch / jump / trap / mret) kills the ID
 * occupant via `id_valid` and restarts fetch at `redirect_pc` (2-cycle
 * penalty: the IF- and ID-stage instructions in flight are both dropped).
 * `redirect` has priority over `stall`.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.3.
 */
`default_nettype none

module slm_cpu_ifu #(
  parameter RESET_PC = 32'h0000_0000
) (
  input  wire        clk,          // clock
  input  wire        rst_n,        // synchronous active-low reset
  input  wire        stall,        // hold IF and ID
  input  wire        redirect,     // flush and refetch from redirect_pc
  input  wire [31:0] redirect_pc,  // redirect target
  output wire [31:0] if_addr,      // word-aligned fetch address
  output wire [31:0] fetch_pc,     // next sequential fetch PC (mepc fallback)
  output reg  [31:0] id_pc,        // PC of the instruction in ID
  output reg         id_valid     // ID stage holds a real instruction
);

  reg [31:0] pc;

  always @(posedge clk) begin
    if (!rst_n) begin
      pc       <= RESET_PC;
      id_pc    <= RESET_PC;
      id_valid <= 1'b0;
    end else if (redirect) begin
      pc       <= redirect_pc;
      id_valid <= 1'b0;
    end else if (!stall) begin
      id_pc    <= pc;
      id_valid <= 1'b1;
      pc       <= pc + 32'd4;
    end
  end

  // On a stall keep presenting the ID-stage instruction so the synchronous
  // instruction memory keeps if_rdata stable for the held ID slot.
  wire [31:0] fetch_sel = stall ? id_pc : pc;

  assign if_addr  = {fetch_sel[31:2], 2'b00};
  assign fetch_pc = pc;

  wire _unused = &{1'b0, fetch_sel[1:0]};

endmodule

`default_nettype wire
