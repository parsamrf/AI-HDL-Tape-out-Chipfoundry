// la_spram.v -- behavioral single-port RAM (infrastructure, not core RTL).
//
// The original flow resolved `la_spram` from lambdalib, which mapped it to
// a sky130 SRAM hard macro. That library is not part of this repo, so we
// provide a behavioral single-port RAM with the same port list
// (clk/ce/we/wmask/addr/din/dout/selctrl/ctrl/status). wmask is a
// byte-lane mask, matching the mem_wstrb wiring.

module la_spram #(
    parameter DW    = 32,
    parameter AW    = 9,
    parameter CTRLW = 8,
    parameter STATW = 8
) (
    input                  clk,
    input                  ce,
    input                  we,
    input  [DW/8-1:0]      wmask,
    input  [AW-1:0]        addr,
    input  [DW-1:0]        din,
    output reg [DW-1:0]    dout,
    input                  selctrl,
    input  [CTRLW-1:0]     ctrl,
    output [STATW-1:0]     status
);

    reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    always @(posedge clk) begin
        if (ce) begin
            if (we) begin
                for (i = 0; i < DW/8; i = i + 1)
                    if (wmask[i]) mem[addr][i*8 +: 8] <= din[i*8 +: 8];
            end
            dout <= mem[addr];
        end
    end

    assign status = {STATW{1'b0}};

endmodule
