// =============================================================================
// cdc_sync.v
//
// Clock domain crossing: axi_clk (pl_clk0, ~96 MHz) <-> dac_clk (clk_dac0, ~32 MHz)
//
// Forward path  axi_clk -> dac_clk:
//   ctrl_mode, ctrl_infinite : two-flop synchronisers (stable levels)
//   ctrl_written             : toggle synchroniser    (pulse)
//   ctrl_rep_count           : captured in dac_clk on synchronised pulse edge
//
// Reverse path  dac_clk -> axi_clk:
//   stat_busy                : two-flop synchroniser  (stable level)
//   stat_done                : two-flop synchroniser  (stable level, held high)
//   stat_rep_done            : captured in axi_clk on rising edge of synced done
//
// (* ASYNC_REG = "TRUE" *) on all synchroniser flip-flops prevents Vivado
// from optimising them away and flags them to the timing analyser so it can
// apply the correct multicycle path exceptions automatically.
// =============================================================================

module cdc_sync (
    // pl_clk0 domain
    input  wire        axi_clk,
    input  wire        axi_resetn,    // active-low

    // clk_dac0 domain
    input  wire        dac_clk,
    input  wire        dac_resetn,    // active-low

    // ------- Inputs from replay_ctrl_axi  (axi_clk) -------------------------
    input  wire        src_mode,
    input  wire        src_infinite,
    input  wire [31:0] src_rep_count,
    input  wire        src_written,   // one-cycle pulse in axi_clk

    // ------- Outputs to replay_ctrl_bram  (dac_clk) -------------------------
    output reg         dst_mode,
    output reg         dst_infinite,
    output reg  [31:0] dst_rep_count,
    output wire        dst_written,   // one-cycle pulse in dac_clk

    // ------- Inputs from replay_ctrl_bram  (dac_clk) ------------------------
    input  wire        src_busy,
    input  wire        src_done,
    input  wire [31:0] src_rep_done,

    // ------- Outputs to replay_ctrl_axi  (axi_clk) --------------------------
    output reg         dst_busy,
    output reg         dst_done,
    output reg  [31:0] dst_rep_done
);

// =============================================================================
// FORWARD PATH  axi_clk -> dac_clk
// =============================================================================

// -----------------------------------------------------------------------------
// ctrl_written: toggle synchroniser
//
// In axi_clk:  each pulse toggles a register.
// In dac_clk:  two-flop sync on the toggle, then XOR with previous value
//              to regenerate a one-cycle pulse.
// This is safe regardless of the clock ratio because the toggle holds state
// between pulses — no pulse can be lost even if dac_clk is much slower.
// -----------------------------------------------------------------------------

reg toggle_r = 1'b0;

always @(posedge axi_clk or negedge axi_resetn) begin
    if (!axi_resetn)
        toggle_r <= 1'b0;
    else if (src_written)
        toggle_r <= ~toggle_r;
end

(* ASYNC_REG = "TRUE" *) reg toggle_sync1 = 1'b0;
(* ASYNC_REG = "TRUE" *) reg toggle_sync2 = 1'b0;
                         reg toggle_prev  = 1'b0;

always @(posedge dac_clk or negedge dac_resetn) begin
    if (!dac_resetn) begin
        toggle_sync1 <= 1'b0;
        toggle_sync2 <= 1'b0;
        toggle_prev  <= 1'b0;
    end else begin
        toggle_sync1 <= toggle_r;
        toggle_sync2 <= toggle_sync1;
        toggle_prev  <= toggle_sync2;
    end
end

// One-cycle pulse in dac_clk whenever the synchronised toggle changes
assign dst_written = toggle_sync2 ^ toggle_prev;

// -----------------------------------------------------------------------------
// ctrl_mode, ctrl_infinite: two-flop synchronisers
//
// Safe because these are stable registered outputs that only change when
// ctrl_written fires.  The toggle sync for ctrl_written arrives in dac_clk
// after these levels have been stable for multiple dac_clk cycles
// (since dac_clk < axi_clk).  The datapath samples them on dst_written.
// -----------------------------------------------------------------------------

(* ASYNC_REG = "TRUE" *) reg mode_sync1 = 1'b0;
(* ASYNC_REG = "TRUE" *) reg inf_sync1  = 1'b0;

always @(posedge dac_clk or negedge dac_resetn) begin
    if (!dac_resetn) begin
        mode_sync1  <= 1'b0;
        dst_mode    <= 1'b0;
        inf_sync1   <= 1'b0;
        dst_infinite <= 1'b0;
    end else begin
        mode_sync1   <= src_mode;
        dst_mode     <= mode_sync1;
        inf_sync1    <= src_infinite;
        dst_infinite <= inf_sync1;
    end
end

// -----------------------------------------------------------------------------
// ctrl_rep_count: captured on the synchronised dst_written pulse
//
// The PS write contract: REP_COUNT is written before CTRL, so it has been
// stable in axi_clk for at least one full AXI write cycle before
// src_written pulses.  Because dac_clk is slower, by the time dst_written
// fires in dac_clk, src_rep_count has been stable for many dac_clk periods.
// No grey-code encoding or full handshake needed.
// -----------------------------------------------------------------------------

always @(posedge dac_clk or negedge dac_resetn) begin
    if (!dac_resetn)
        dst_rep_count <= 32'h0;
    else if (dst_written)
        dst_rep_count <= src_rep_count;
end

// =============================================================================
// REVERSE PATH  dac_clk -> axi_clk
// =============================================================================

// -----------------------------------------------------------------------------
// stat_busy: two-flop synchroniser (stable level, can change slowly)
// -----------------------------------------------------------------------------

(* ASYNC_REG = "TRUE" *) reg busy_sync1 = 1'b0;

always @(posedge axi_clk or negedge axi_resetn) begin
    if (!axi_resetn) begin
        busy_sync1 <= 1'b0;
        dst_busy   <= 1'b0;
    end else begin
        busy_sync1 <= src_busy;
        dst_busy   <= busy_sync1;
    end
end

// -----------------------------------------------------------------------------
// stat_done: two-flop synchroniser
//
// stat_done is held high by the datapath until the PS writes CTRL again
// (ctrl_written clears it).  This means it is a stable level by the time
// it is sampled in axi_clk — no pulse sync needed.
// -----------------------------------------------------------------------------

(* ASYNC_REG = "TRUE" *) reg done_sync1 = 1'b0;
                         reg done_prev  = 1'b0;

always @(posedge axi_clk or negedge axi_resetn) begin
    if (!axi_resetn) begin
        done_sync1 <= 1'b0;
        dst_done   <= 1'b0;
        done_prev  <= 1'b0;
    end else begin
        done_sync1 <= src_done;
        dst_done   <= done_sync1;
        done_prev  <= dst_done;
    end
end

// -----------------------------------------------------------------------------
// stat_rep_done: captured in axi_clk on the rising edge of synchronised done
//
// rep_done is stable in dac_clk from the moment replay completes and stays
// stable until ctrl_written resets it.  axi_clk is faster than dac_clk, so
// by the time the rising edge of done_sync propagates to axi_clk and is
// detected, rep_done has been stable for many axi_clk cycles.
// Capture it once on the done rising edge so the PS always reads a
// consistent snapshot.
// -----------------------------------------------------------------------------

always @(posedge axi_clk or negedge axi_resetn) begin
    if (!axi_resetn)
        dst_rep_done <= 32'h0;
    else if (dst_done && !done_prev)   // rising edge of synchronised done
        dst_rep_done <= src_rep_done;
end

endmodule
