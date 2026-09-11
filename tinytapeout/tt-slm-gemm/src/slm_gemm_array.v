/*
 * slm_gemm_array — 8x8 weight-stationary systolic mesh of slm_gemm_pe.
 *
 * PE (k, n) holds W[k][n]. Weight loading: the controller presents one
 * weight row per cycle on w_in_flat (byte n = W[w_row][n]) with w_load high;
 * the row select decodes to that row's PEs (8 cycles load the full array).
 * Activations enter at the west edge, one row-k lane per matrix column k of
 * A, and flow east; the controller injects A[m][k] into row k with a one-
 * cycle skew per row so partial sums flowing south stay aligned. Column n's
 * completed INT32 dot product for activation row m appears on the south edge
 * (col_psum_flat) with col_valid[n] high for exactly one cycle.
 *
 * AI-assisted design.
 * Part of slm-soc. See docs/SPEC.md section 6.8.
 */
`default_nettype none

module slm_gemm_array (
  input  wire         clk,           // clock
  input  wire         rst_n,         // synchronous active-low reset
  input  wire         w_load,        // load w_in_flat into weight row w_row
  input  wire [2:0]   w_row,         // destination weight row (k index)
  input  wire [63:0]  w_in_flat,     // byte n = W[w_row][n]
  input  wire [7:0]   a_valid_in,    // west-edge activation valid per row
  input  wire [63:0]  a_in_flat,     // west-edge activation byte per row
  output wire [7:0]   col_valid,     // south-edge result valid per column
  output wire [255:0] col_psum_flat  // south-edge column sums, 32b each
);

  // Mesh nets: av/ad index [row][stage] (stage 0 = west edge input),
  // ps index [boundary][col] (boundary 0 = north edge, tied to zero).
  wire        av [0:7][0:8];
  wire [7:0]  ad [0:7][0:8];
  wire [31:0] ps [0:8][0:7];

  wire [7:0] w_load_row = w_load ? (8'h01 << w_row) : 8'h00;

  wire [7:0]  east_valid;
  wire [63:0] east_data;

  genvar gk;
  genvar gn;
  generate
    for (gn = 0; gn < 8; gn = gn + 1) begin : g_col_edge
      assign ps[0][gn] = 32'h0;
      assign col_valid[gn] = av[7][gn+1];
      assign col_psum_flat[32*gn +: 32] = ps[8][gn];
    end
    for (gk = 0; gk < 8; gk = gk + 1) begin : g_row
      assign av[gk][0] = a_valid_in[gk];
      assign ad[gk][0] = a_in_flat[8*gk +: 8];
      assign east_valid[gk] = av[gk][8];
      assign east_data[8*gk +: 8] = ad[gk][8];
      for (gn = 0; gn < 8; gn = gn + 1) begin : g_col
        slm_gemm_pe u_pe (
          .clk         (clk),
          .rst_n       (rst_n),
          .w_load      (w_load_row[gk]),
          .w_in        (w_in_flat[8*gn +: 8]),
          .a_valid     (av[gk][gn]),
          .a_in        (ad[gk][gn]),
          .psum_in     (ps[gk][gn]),
          .a_valid_out (av[gk][gn+1]),
          .a_out       (ad[gk][gn+1]),
          .psum_out    (ps[gk+1][gn])
        );
      end
    end
  endgenerate

  // East-edge activation outputs leave the array unused.
  wire _unused = &{1'b0, east_valid, east_data};

endmodule

`default_nettype wire
