`default_nettype none

module tqvp_spi_traffic4 (
    input         clk,
    input         rst_n,

    // External pins
    input  [7:0]  ui_in,
    output [7:0]  uo_out,

    // TinyQV peripheral bus
    input  [5:0]  address,
    input  [31:0] data_in,
    input  [1:0]  data_write_n,
    input  [1:0]  data_read_n,
    output [31:0] data_out,
    input         data_ready,
    output        user_interrupt
);

    // ------------------------------------------------------------
    // Register map
    // ------------------------------------------------------------
    localparam [3:0] REG_CTRL        = 4'd0;
    localparam [3:0] REG_LOOP_STATUS = 4'd1;
    localparam [3:0] REG_WIFI_COUNT  = 4'd2;
    localparam [3:0] REG_THRESHOLD   = 4'd3;
    localparam [3:0] REG_STATUS      = 4'd4;
    localparam [3:0] REG_SPI_STATUS  = 4'd5;
    localparam [3:0] REG_SECURITY    = 4'd6;

    // ------------------------------------------------------------
    // External pin map
    //
    // ui_in[0] = inductive loop detect input
    // ui_in[1] = SPI SCK from ESP32
    // ui_in[2] = SPI CS_N from ESP32, active low
    // ui_in[3] = SPI MOSI from ESP32
    //
    // uo_out[0] = supplemental request to original 555/controller
    // uo_out[1] = Wi-Fi congestion present
    // uo_out[2] = synchronized/filtered loop detect status
    // uo_out[3] = latched interrupt pending
    // uo_out[4] = SPI MISO, unused/tied low in this write-only version
    // uo_out[7:5] = unused
    // ------------------------------------------------------------

    wire loop_raw   = ui_in[0];
    wire spi_sck_i  = ui_in[1];
    wire spi_cs_ni  = ui_in[2];
    wire spi_mosi_i = ui_in[3];

    // ------------------------------------------------------------
    // Control register bits
    //
    // ctrl_reg[0] = enable
    // ctrl_reg[1] = request mode:
    //               0 = level request while Wi-Fi demand is present
    //               1 = one-shot pulse request when Wi-Fi demand appears
    //
    // Write-only CTRL bit:
    // data_in[2] = clear irq_pending
    //
    // SECURITY CHANGE:
    //   CTRL is TinyQV-bus-only. SPI is intentionally not allowed to
    //   enable/disable the peripheral or change pulse/level behavior.
    // ------------------------------------------------------------

    reg [1:0] ctrl_reg;

    wire ctrl_enable     = ctrl_reg[0];
    wire ctrl_pulse_mode = ctrl_reg[1];

    // ------------------------------------------------------------
    // Stored system registers
    // ------------------------------------------------------------

    reg [3:0] wifi_count_reg;
    reg [3:0] threshold_reg;
    reg       irq_pending;

    // ------------------------------------------------------------
    // Security / protocol constants
    // ------------------------------------------------------------
    // SPI packet format is now 32 bits:
    //
    //   byte 0: command/address
    //   byte 1: data
    //   byte 2: sequence counter
    //   byte 3: keyed CRC8-style authentication tag
    //
    // Command byte:
    //   bit[7]   = 1 for write
    //   bit[6:4] = 3'b101 command class / packet discriminator
    //   bit[3:0] = register address
    //
    // Only REG_WIFI_COUNT is writable over SPI. REG_CTRL and
    // REG_THRESHOLD are intentionally bus-only.
    //
    // Tag generation expected from ESP32:
    //   tag = CRC8(KEY, command, data, sequence)
    //
    // This is a lightweight keyed integrity/authenticity check, not a
    // substitute for a cryptographic MAC such as HMAC-SHA256.
    // ------------------------------------------------------------

    localparam [7:0] SPI_CMD_CLASS     = 8'h50;  // after mask 8'h70, command[6:4] must be 3'b101
    localparam [7:0] SPI_CMD_CLASS_MSK = 8'h70;
    localparam [7:0] SPI_AUTH_KEY      = 8'h5C;  // demo key; choose/project-configure in real use

    // Stale Wi-Fi readings expire if no valid authenticated packet arrives.
    // To reduce switching power, the timeout counter does not decrement
    // every clk cycle. Instead, it decrements only when a small prescaler
    // reaches WIFI_TIMEOUT_TICK_MAX.
    //
    // Effective timeout in clk cycles is approximately:
    //   WIFI_TIMEOUT_MAX * (WIFI_TIMEOUT_TICK_MAX + 1)
    //
    // Example: 16'hFFFF * 256 cycles if WIFI_TIMEOUT_TICK_MAX = 8'hFF.
    localparam [15:0] WIFI_TIMEOUT_MAX      = 16'hFFFF;
    localparam [7:0]  WIFI_TIMEOUT_TICK_MAX = 8'hFF;

    // Avoid threshold=0, which would make every count look congested.
    localparam [3:0] MIN_THRESHOLD = 4'd1;
    localparam [3:0] MAX_THRESHOLD = 4'd15;

    // ------------------------------------------------------------
    // TinyQV bus decode
    // ------------------------------------------------------------

    wire [3:0] reg_sel  = address[5:2];
    wire       write_en = (data_write_n != 2'b11);
    wire       read_en  = (data_read_n  != 2'b11);

    wire sel_ctrl      = (reg_sel == REG_CTRL);
    wire sel_wifi      = (reg_sel == REG_WIFI_COUNT);
    wire sel_threshold = (reg_sel == REG_THRESHOLD);

    wire ctrl_wen      = write_en && sel_ctrl;
    wire wifi_bus_wen  = write_en && sel_wifi;
    wire thresh_wen    = write_en && sel_threshold;

    wire irq_clear_now = ctrl_wen && data_in[2];

    wire [3:0] threshold_from_bus =
        (data_in[3:0] < MIN_THRESHOLD) ? MIN_THRESHOLD :
        (data_in[3:0] > MAX_THRESHOLD) ? MAX_THRESHOLD :
        data_in[3:0];

    // ------------------------------------------------------------
    // Synchronize and lightly filter loop detector input
    // ------------------------------------------------------------
    // The raw loop detector is synchronized first, then filtered so that
    // short glitches do not briefly make the design believe the loop is
    // inactive and allow a Wi-Fi supplemental request.
    // ------------------------------------------------------------

    reg loop_s1;
    reg loop_s2;
    reg loop_detect_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_s1          <= 1'b0;
            loop_s2          <= 1'b0;
            loop_detect_sync <= 1'b0;
        end else begin
            loop_s1          <= loop_raw;
            loop_s2          <= loop_s1;
            loop_detect_sync <= loop_s2;
        end
    end

    reg [3:0] loop_inactive_count;
    reg       loop_inactive_stable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_inactive_count  <= 4'd0;
            loop_inactive_stable <= 1'b0;
        end else if (loop_detect_sync) begin
            loop_inactive_count  <= 4'd0;
            loop_inactive_stable <= 1'b0;
        end else if (loop_inactive_count != 4'hF) begin
            loop_inactive_count  <= loop_inactive_count + 4'd1;
            loop_inactive_stable <= 1'b0;
        end else begin
            loop_inactive_stable <= 1'b1;
        end
    end

    wire loop_detect_r = loop_detect_sync;

    // ------------------------------------------------------------
    // SPI input synchronization
    // ------------------------------------------------------------
    // Suggested ESP32 SPI mode:
    //   CPOL = 0
    //   CPHA = 0
    //
    // Data is sampled on rising SCK while CS_N is low.
    // clk must be several times faster than SPI SCK.
    // ------------------------------------------------------------

    reg spi_sck_s1;
    reg spi_sck_s2;
    reg spi_cs_s1;
    reg spi_cs_s2;
    reg spi_mosi_s1;
    reg spi_mosi_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_sck_s1  <= 1'b0;
            spi_sck_s2  <= 1'b0;
            spi_cs_s1   <= 1'b1;
            spi_cs_s2   <= 1'b1;
            spi_mosi_s1 <= 1'b0;
            spi_mosi_s2 <= 1'b0;
        end else begin
            spi_sck_s1  <= spi_sck_i;
            spi_sck_s2  <= spi_sck_s1;

            spi_cs_s1   <= spi_cs_ni;
            spi_cs_s2   <= spi_cs_s1;

            spi_mosi_s1 <= spi_mosi_i;
            spi_mosi_s2 <= spi_mosi_s1;
        end
    end

    wire spi_cs_active = ~spi_cs_s2;
    wire spi_sck_rise  = spi_cs_active && (spi_sck_s1 && !spi_sck_s2);

    // ------------------------------------------------------------
    // SPI 32-bit packet receiver
    // ------------------------------------------------------------

    reg [31:0] spi_shift;
    reg [5:0]  spi_bit_count;
    reg        spi_packet_ready;
    reg [7:0]  spi_cmd_byte;
    reg [7:0]  spi_data_byte;
    reg [7:0]  spi_seq_byte;
    reg [7:0]  spi_tag_byte;
    reg        spi_write_seen;
    reg        spi_frame_done;

    wire [31:0] spi_shift_next = {spi_shift[30:0], spi_mosi_s2};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_shift        <= 32'd0;
            spi_bit_count    <= 6'd0;
            spi_packet_ready <= 1'b0;
            spi_cmd_byte     <= 8'd0;
            spi_data_byte    <= 8'd0;
            spi_seq_byte     <= 8'd0;
            spi_tag_byte     <= 8'd0;
            spi_write_seen   <= 1'b0;
            spi_frame_done   <= 1'b0;
        end else begin
            spi_packet_ready <= 1'b0;

            if (!spi_cs_active) begin
                spi_bit_count  <= 6'd0;
                spi_shift      <= 32'd0;
                spi_frame_done <= 1'b0;
            end else if (spi_sck_rise && !spi_frame_done) begin
                spi_shift <= spi_shift_next;

                if (spi_bit_count == 6'd31) begin
                    spi_bit_count    <= 6'd0;
                    spi_packet_ready <= 1'b1;
                    spi_cmd_byte     <= spi_shift_next[31:24];
                    spi_data_byte    <= spi_shift_next[23:16];
                    spi_seq_byte     <= spi_shift_next[15:8];
                    spi_tag_byte     <= spi_shift_next[7:0];
                    spi_write_seen   <= spi_shift_next[31];
                    spi_frame_done   <= 1'b1;
                end else begin
                    spi_bit_count <= spi_bit_count + 6'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Lightweight keyed CRC8 tag checker
    // ------------------------------------------------------------
    // Polynomial: x^8 + x^2 + x + 1, represented as 8'h07.
    // Input order matches byte order: KEY, command, data, sequence.
    // ------------------------------------------------------------

    function [7:0] crc8_byte;
        input [7:0] crc_in;
        input [7:0] data_byte;
        reg   [7:0] crc;
        reg   [7:0] data;
        integer i;
        begin
            crc  = crc_in;
            data = data_byte;
            for (i = 0; i < 8; i = i + 1) begin
                if ((crc[7] ^ data[7]) == 1'b1) begin
                    crc = {crc[6:0], 1'b0} ^ 8'h07;
                end else begin
                    crc = {crc[6:0], 1'b0};
                end
                data = {data[6:0], 1'b0};
            end
            crc8_byte = crc;
        end
    endfunction

    function [7:0] spi_expected_tag;
        input [7:0] cmd;
        input [7:0] dat;
        input [7:0] seq;
        reg   [7:0] crc;
        begin
            crc = 8'h00;
            crc = crc8_byte(crc, SPI_AUTH_KEY);
            crc = crc8_byte(crc, cmd);
            crc = crc8_byte(crc, dat);
            crc = crc8_byte(crc, seq);
            spi_expected_tag = crc;
        end
    endfunction

    wire       spi_cmd_class_ok = ((spi_cmd_byte & SPI_CMD_CLASS_MSK) == SPI_CMD_CLASS);
    wire [3:0] spi_reg_addr     = spi_cmd_byte[3:0];
    wire       spi_tag_ok       = (spi_tag_byte == spi_expected_tag(spi_cmd_byte,
                                                                     spi_data_byte,
                                                                     spi_seq_byte));

    reg [7:0] last_spi_seq;
    reg       last_spi_seq_valid;
    wire      spi_seq_fresh = !last_spi_seq_valid || (spi_seq_byte != last_spi_seq);

    // SECURITY CHANGE:
    //   SPI can write Wi-Fi count only. CTRL and THRESHOLD are bus-only.
    wire spi_is_write = spi_packet_ready &&
                        spi_write_seen &&
                        spi_cmd_class_ok &&
                        spi_tag_ok &&
                        spi_seq_fresh;

    wire spi_ctrl_wen      = 1'b0;
    wire spi_threshold_wen = 1'b0;
    wire spi_wifi_wen      = spi_is_write && (spi_reg_addr == REG_WIFI_COUNT);

    // Status flags for debugging/security visibility.
    reg spi_last_tag_ok;
    reg spi_last_seq_ok;
    reg spi_last_cmd_ok;
    reg spi_last_packet_accepted;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_spi_seq             <= 8'd0;
            last_spi_seq_valid       <= 1'b0;
            spi_last_tag_ok          <= 1'b0;
            spi_last_seq_ok          <= 1'b0;
            spi_last_cmd_ok          <= 1'b0;
            spi_last_packet_accepted <= 1'b0;
        end else begin
            spi_last_packet_accepted <= 1'b0;

            if (spi_packet_ready) begin
                spi_last_tag_ok <= spi_tag_ok;
                spi_last_seq_ok <= spi_seq_fresh;
                spi_last_cmd_ok <= spi_cmd_class_ok && spi_write_seen &&
                                   (spi_reg_addr == REG_WIFI_COUNT);

                if (spi_wifi_wen) begin
                    last_spi_seq             <= spi_seq_byte;
                    last_spi_seq_valid       <= 1'b1;
                    spi_last_packet_accepted <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Register writes
    // ------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_reg <= 2'b00;
        end else if (ctrl_wen) begin
            ctrl_reg <= data_in[1:0];
        end else if (spi_ctrl_wen) begin
            // Unreachable by design; retained as a named security tie-off.
            ctrl_reg <= spi_data_byte[1:0];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            threshold_reg <= 4'd8;
        end else if (thresh_wen) begin
            threshold_reg <= threshold_from_bus;
        end else if (spi_threshold_wen) begin
            // Unreachable by design; threshold is bus-only.
            threshold_reg <= spi_data_byte[3:0];
        end
    end

    // Wi-Fi data freshness watchdog.
    //
    // Low-power change:
    //   The large timeout counter is not decremented every clk cycle.
    //   A small prescaler generates a slower timeout tick, so the wider
    //   wifi_timeout register switches much less often. The prescaler is
    //   also held at zero when no timeout is active.
    reg [15:0] wifi_timeout;
    reg [7:0]  wifi_timeout_tick_count;
    reg        wifi_valid;

    wire wifi_timeout_active = (wifi_timeout != 16'd0);
    wire wifi_timeout_tick   = wifi_timeout_active &&
                               (wifi_timeout_tick_count == WIFI_TIMEOUT_TICK_MAX);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wifi_count_reg           <= 4'd0;
            wifi_timeout             <= 16'd0;
            wifi_timeout_tick_count  <= 8'd0;
            wifi_valid               <= 1'b0;
        end else if (wifi_bus_wen) begin
            wifi_count_reg           <= data_in[3:0];
            wifi_timeout             <= WIFI_TIMEOUT_MAX;
            wifi_timeout_tick_count  <= 8'd0;
            wifi_valid               <= 1'b1;
        end else if (spi_wifi_wen) begin
            wifi_count_reg           <= spi_data_byte[3:0];
            wifi_timeout             <= WIFI_TIMEOUT_MAX;
            wifi_timeout_tick_count  <= 8'd0;
            wifi_valid               <= 1'b1;
        end else if (wifi_timeout_active) begin
            wifi_valid <= 1'b1;

            if (wifi_timeout_tick) begin
                wifi_timeout            <= wifi_timeout - 16'd1;
                wifi_timeout_tick_count <= 8'd0;
            end else begin
                wifi_timeout_tick_count <= wifi_timeout_tick_count + 8'd1;
            end
        end else begin
            wifi_timeout_tick_count <= 8'd0;
            wifi_valid              <= 1'b0;
        end
    end

    // ------------------------------------------------------------
    // Demand detection
    // ------------------------------------------------------------
    // If the loop detector is active, the original loop/555 controller
    // already has demand, so TinyQV suppresses the supplemental request.
    //
    // Security/safety changes:
    //   - stale Wi-Fi counts are ignored through wifi_valid
    //   - Wi-Fi request is allowed only after stable loop inactivity
    //   - threshold cannot be set to 0 through bus clamp
    // ------------------------------------------------------------

    wire wifi_above_threshold = wifi_valid &&
                                ctrl_enable &&
                                (wifi_count_reg >= threshold_reg);

    reg congestion_r;
    reg wifi_demand_r;
    reg supplemental_request_level;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            congestion_r               <= 1'b0;
            wifi_demand_r              <= 1'b0;
            supplemental_request_level <= 1'b0;
        end else begin
            congestion_r <= wifi_above_threshold;

            wifi_demand_r <= wifi_above_threshold &&
                             loop_inactive_stable;

            supplemental_request_level <= wifi_above_threshold &&
                                          loop_inactive_stable;
        end
    end

    // ------------------------------------------------------------
    // Optional one-shot request pulse
    // ------------------------------------------------------------

    localparam [3:0] PULSE_WIDTH = 4'd8;

    reg wifi_demand_d;
    reg [3:0] pulse_count;

    wire wifi_demand_rise = wifi_demand_r && !wifi_demand_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wifi_demand_d <= 1'b0;
            pulse_count   <= 4'd0;
        end else begin
            wifi_demand_d <= wifi_demand_r;

            if (!ctrl_enable) begin
                pulse_count <= 4'd0;
            end else if (wifi_demand_rise) begin
                pulse_count <= PULSE_WIDTH;
            end else if (pulse_count != 4'd0) begin
                pulse_count <= pulse_count - 4'd1;
            end
        end
    end

    wire supplemental_request_pulse = (pulse_count != 4'd0);

    wire supplemental_request =
        ctrl_pulse_mode ? supplemental_request_pulse :
                          supplemental_request_level;

    // ------------------------------------------------------------
    // Interrupt latch
    // ------------------------------------------------------------
    // Edge-latched interrupt: the CPU can clear it even while level demand
    // remains present. A new rising demand event reasserts it.
    // ------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_pending <= 1'b0;
        end else begin
            irq_pending <= wifi_demand_rise | (irq_pending & ~irq_clear_now);
        end
    end

    // ------------------------------------------------------------
    // Read mux
    // ------------------------------------------------------------

    reg [31:0] read_data;

    always @(*) begin
        if (!read_en) begin
            read_data = 32'd0;
        end else begin
            case (reg_sel)
                REG_CTRL:
                    read_data = {30'd0, ctrl_reg};

                REG_LOOP_STATUS:
                    read_data = {30'd0, loop_inactive_stable, loop_detect_r};

                REG_WIFI_COUNT:
                    read_data = {27'd0, wifi_valid, wifi_count_reg};

                REG_THRESHOLD:
                    read_data = {28'd0, threshold_reg};

                REG_STATUS:
                    read_data = {25'd0,
                                 loop_inactive_stable,
                                 wifi_valid,
                                 supplemental_request,
                                 irq_pending,
                                 loop_detect_r,
                                 wifi_demand_r,
                                 congestion_r};

                REG_SPI_STATUS:
                    read_data = {8'd0,
                                 spi_cs_active,
                                 spi_frame_done,
                                 spi_packet_ready,
                                 spi_write_seen,
                                 spi_bit_count,
                                 spi_cmd_byte};

                REG_SECURITY:
                    read_data = {3'd0,
                                 wifi_timeout_tick_count,
                                 last_spi_seq_valid,
                                 spi_last_packet_accepted,
                                 spi_last_cmd_ok,
                                 spi_last_seq_ok,
                                 spi_last_tag_ok,
                                 last_spi_seq,
                                 spi_tag_byte};

                default:
                    read_data = 32'd0;
            endcase
        end
    end

    assign data_out = read_data;

    // ------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------

    assign user_interrupt = irq_pending;

    assign uo_out[0] = supplemental_request;
    assign uo_out[1] = congestion_r;
    assign uo_out[2] = loop_detect_r;
    assign uo_out[3] = irq_pending;
    assign uo_out[4] = 1'b0;  // MISO unused in this write-only SPI version
    assign uo_out[7:5] = 3'b000;

    // ------------------------------------------------------------
    // MANUAL ANTENNA FIXES
    // ------------------------------------------------------------
`ifdef SYNTHESIS
    // Fix for 'net17' (ui_in[3] / SPI MOSI)
    (* keep *) sky130_fd_sc_hd__diode_2 diode_mosi (
        .DIODE(ui_in[3])
    );

    // Fix for '_0268_' (data_out[5])
    (* keep *) sky130_fd_sc_hd__diode_2 diode_dout5 (
        .DIODE(data_out[5])
    );

    // Fix for 'net29' (data_out[29] constant tie-off)
    (* keep *) sky130_fd_sc_hd__diode_2 diode_dout29 (
        .DIODE(data_out[29])
    );
`endif
    // ------------------------------------------------------------
    // Unused signals
    // ------------------------------------------------------------

    wire _unused = &{
        ui_in[7:4],
        address[1:0],
        data_in[31:4],
        data_ready,
        1'b0
    };

endmodule

// ------------------------------------------------------------
// PHYSICAL CELL BLACKBOX DEFINITIONS
// ------------------------------------------------------------
`ifdef SYNTHESIS
(* blackbox *)
module sky130_fd_sc_hd__diode_2 (
    input DIODE
);
endmodule
`endif

`default_nettype wire
