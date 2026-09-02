`default_nettype none

module spi_reg #(
    parameter ADDR_W = 6,
    parameter REG_W  = 32
)(
    input  wire              clk,
    input  wire              rstb,
    input  wire              ena,
    
    input  wire              spi_clk,
    input  wire              spi_mosi,
    input  wire              spi_cs_n,
    output reg               spi_miso,
    
    output reg  [ADDR_W-1:0] reg_addr,
    output reg  [REG_W-1:0]  reg_data_o,
    output reg               reg_wen,        // This is the pin the linter was missing!
    input  wire [REG_W-1:0]  reg_data_i,
    
    output reg               reg_addr_v,
    input  wire              reg_data_i_dv,  // pulse: reg_data_i is valid, load TX shifter
    output reg               reg_data_o_dv,
    output reg               reg_rw,
    input  wire [1:0]        txn_width       // Declared and now "used"
);

    reg [1:0]  state;
    reg [5:0]  bit_cnt;
    reg [REG_W-1:0] shift_reg;

    // Fix for UNUSEDSIGNAL: We'll acknowledge txn_width even if we don't use it logic-wise
    wire [1:0] _unused_width = txn_width;

    reg sclk_d;
    always @(posedge clk) sclk_d <= spi_clk;
    wire sclk_rose = (spi_clk && !sclk_d);
    wire sclk_fell = (!spi_clk && sclk_d);

    always @(posedge clk) begin
        if (!rstb || spi_cs_n || !ena) begin
            state         <= 2'b00;
            bit_cnt       <= 0;
            reg_wen       <= 0;
            spi_miso      <= 0;
            reg_addr_v    <= 0;
            reg_data_o_dv <= 0;
            reg_rw        <= 0;
        end else begin
            reg_wen       <= 0;
            // one-cycle pulse: leaving this sticky until CS deassert kept
            // write_en asserted in the wrapper for the rest of the frame,
            // letting chained commands land stale writes on registers
            reg_data_o_dv <= 0;

            case (state)
                2'b00: begin // IDLE/ADDR
                    if (sclk_rose) begin
                        if (bit_cnt == 0) reg_rw <= spi_mosi;
                        else reg_addr <= {reg_addr[ADDR_W-2:0], spi_mosi};
                        
                        if (bit_cnt == ADDR_W) begin
                            state <= 2'b01;
                            bit_cnt <= 0;
                            reg_addr_v <= 1;
                            // TX data is NOT loaded here: reg_data_i is only
                            // valid once the wrapper has seen reg_addr_v and
                            // opened the peripheral's read mux - it arrives
                            // via the reg_data_i_dv pulse in the DATA state
                        end else bit_cnt <= bit_cnt + 1;
                    end
                end

                2'b01: begin // DATA
                    reg_addr_v <= 0;
                    if (sclk_rose) begin
                        // RX shifting is a WRITE-only activity: on reads the
                        // falling-edge TX path owns shift_reg (the old
                        // unconditional shift double-clocked the TX buffer
                        // with MOSI garbage every SPI bit)
                        if (reg_rw)
                            shift_reg <= {shift_reg[REG_W-2:0], spi_mosi};
                        if (bit_cnt == REG_W-1) begin
                            if (reg_rw) begin
                                reg_data_o    <= {shift_reg[REG_W-2:0], spi_mosi};
                                reg_wen       <= 1;
                                reg_data_o_dv <= 1;
                            end
                            state <= 2'b00;
                        end else bit_cnt <= bit_cnt + 1;
                    end
                    if (reg_data_i_dv && !reg_rw) begin
                        // wrapper says read data is on reg_data_i now
                        // (system-clock event; arrives before the first
                        // falling SPI edge for any SPI clock slow enough to
                        // pass the 2-stage input synchronizers)
                        shift_reg <= reg_data_i;
                    end else if (sclk_fell && !reg_rw) begin
                        spi_miso  <= shift_reg[REG_W-1];
                        shift_reg <= {shift_reg[REG_W-2:0], 1'b0};
                    end
                end

                // Fix for CASEINCOMPLETE: Tell the linter what to do in "impossible" states
                default: state <= 2'b00; 
            endcase
        end
    end

endmodule
