`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: University of Arizona
// Engineer: Tristan Palma
// 
// Create Date: 04/26/2026 
// Design Name: Bit Manipulation Instructions Unit
// Module Name: Top Level
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision: A
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module toplevel (
    input wire clk,
    input wire resetn,
    output wire        trap,
    output wire        mem_valid,
    output wire        mem_instr,
    input  wire        mem_ready,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [ 3:0] mem_wstrb,
    input  wire [31:0] mem_rdata
);

    // PCPI Bus Wires
    wire        pcpi_valid;
    wire [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
    wire        pcpi_ready, pcpi_wr, pcpi_wait;
    wire [31:0] pcpi_rd;

    // Instantiate CPU
    picorv32 #(
        .ENABLE_PCPI(1) // CRITICAL: This must be 1 to enable BMU
    ) cpu (
        .clk(clk),
        .resetn(resetn),
        // a halted CPU (illegal instruction / ebreak) must be visible
        // off-chip; irq tied low so the unused input is not an X source
        // in gate-level sim
        .trap(trap),
        .irq(32'b0),

        // Memory Interface Connections
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),

        // PCPI Connections
        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),
        .pcpi_ready(pcpi_ready), 
        .pcpi_wr(pcpi_wr),
        .pcpi_wait(pcpi_wait),
        .pcpi_rd(pcpi_rd)
    );

    // Instantiate BMU
    bmu_pcpi_wrapper bmu_inst (
        .clk(clk),
        .resetn(resetn),
        .pcpi_valid(pcpi_valid),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),
        .pcpi_ready(pcpi_ready),
        .pcpi_wr(pcpi_wr), 
        .pcpi_wait(pcpi_wait),
        .pcpi_rd(pcpi_rd)
    );

endmodule
