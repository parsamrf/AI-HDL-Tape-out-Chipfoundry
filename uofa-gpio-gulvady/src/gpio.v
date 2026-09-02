/*
 * gpio.v - Memory-mapped GPIO expander peripheral for PicoRV32
 *
 * ECE 407 Final Project - Custom MMIO Peripheral
 * Team: Kedar Gulvady, Ali Alsaffar, Joseph McLaughlin
 *
 * Provides 32 bidirectional GPIO pins controlled through 4 memory-mapped
 * registers. Speaks the PicoRV32 native valid/ready memory interface
 * (see picorv32 docs Section 1.5).
 *
 * --------------------------------------------------------------------------
 *  Register map (offset from peripheral base)
 * --------------------------------------------------------------------------
 *   0x00  GPIO_DIR  R/W  Per-pin direction.  1 = output, 0 = input.
 *                        Reset value = 0 (all pins inputs).
 *   0x04  GPIO_OUT  R/W  Output value driven on pins where DIR[i]=1.
 *                        Reads return the last written value.
 *   0x08  GPIO_IN   R    Synchronized current value of gpio_i pads.
 *                        Writes are ignored.
 *   0x0C  GPIO_TOG  W    Write-1-to-toggle.  Each bit set in wdata XORs
 *                        the corresponding bit of GPIO_OUT.
 *                        Reads return 0.
 * --------------------------------------------------------------------------
 *
 * Bus interface notes
 *   - Combinational mem_ready (asserted in the same cycle as mem_valid &
 *     gpio_sel), so the peripheral never stalls the CPU.
 *   - Byte strobes (mem_wstrb[3:0]) are honored, so sw/sh/sb instructions
 *     work as expected.
 *   - Inputs are double-flopped to cross the asynchronous gpio_i pad domain
 *     into the system clock safely.
 */

`default_nettype none

module gpio #(
    parameter integer WIDTH      = 32,            // number of GPIO pins
    parameter [31:0]  BASE_ADDR  = 32'h0300_0000, // for documentation only;
                                                  // address decoding lives in
                                                  // the top-level wrapper.
    parameter integer ADDR_BITS  = 4              // 4 regs => 4 lower addr bits
) (
    input  wire             clk,
    input  wire             resetn,

    // PicoRV32 native memory interface (already address-decoded by parent)
    input  wire             mem_valid,    // asserted when this peripheral selected
    output wire             mem_ready,    // 1 in the same cycle (always ready)
    input  wire [ADDR_BITS-1:0] mem_addr, // local register offset (bytes)
    input  wire [31:0]      mem_wdata,
    input  wire [3:0]       mem_wstrb,    // 0 = read, nonzero = write
    output reg  [31:0]      mem_rdata,

    // GPIO pad-side signals (top-level routes these to IO cells)
    output wire [WIDTH-1:0] gpio_o,       // value to drive when configured output
    output wire [WIDTH-1:0] gpio_oe,      // output enable: 1 = drive gpio_o
    input  wire [WIDTH-1:0] gpio_i        // raw input from pads
);

    // ------------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] dir_reg;     // 1 = output, 0 = input
    reg [WIDTH-1:0] out_reg;     // value to drive when DIR=1
    reg [WIDTH-1:0] in_sync_q;   // first-stage synchronizer
    reg [WIDTH-1:0] in_sync;     // second-stage synchronizer (visible to CPU)

    // ------------------------------------------------------------------
    // Pad-side outputs
    // ------------------------------------------------------------------
    assign gpio_o  = out_reg;
    assign gpio_oe = dir_reg;

    // ------------------------------------------------------------------
    // Bus handshake: combinational ready
    // ------------------------------------------------------------------
    assign mem_ready = mem_valid;

    wire is_write = mem_valid && (mem_wstrb != 4'b0000);
    wire is_read  = mem_valid && (mem_wstrb == 4'b0000);

    // Word offset (drop the 2 low byte bits, keep the next ADDR_BITS-2 bits
    // as the register index).
    wire [ADDR_BITS-3:0] reg_idx = mem_addr[ADDR_BITS-1:2];

    // Per-register selects
    wire sel_dir = (reg_idx == 2'd0);
    wire sel_out = (reg_idx == 2'd1);
    wire sel_in  = (reg_idx == 2'd2);
    wire sel_tog = (reg_idx == 2'd3);

    // ------------------------------------------------------------------
    // Input synchronizer (2-flop, async-safe)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            in_sync_q <= {WIDTH{1'b0}};
            in_sync   <= {WIDTH{1'b0}};
        end else begin
            in_sync_q <= gpio_i;
            in_sync   <= in_sync_q;
        end
    end

    // ------------------------------------------------------------------
    // Write logic with byte strobes
    //
    // The four byte strobe bits (wstrb[0..3]) gate writes to bytes
    // [7:0], [15:8], [23:16], [31:24] respectively.  This matches what
    // the RV32 sb / sh / sw instructions emit.  GPIO_IN is read-only.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            dir_reg <= {WIDTH{1'b0}};   // inputs by default => safe at reset
            out_reg <= {WIDTH{1'b0}};
        end else if (is_write) begin
            if (sel_dir) begin
                if (mem_wstrb[0]) dir_reg[ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) dir_reg[15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) dir_reg[23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) dir_reg[31:24] <= mem_wdata[31:24];
            end
            if (sel_out) begin
                if (mem_wstrb[0]) out_reg[ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) out_reg[15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) out_reg[23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) out_reg[31:24] <= mem_wdata[31:24];
            end
            if (sel_tog) begin
                if (mem_wstrb[0]) out_reg[ 7: 0] <= out_reg[ 7: 0] ^ mem_wdata[ 7: 0];
                if (mem_wstrb[1]) out_reg[15: 8] <= out_reg[15: 8] ^ mem_wdata[15: 8];
                if (mem_wstrb[2]) out_reg[23:16] <= out_reg[23:16] ^ mem_wdata[23:16];
                if (mem_wstrb[3]) out_reg[31:24] <= out_reg[31:24] ^ mem_wdata[31:24];
            end
            // sel_in is read-only; writes silently ignored.
        end
    end

    // ------------------------------------------------------------------
    // Read mux (combinational so mem_rdata is valid the same cycle as
    // mem_ready).
    // ------------------------------------------------------------------
    always @(*) begin
        mem_rdata = 32'h0000_0000;
        if (is_read) begin
            case (reg_idx)
                2'd0: mem_rdata = {{(32-WIDTH){1'b0}}, dir_reg};
                2'd1: mem_rdata = {{(32-WIDTH){1'b0}}, out_reg};
                2'd2: mem_rdata = {{(32-WIDTH){1'b0}}, in_sync};
                2'd3: mem_rdata = 32'h0000_0000;   // TOG reads as zero
                default: mem_rdata = 32'h0000_0000;
            endcase
        end
    end

endmodule

`default_nettype wire
