/*
 * sky130_sram_2k_behav.v
 *
 * ECE 407 Final Project
 * Team: Kedar Gulvady, Ali Alsaffar, Joseph McLaughlin
 * (src/ copy maintained for tapeout)
 *
 * Behavioral RTL implementation of the OpenRAM macro
 *   sky130_sram_2kbyte_1rw1r_32x512_8
 * SYNTHESIZED INTO SILICON as a documented substitution: no GDS/LEF for
 * the OpenRAM macro exists in the PDK or repo, so the flow hardens this
 * flop-RAM instead (see the tapeout errata). Port list and timing match the
 * macro: 1-cycle synchronous read on both ports, byte-enable writes on
 * port 0. NOTE: as flops, power-up contents are RANDOM in silicon - the
 * NOP prefill below exists only in simulation.
 *
 * Loads firmware.hex via $readmemh at time 0 if the FIRMWARE_HEX
 * macro is defined at compile time:
 *
 *   iverilog -DFIRMWARE_HEX='"firmware.hex"' ... sky130_sram_2k_behav.v
 *
 */

`default_nettype none
`timescale 1ns / 1ps

module sky130_sram_2kbyte_1rw1r_32x512_8 (
`ifdef USE_POWER_PINS
    inout vccd1,
    inout vssd1,
`endif
    // Port 0 - read/write
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [3:0]  wmask0,
    input  wire [8:0]  addr0,
    input  wire [31:0] din0,
    output reg  [31:0] dout0,
    // Port 1 - read-only
    input  wire        clk1,
    input  wire        csb1,
    input  wire [8:0]  addr1,
    output reg  [31:0] dout1
);

    reg [31:0] mem [0:511];
    integer    i;

    initial begin
        // Default-fill memory with NOPs so a CPU that wanders into
        // unloaded territory at least keeps fetching something
        // benign-ish until it traps.
        for (i = 0; i < 512; i = i + 1) begin
            mem[i] = 32'h0000_0013;   // RV32 addi x0, x0, 0  (canonical NOP)
        end
`ifdef FIRMWARE_HEX
        $display("[sram] Loading firmware from %s", `FIRMWARE_HEX);
        $readmemh(`FIRMWARE_HEX, mem);
`endif
    end

    // -----------------------------------------------------------
    // Port 0 - read/write, single-cycle synchronous
    // -----------------------------------------------------------
    always @(posedge clk0) begin
        if (!csb0) begin
            if (web0) begin
                // Read
                dout0 <= mem[addr0];
            end else begin
                // Write with byte mask; reads get the new value next cycle
                if (wmask0[0]) mem[addr0][ 7: 0] <= din0[ 7: 0];
                if (wmask0[1]) mem[addr0][15: 8] <= din0[15: 8];
                if (wmask0[2]) mem[addr0][23:16] <= din0[23:16];
                if (wmask0[3]) mem[addr0][31:24] <= din0[31:24];
                // dout0 holds its previous value on a write cycle
                // (deterministic for gate-level sim; the macro leaves it
                // undefined, so nothing may rely on it either way).
            end
        end
    end

    // -----------------------------------------------------------
    // Port 1 - read-only
    // -----------------------------------------------------------
    always @(posedge clk1) begin
        if (!csb1) begin
            dout1 <= mem[addr1];
        end
    end

endmodule

`default_nettype wire
