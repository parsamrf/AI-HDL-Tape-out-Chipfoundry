
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


 /* cpu core needs some sram to execute instructions and store varaibles etc
	   so, we instantiate sram module. We have two choices here :
	   
       we may use compiler-optimiozed our own behavioral model sram (which is used here)
	   when compared with built-in sram cell this results in less area and higher fmax
	   or use the cell-hardened sky130_sram_2kbyte_1rw1r_32x512_8 sram modue.
	   The sky130_sram_2kbyte_1rw1r_32x512_8 module often crashes and currently offline
	   from silicon-Compiler's website due to some debug issues and not recommended for use) */
	   
module sram_behav (
    input         clk,
    input         csb0,      // active low
    input         web0,      // active low write enable
    input  [3:0]  wmask0,
    input  [31:0] din0,
    input  [31:0] addr0,
    output reg [31:0] dout0
);

    reg [31:0] mem [0:31];    // 128 B = 32 words (TinyTapeout-sized)

    always @(posedge clk) begin
        if (!csb0) begin
            if (!web0) begin
                if (wmask0[0]) mem[addr0[4:0]][7:0]   <= din0[7:0];
                if (wmask0[1]) mem[addr0[4:0]][15:8]  <= din0[15:8];
                if (wmask0[2]) mem[addr0[4:0]][23:16] <= din0[23:16];
                if (wmask0[3]) mem[addr0[4:0]][31:24] <= din0[31:24];
            end
            dout0 <= mem[addr0[4:0]];
        end
    end
endmodule
