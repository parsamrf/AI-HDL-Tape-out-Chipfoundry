/* --------------------------------------------------------------------------------------------
                         ECE507 - Digital VLSI Design
						 
			                     Project Work
								     by
			                Chakravarthy Anbazhagan
				              (chakra@arizona.edu)
				 
     Pipelined High-Performance Bit-Slice Vector Processor Extension to picorv32 CPU core
	 Developed using SiliconCompiler VLSI Design Software, Verilog-Synthesis & Simulation 
	 and related RISC-V ecosystem tools
				 
     Our design implements 4×8bit SIMD vector operations on 32bit registers.
                 The vector processor supports the following vector instructions:
                       Vector addition operations :  
                             VADD8, VSUB8, VAND8, VOR8, VXOR8
                             VSADD8 (saturating add)
                       Vector multiply operations : 
                             VMUL8 (8×8→8, low byte)
                       Vector dot product operations : 				 
                             VDOT8 (4×8‑bit dot product → 32‑bit scalar)
							 
     Our design uses a multicycle, pipelined PCPI interface with pcpi_wait/pcpi_ready interface protocol.

     Instruction set and encoding :
          We use RISCV custom-0 opcode and a dedicated funct7 to mark vector ops:
              opcode = 7'b0001011 (custom-0)
              funct7 = 7'b0000001 → “vector instruction”
              funct3 selects the operation:
              funct3	Mnemonic	 Description
                000	      VADD8	   lane-wise 8-bit add
                001	      VSUB8	   lane-wise 8-bit sub
                010	      VAND8	   lane-wise 8-bit AND
                011	      VOR8	   lane-wise 8-bit OR
                100	      VXOR8	   lane-wise 8-bit XOR
                101	      VSADD8   lane-wise 8-bit saturating add
                110	      VMUL8	   lane‑wise 8×8→8 (low 8 bits)
                111	      VDOT8	   4×8‑bit dot product → 32‑bit scalar

          Lane layout in a 32-bit register:
                Lane 0: bits [7:0]
                Lane 1: bits [15:8]
                Lane 2: bits [23:16]
                Lane 3: bits [31:24]				
	 
----------------------------------------------------------------------------------------------*/

