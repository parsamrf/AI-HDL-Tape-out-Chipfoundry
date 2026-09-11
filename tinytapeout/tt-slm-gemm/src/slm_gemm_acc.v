/*
 * slm_gemm_acc — per-column accumulator capture and drain sequencer for the
 * GEMM engine.
 *
 * The 8 south-edge column sums of one activation row arrive skewed (column n
 * pulses col_valid[n] one cycle after column n-1). Each pulse captures that
 * column's INT32 dot product. Once all 8 columns of the row are captured,
 * the drain sequencer streams them in column order 0..7 into the shared
 * slm_requant (owned by slm_gemm_ctrl) at one value per cycle, tags each
 * returning INT8 with its column index on res_col, and pulses row_done one
 * cycle after the last requantized byte. The controller streams rows
 * serially, so capture of a new row never overlaps a drain in progress.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.8.
 */
`default_nettype none

module slm_gemm_acc (
  input  wire         clk,           // clock
  input  wire         rst_n,         // synchronous active-low reset
  input  wire         clear,         // pulse: reset capture/drain state
  input  wire [7:0]   col_valid,     // array south-edge valid per column
  input  wire [255:0] col_psum_flat, // array south-edge sums, 32b each
  output reg          rq_in_valid,   // to shared slm_requant in_valid
  output reg  [31:0]  rq_in_acc,     // to shared slm_requant in_acc
  input  wire         rq_out_valid,  // from slm_requant out_valid
  input  wire [7:0]   rq_out_q,      // from slm_requant out_q
  output wire         res_valid,     // requantized result byte valid
  output wire [2:0]   res_col,       // column index of res_q
  output wire [7:0]   res_q,         // requantized result byte
  output reg          row_done       // pulse: row fully drained
);

  reg [31:0] acc_reg [0:7];
  reg [7:0]  captured;
  reg        draining;
  reg [3:0]  issue_idx;
  reg [2:0]  out_idx;

  integer i;

  assign res_valid = rq_out_valid;
  assign res_col   = out_idx;
  assign res_q     = rq_out_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      captured    <= 8'h00;
      draining    <= 1'b0;
      issue_idx   <= 4'd0;
      out_idx     <= 3'd0;
      rq_in_valid <= 1'b0;
      rq_in_acc   <= 32'h0;
      row_done    <= 1'b0;
      for (i = 0; i < 8; i = i + 1)
        acc_reg[i] <= 32'h0;
    end else begin
      row_done    <= 1'b0;
      rq_in_valid <= 1'b0;
      if (clear) begin
        captured  <= 8'h00;
        draining  <= 1'b0;
        issue_idx <= 4'd0;
        out_idx   <= 3'd0;
      end else begin
        // capture skewed column results as they pop out of the array
        for (i = 0; i < 8; i = i + 1) begin
          if (col_valid[i]) begin
            acc_reg[i]  <= col_psum_flat[32*i +: 32];
            captured[i] <= 1'b1;
          end
        end
        // start draining once the whole row is captured
        if (!draining && (captured == 8'hFF)) begin
          draining  <= 1'b1;
          issue_idx <= 4'd0;
          out_idx   <= 3'd0;
        end
        // issue one accumulator per cycle into the requant pipeline
        if (draining && (issue_idx < 4'd8)) begin
          rq_in_valid <= 1'b1;
          rq_in_acc   <= acc_reg[issue_idx[2:0]];
          issue_idx   <= issue_idx + 4'd1;
        end
        // count requantized bytes coming back (in issue order 0..7)
        if (rq_out_valid) begin
          if (out_idx == 3'd7) begin
            row_done <= 1'b1;
            draining <= 1'b0;
            captured <= 8'h00;
            out_idx  <= 3'd0;
          end else begin
            out_idx <= out_idx + 3'd1;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
