/*
 * slm_cpu_decode — combinational RV32IM + Zicsr instruction decoder.
 *
 * Produces register indices, sign-extended immediate, ALU control, and
 * one-hot instruction class flags for the ID stage. Unrecognized opcodes
 * and reserved funct3/funct7 combinations raise `illegal` (mcause 2).
 * fence / fence.i decode as architectural NOPs (all class flags low).
 * For CSR instructions the CSR address travels in imm[11:0] (I-type imm).
 *
 * Author: ChipSage Labs (AI-assisted design for Kevin Gubbi <kevin@chipsagelabs.ai>)
 * Part of slm-soc. See docs/SPEC.md section 6.3.
 */
`default_nettype none

module slm_cpu_decode (
  input  wire [31:0] instr,        // instruction word
  output wire [4:0]  rs1,          // source register 1 index
  output wire [4:0]  rs2,          // source register 2 index
  output wire [4:0]  rd,           // destination register index
  output wire [2:0]  funct3,       // funct3 field
  output reg  [31:0] imm,          // sign-extended immediate
  output reg  [3:0]  alu_op,       // ALU operation (slm_cpu_alu encoding)
  output reg         alu_a_pc,     // 1: ALU operand A = PC (else rs1)
  output reg         alu_b_imm,    // 1: ALU operand B = imm (else rs2)
  output reg         is_lui,       // LUI
  output reg         is_jal,       // JAL
  output reg         is_jalr,      // JALR
  output reg         is_branch,    // conditional branch
  output reg         is_load,      // load
  output reg         is_store,     // store
  output reg         is_muldiv,    // M-extension op (unit op = funct3)
  output reg         is_csr,       // CSR read/modify/write
  output reg         csr_use_imm,  // CSR immediate (zimm) form
  output reg         csr_wen,      // CSR write actually performed
  output reg         is_ecall,     // ECALL
  output reg         is_ebreak,    // EBREAK
  output reg         is_mret,      // MRET
  output reg         is_wfi,       // WFI
  output reg         writes_rd,    // instruction writes rd
  output reg         uses_rs1,     // instruction reads rs1
  output reg         uses_rs2,     // instruction reads rs2
  output reg         illegal      // illegal instruction
);

  wire [6:0] opcode = instr[6:0];
  wire [6:0] funct7 = instr[31:25];

  assign rs1    = instr[19:15];
  assign rs2    = instr[24:20];
  assign rd     = instr[11:7];
  assign funct3 = instr[14:12];

  // Immediate formats.
  wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
  wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7],
                       instr[30:25], instr[11:8], 1'b0};
  wire [31:0] imm_u = {instr[31:12], 12'b0};
  wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
                       instr[20], instr[30:21], 1'b0};

  // funct3 -> ALU op for OP/OP-IMM (sub_sra selects SUB / SRA variants).
  function [3:0] f3_alu;
    input [2:0] f3;
    input       sub_sra;
    begin
      case (f3)
        3'b000:  f3_alu = sub_sra ? 4'd1 : 4'd0; // ADD / SUB
        3'b001:  f3_alu = 4'd2;                  // SLL
        3'b010:  f3_alu = 4'd3;                  // SLT
        3'b011:  f3_alu = 4'd4;                  // SLTU
        3'b100:  f3_alu = 4'd5;                  // XOR
        3'b101:  f3_alu = sub_sra ? 4'd7 : 4'd6; // SRL / SRA
        3'b110:  f3_alu = 4'd8;                  // OR
        default: f3_alu = 4'd9;                  // AND
      endcase
    end
  endfunction

  always @(*) begin
    imm         = imm_i;
    alu_op      = 4'd0;
    alu_a_pc    = 1'b0;
    alu_b_imm   = 1'b0;
    is_lui      = 1'b0;
    is_jal      = 1'b0;
    is_jalr     = 1'b0;
    is_branch   = 1'b0;
    is_load     = 1'b0;
    is_store    = 1'b0;
    is_muldiv   = 1'b0;
    is_csr      = 1'b0;
    csr_use_imm = 1'b0;
    csr_wen     = 1'b0;
    is_ecall    = 1'b0;
    is_ebreak   = 1'b0;
    is_mret     = 1'b0;
    is_wfi      = 1'b0;
    writes_rd   = 1'b0;
    uses_rs1    = 1'b0;
    uses_rs2    = 1'b0;
    illegal     = 1'b0;

    case (opcode)
      7'b0110111: begin // LUI
        imm       = imm_u;
        is_lui    = 1'b1;
        writes_rd = 1'b1;
      end

      7'b0010111: begin // AUIPC: result = pc + imm_u via ALU
        imm       = imm_u;
        alu_a_pc  = 1'b1;
        alu_b_imm = 1'b1;
        writes_rd = 1'b1;
      end

      7'b1101111: begin // JAL
        imm       = imm_j;
        is_jal    = 1'b1;
        writes_rd = 1'b1;
      end

      7'b1100111: begin // JALR: target = (rs1 + imm) & ~1 via ALU
        imm       = imm_i;
        alu_b_imm = 1'b1;
        is_jalr   = 1'b1;
        writes_rd = 1'b1;
        uses_rs1  = 1'b1;
        if (funct3 != 3'b000)
          illegal = 1'b1;
      end

      7'b1100011: begin // BEQ/BNE/BLT/BGE/BLTU/BGEU
        imm       = imm_b;
        is_branch = 1'b1;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
        if ((funct3 == 3'b010) || (funct3 == 3'b011))
          illegal = 1'b1;
      end

      7'b0000011: begin // LB/LH/LW/LBU/LHU
        imm       = imm_i;
        alu_b_imm = 1'b1;
        is_load   = 1'b1;
        writes_rd = 1'b1;
        uses_rs1  = 1'b1;
        if ((funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111))
          illegal = 1'b1;
      end

      7'b0100011: begin // SB/SH/SW
        imm       = imm_s;
        alu_b_imm = 1'b1;
        is_store  = 1'b1;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
        if (funct3 > 3'b010)
          illegal = 1'b1;
      end

      7'b0010011: begin // OP-IMM
        imm       = imm_i;
        alu_b_imm = 1'b1;
        writes_rd = 1'b1;
        uses_rs1  = 1'b1;
        alu_op    = f3_alu(funct3, (funct3 == 3'b101) && funct7[5]);
        if ((funct3 == 3'b001) && (funct7 != 7'b0000000))
          illegal = 1'b1;
        if ((funct3 == 3'b101) &&
            (funct7 != 7'b0000000) && (funct7 != 7'b0100000))
          illegal = 1'b1;
      end

      7'b0110011: begin // OP
        writes_rd = 1'b1;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
        if (funct7 == 7'b0000001) begin
          is_muldiv = 1'b1;               // unit op = funct3
        end else if (funct7 == 7'b0000000) begin
          alu_op = f3_alu(funct3, 1'b0);
        end else if ((funct7 == 7'b0100000) &&
                     ((funct3 == 3'b000) || (funct3 == 3'b101))) begin
          alu_op = f3_alu(funct3, 1'b1);
        end else begin
          illegal = 1'b1;
        end
      end

      7'b0001111: begin // MISC-MEM: fence / fence.i as NOPs
        if ((funct3 != 3'b000) && (funct3 != 3'b001))
          illegal = 1'b1;
      end

      7'b1110011: begin // SYSTEM
        if (funct3 == 3'b000) begin
          case (instr)
            32'h0000_0073: is_ecall  = 1'b1;
            32'h0010_0073: is_ebreak = 1'b1;
            32'h3020_0073: is_mret   = 1'b1;
            32'h1050_0073: is_wfi    = 1'b1;
            default:       illegal   = 1'b1;
          endcase
        end else if (funct3 == 3'b100) begin
          illegal = 1'b1;
        end else begin
          imm         = imm_i;            // CSR address in imm[11:0]
          is_csr      = 1'b1;
          writes_rd   = 1'b1;
          csr_use_imm = funct3[2];
          uses_rs1    = ~funct3[2];
          // csrrw/csrrwi always write; csrrs/c[i] write iff rs1/zimm != 0.
          csr_wen     = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);
        end
      end

      default: begin
        illegal = 1'b1;
      end
    endcase
  end

endmodule

`default_nettype wire
