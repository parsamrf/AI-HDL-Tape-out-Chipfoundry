module picorv32_pcpi_vec (
    input clk,
    input resetn,

    input        pcpi_valid,
    input [31:0] pcpi_insn,
    input [31:0] pcpi_rs1,
    input [31:0] pcpi_rs2,

    output reg        pcpi_wr,
    output reg [31:0] pcpi_rd,
    output reg        pcpi_wait,
    output reg        pcpi_ready
);

    wire [6:0] opcode = pcpi_insn[6:0];
    wire [2:0] funct3 = pcpi_insn[14:12];
    wire [6:0] funct7 = pcpi_insn[31:25];

    // Use custom-0 opcode: 0001011
    wire is_custom0 = (opcode == 7'b0001011);

    // Simple operation decode
    wire instr_vadd8 = is_custom0 && (funct3 == 3'b000) && (funct7 == 7'b0000000);
    wire instr_vsub8 = is_custom0 && (funct3 == 3'b001) && (funct7 == 7'b0000000);
    wire instr_vand  = is_custom0 && (funct3 == 3'b010) && (funct7 == 7'b0000000);
    wire instr_vor   = is_custom0 && (funct3 == 3'b011) && (funct7 == 7'b0000000);

    wire instr_vec = instr_vadd8 || instr_vsub8 || instr_vand || instr_vor;

    wire [7:0] a0 = pcpi_rs1[7:0];
    wire [7:0] a1 = pcpi_rs1[15:8];
    wire [7:0] a2 = pcpi_rs1[23:16];
    wire [7:0] a3 = pcpi_rs1[31:24];

    wire [7:0] b0 = pcpi_rs2[7:0];
    wire [7:0] b1 = pcpi_rs2[15:8];
    wire [7:0] b2 = pcpi_rs2[23:16];
    wire [7:0] b3 = pcpi_rs2[31:24];

    wire [31:0] result_vadd8 = {
        a3 + b3,
        a2 + b2,
        a1 + b1,
        a0 + b0
    };

    wire [31:0] result_vsub8 = {
        a3 - b3,
        a2 - b2,
        a1 - b1,
        a0 - b0
    };

    wire [31:0] result_vand = pcpi_rs1 & pcpi_rs2;
    wire [31:0] result_vor  = pcpi_rs1 | pcpi_rs2;

    always @(posedge clk) begin
        if (!resetn) begin
            pcpi_wr    <= 0;
            pcpi_rd    <= 0;
            pcpi_wait  <= 0;
            pcpi_ready <= 0;
        end else begin
            pcpi_wr    <= 0;
            pcpi_ready <= 0;
            pcpi_wait  <= 0;

            // !pcpi_ready keeps this a single-cycle response: picorv32 holds
            // pcpi_valid through the ready cycle, so without the gate a second
            // ready/wr pulse fires after valid falls (one-ready-per-request
            // contract violation with any core that pipelines PCPI).
            if (pcpi_valid && instr_vec && !pcpi_ready) begin
                pcpi_wr    <= 1;
                pcpi_ready <= 1;
                pcpi_wait  <= 0;

                if (instr_vadd8)
                    pcpi_rd <= result_vadd8;
                else if (instr_vsub8)
                    pcpi_rd <= result_vsub8;
                else if (instr_vand)
                    pcpi_rd <= result_vand;
                else if (instr_vor)
                    pcpi_rd <= result_vor;
                else
                    pcpi_rd <= 32'h00000000;
            end
        end
    end

endmodule