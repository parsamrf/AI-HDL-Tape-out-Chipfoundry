`timescale 1 ns / 1 ps

module bmi_pcpi (
    input         clk,
    input         resetn,

    input         pcpi_valid,
    input  [31:0] pcpi_insn,
    input  [31:0] pcpi_rs1,
    input  [31:0] pcpi_rs2,

    output        pcpi_wr,
    output [31:0] pcpi_rd,
    output        pcpi_wait,
    output        pcpi_ready
);

    // Use RISC-V custom-0 opcode: 0001011 = 7'h0b.
    // funct3 selects the BMI operation used by bmi_unit.
    wire [2:0] bmi_op = pcpi_insn[14:12];
    // Claim only implemented encodings (funct3 000-101, funct7 0): reserved
    // custom-0 encodings must trap in the CPU, not silently write 0 to rd.
    wire is_custom0 = (pcpi_insn[6:0] == 7'b0001011) &&
                      (pcpi_insn[31:25] == 7'b0000000) &&
                      (bmi_op <= 3'b101);

    wire [31:0] bmi_result;

    bmi_unit #(
        .WIDTH(32)
    ) bmi_core (
        .rs1(pcpi_rs1),
        .rs2(pcpi_rs2),
        .op(bmi_op),
        .result(bmi_result)
    );

    // Combinational one-cycle PCPI response.
    // If instruction is not ours, leave ready low so PicoRV32 handles it normally.
    assign pcpi_wr    = pcpi_valid && is_custom0;
    assign pcpi_rd    = bmi_result;
    assign pcpi_wait  = 1'b0;
    assign pcpi_ready = pcpi_valid && is_custom0;

endmodule