// our pipelined, vector processor module
module pcpi_vec_proc(
    input         clk,
    input         resetn,

    // from picoRV32
    input         pcpi_valid,
    input  [31:0] pcpi_insn,
    input  [31:0] pcpi_rs1,
    input  [31:0] pcpi_rs2,

    // to picoRV32
    output reg        pcpi_wr,
    output reg [31:0] pcpi_rd,
    output reg        pcpi_wait,
    output reg        pcpi_ready
);

    // decode the instn fields
    wire [6:0]  opcode = pcpi_insn[6:0];
    wire [2:0]  funct3 = pcpi_insn[14:12];
    wire [6:0]  funct7 = pcpi_insn[31:25];

    // we use the custom function encoding bits as follows :
    localparam OPC_CUSTOM0  = 7'b0001011;
    localparam FUNCT7_VEC   = 7'b0000001;
    // we define and implement the following vector operations 
    localparam VOP_ADD  = 3'b000;  // vector Add
    localparam VOP_SUB  = 3'b001;  // vector Subtract
    localparam VOP_AND  = 3'b010;  // vector AND
    localparam VOP_OR   = 3'b011;  // vector OR
    localparam VOP_XOR  = 3'b100;  // vector XOR
    localparam VOP_SADD = 3'b101;  // vector Saturated Addition
    localparam VOP_MUL  = 3'b110;  // vector Multiply
    localparam VOP_DOT  = 3'b111;  // vector Dot Product 

    // to flag if a vector instn is encountered
    wire is_vec_insn =
        (opcode == OPC_CUSTOM0) &&
        (funct7 == FUNCT7_VEC) &&
        (funct3 <= VOP_DOT);

    // Finite-State Machine States
    localparam STATE_IDLE  = 4'd0;
    localparam STATE_EXEC1 = 4'd1; // lanes 0–1 for simple ops
    localparam STATE_EXEC2 = 4'd2; // lanes 2–3 for simple ops
    localparam STATE_EXEC3 = 4'd3; // extra stage for MUL if desired
    localparam STATE_DOT0  = 4'd4; // dot product takes 4 cycles
    localparam STATE_DOT1  = 4'd5;
    localparam STATE_DOT2  = 4'd6;
    localparam STATE_DOT3  = 4'd7;
    localparam STATE_DONE  = 4'd8;

    reg [3:0] state, state_next;

    // Latched operands and op
    reg [31:0] rs1_reg, rs2_reg;
    reg [2:0]  op_reg;

    // Partial and final results
    reg [31:0] partial_reg;  // for lanes 0–1
    reg [31:0] result_reg;   // final 4-lane result or dot product

    // Accumulator for dot product
    reg [31:0] acc_reg;

    // Lane extraction
    wire [7:0] a0 = rs1_reg[7:0];
    wire [7:0] a1 = rs1_reg[15:8];
    wire [7:0] a2 = rs1_reg[23:16];
    wire [7:0] a3 = rs1_reg[31:24];

    wire [7:0] b0 = rs2_reg[7:0];
    wire [7:0] b1 = rs2_reg[15:8];
    wire [7:0] b2 = rs2_reg[23:16];
    wire [7:0] b3 = rs2_reg[31:24];

    // Combinational lane results for simple ops
    reg [7:0] rd0_0, rd0_1; // lanes 0–1
    reg [7:0] rd1_2, rd1_3; // lanes 2–3

    // For saturating add
    reg [8:0] s0_0, s0_1;
    reg [8:0] s1_2, s1_3;

    // For multiply
    wire [15:0] p0_0 = a0 * b0;
    wire [15:0] p0_1 = a1 * b1;
    wire [15:0] p1_2 = a2 * b2;
    wire [15:0] p1_3 = a3 * b3;

    // Next-state and outputs
    always @* begin
        state_next = state;

        pcpi_wr    = 1'b0;
        pcpi_rd    = 32'b0;
        pcpi_wait  = 1'b0;
        pcpi_ready = 1'b0;

        rd0_0 = 8'b0;
        rd0_1 = 8'b0;
        rd1_2 = 8'b0;
        rd1_3 = 8'b0;

        s0_0  = 9'b0;
        s0_1  = 9'b0;
        s1_2  = 9'b0;
        s1_3  = 9'b0;

        case (state)
            // --------------------------------------------------
            STATE_IDLE: begin
                if (pcpi_valid && is_vec_insn) begin
                    pcpi_wait = 1'b1;
                    if (funct3 == VOP_DOT)
                        state_next = STATE_DOT0;
                    else
                        state_next = STATE_EXEC1;
                end
            end

            // --------------------------------------------------
            // Simple vector ops (VADD/VSUB/VAND/VOR/VXOR/VSADD/VMUL)
            // --------------------------------------------------
            STATE_EXEC1: begin
                pcpi_wait = 1'b1;

                case (op_reg)
                    VOP_ADD: begin
                        rd0_0 = a0 + b0;
                        rd0_1 = a1 + b1;
                    end
                    VOP_SUB: begin
                        rd0_0 = a0 - b0;
                        rd0_1 = a1 - b1;
                    end
                    VOP_AND: begin
                        rd0_0 = a0 & b0;
                        rd0_1 = a1 & b1;
                    end
                    VOP_OR: begin
                        rd0_0 = a0 | b0;
                        rd0_1 = a1 | b1;
                    end
                    VOP_XOR: begin
                        rd0_0 = a0 ^ b0;
                        rd0_1 = a1 ^ b1;
                    end
                    VOP_SADD: begin
                        s0_0 = {1'b0, a0} + {1'b0, b0};
                        s0_1 = {1'b0, a1} + {1'b0, b1};
                        rd0_0 = s0_0[8] ? 8'hFF : s0_0[7:0];
                        rd0_1 = s0_1[8] ? 8'hFF : s0_1[7:0];
                    end
                    VOP_MUL: begin
                        rd0_0 = p0_0[7:0];
                        rd0_1 = p0_1[7:0];
                    end
                    default: ;
                endcase

                state_next = STATE_EXEC2;
            end

            STATE_EXEC2: begin
                pcpi_wait = 1'b1;

                case (op_reg)
                    VOP_ADD: begin
                        rd1_2 = a2 + b2;
                        rd1_3 = a3 + b3;
                    end
                    VOP_SUB: begin
                        rd1_2 = a2 - b2;
                        rd1_3 = a3 - b3;
                    end
                    VOP_AND: begin
                        rd1_2 = a2 & b2;
                        rd1_3 = a3 & b3;
                    end
                    VOP_OR: begin
                        rd1_2 = a2 | b2;
                        rd1_3 = a3 | b3;
                    end
                    VOP_XOR: begin
                        rd1_2 = a2 ^ b2;
                        rd1_3 = a3 ^ b3;
                    end
                    VOP_SADD: begin
                        s1_2 = {1'b0, a2} + {1'b0, b2};
                        s1_3 = {1'b0, a3} + {1'b0, b3};
                        rd1_2 = s1_2[8] ? 8'hFF : s1_2[7:0];
                        rd1_3 = s1_3[8] ? 8'hFF : s1_3[7:0];
                    end
                    VOP_MUL: begin
                        rd1_2 = p1_2[7:0];
                        rd1_3 = p1_3[7:0];
                    end
                    default: ;
                endcase

                // for now, MUL uses same 2-stage path; EXEC3 reserved if we we later need deeper pipeline
                state_next = STATE_DONE;
            end

            // Optional extra stage for MUL if we later decide to deepen the pipeline
            STATE_EXEC3: begin
                pcpi_wait  = 1'b1;
                state_next = STATE_DONE;
            end

            // --------------------------------------------------
            // Dot product: one lane per cycle
            // --------------------------------------------------
            STATE_DOT0: begin
                pcpi_wait  = 1'b1;
                state_next = STATE_DOT1;
            end

            STATE_DOT1: begin
                pcpi_wait  = 1'b1;
                state_next = STATE_DOT2;
            end

            STATE_DOT2: begin
                pcpi_wait  = 1'b1;
                state_next = STATE_DOT3;
            end

            STATE_DOT3: begin
                pcpi_wait  = 1'b1;
                state_next = STATE_DONE;
            end
           
            STATE_DONE: begin
                // VDOT8's accumulator only lands in result_reg at the END of
                // this cycle - reading result_reg here returned the PREVIOUS
                // instruction's result. Mux the accumulator out directly.
                pcpi_rd    = (op_reg == VOP_DOT) ? acc_reg : result_reg;
                pcpi_wr    = 1'b1;
                pcpi_ready = 1'b1;
                pcpi_wait  = 1'b0;
                state_next = STATE_IDLE;
            end

            default: state_next = STATE_IDLE;
        endcase
    end

    // Sequential logic (synchronous reset, matching picorv32's style - the
    // raw external resetn pin is not synchronized, so async removal here
    // would be a recovery/removal hazard)
    always @(posedge clk) begin
        if (!resetn) begin
            state      <= STATE_IDLE;
            rs1_reg    <= 32'b0;
            rs2_reg    <= 32'b0;
            op_reg     <= 3'b0;
            partial_reg<= 32'b0;
            result_reg <= 32'b0;
            acc_reg    <= 32'b0;
        end else begin
            state <= state_next;

            case (state)
                STATE_IDLE: begin
                    if (pcpi_valid && is_vec_insn) begin
                        rs1_reg <= pcpi_rs1;
                        rs2_reg <= pcpi_rs2;
                        op_reg  <= funct3;
                        acc_reg <= 32'b0;
                    end
                end

                // Simple ops: store partial and final results
                STATE_EXEC1: begin
                    partial_reg <= {16'b0, rd0_1, rd0_0};
                end

                STATE_EXEC2: begin
                    result_reg <= {rd1_3, rd1_2, partial_reg[15:8], partial_reg[7:0]};
                end

                STATE_EXEC3: begin
                    // If later we decide to use EXEC3 for MUL, pack here
                end

                // Dot product accumulation
                STATE_DOT0: begin
                    acc_reg <= acc_reg + (a0 * b0);
                end

                STATE_DOT1: begin
                    acc_reg <= acc_reg + (a1 * b1);
                end

                STATE_DOT2: begin
                    acc_reg <= acc_reg + (a2 * b2);
                end

                STATE_DOT3: begin
                    acc_reg <= acc_reg + (a3 * b3);
                end

                STATE_DONE: begin
                    // Select result source: dot vs simple ops
                    if (op_reg == VOP_DOT)
                        result_reg <= acc_reg;
                    // else result_reg already set in EXEC2
                end
            endcase
        end
    end

endmodule
