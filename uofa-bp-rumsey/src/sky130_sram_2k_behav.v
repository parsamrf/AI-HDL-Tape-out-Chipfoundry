// Tapeout integration harness — behavioral flop-RAM substitution for the sky130
// SRAM macro, for physical-flow demonstration only.
//
// Implements the exact interface of the OpenRAM blackbox
// sky130_sram_2kbyte_1rw1r_32x512_8 (src/sky130_sram_2k.bb.v) as a
// synthesizable synchronous flop RAM: 512 x 32 bits, one RW port with
// byte write mask, one R port.

module sky130_sram_2kbyte_1rw1r_32x512_8 (
`ifdef USE_POWER_PINS
    inout vccd1,
    inout vssd1,
`endif
    // Port 0: RW
    input clk0,
    input csb0,
    input web0,
    input [3:0] wmask0,
    input [8:0] addr0,
    input [31:0] din0,
    output reg [31:0] dout0,
    // Port 1: R
    input clk1,
    input csb1,
    input [8:0] addr1,
    output reg [31:0] dout1
);

    reg [31:0] mem [0:511];

    // Port 0: synchronous read/write
    always @(posedge clk0) begin
        if (!csb0) begin
            if (!web0) begin
                if (wmask0[0]) mem[addr0][ 7: 0] <= din0[ 7: 0];
                if (wmask0[1]) mem[addr0][15: 8] <= din0[15: 8];
                if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
                if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
            end
            dout0 <= mem[addr0];
        end
    end

    // Port 1: synchronous read
    always @(posedge clk1) begin
        if (!csb1)
            dout1 <= mem[addr1];
    end

endmodule
