module bmu_pcpi_wrapper (
    input wire clk, resetn,
    input  wire         pcpi_valid,
    input  wire [31:0]  pcpi_insn,
    input  wire [31:0]  pcpi_rs1,
    input  wire [31:0]  pcpi_rs2,
    output reg  [31:0]  pcpi_rd,
    output reg          pcpi_wr,
    output reg          pcpi_ready,
    output reg          pcpi_wait
);

    wire [31:0] bmu_result;

    // BMU fed directly from PCPI bus 
    BMU my_core (
        .data_in (pcpi_rs1),
        .sel_op  (pcpi_insn[14:12]),
        .data_out(bmu_result)
    );

    localparam IDLE = 1'd0;
    localparam DONE = 1'd1;

    reg state;

    always @(posedge clk) begin
        if (!resetn) begin
            state      <= IDLE;
            pcpi_wait  <= 1'b0;
            pcpi_ready <= 1'b0;
            pcpi_wr    <= 1'b0;
            pcpi_rd    <= 32'b0;
        end else begin
            pcpi_ready <= 1'b0;
            pcpi_wr    <= 1'b0;
            pcpi_wait  <= 1'b0;

            case (state)
                IDLE: begin
                    // !pcpi_ready holds off re-acceptance during the
                    // completion cycle: picorv32 keeps pcpi_valid high while
                    // ready is asserted, and without the gate the FSM
                    // re-armed and fired a ghost ready/wr pulse (with stale
                    // pcpi_rd) two cycles after valid deasserted.
                    if (pcpi_valid && !pcpi_ready && pcpi_insn[6:0] == 7'b0001011) begin
                        pcpi_wait <= 1'b1;
                        state     <= DONE;
                    end
                end

                DONE: begin
                    pcpi_rd    <= bmu_result;
                    pcpi_ready <= 1'b1;
                    pcpi_wr    <= 1'b1;
                    state      <= IDLE;
                end
            endcase
        end
    end

endmodule
