// L2 controller: the interconnect between the L1 caches and l2_cache's
// single set of L1-facing TileLink ports.
//
//   A, C, E (L1 -> L2): many senders, one receiver. A round-robin arbiter
//                       per channel picks which L1 gets through, rotating
//                       priority so no L1 can starve the others.
//   B, D    (L2 -> L1): one sender, many receivers. Routed to the L1 whose
//                       port index equals the message's source field.
//
// Port i on the L1 side belongs to the L1 whose fixed TileLink source id
// is i, which is what lets B/D be routed back by source.
//
// Channel priority E > D > C > B > A: a channel may only START presenting a
// new message while no higher-priority channel has one waiting. Once a
// message is presented it is never retracted (TileLink requires valid and
// payload to hold until ready), and each channel still has its own wires,
// so a lower channel can never block a higher one. That's the TileLink
// forward-progress rule: a message only ever waits on higher channels.
module l2_controller
import tilelink_pkg::*;
#(
    parameter int N_L1 = 2**SOURCE_WIDTH // one port per possible source id
)(
    input  logic clk,
    input  logic rst,

    // channel A facing L1s
    input  channel_a        l1_a       [0:N_L1-1],
    input  logic [N_L1-1:0] l1_a_valid,
    output logic [N_L1-1:0] l1_a_ready,

    // channel B facing L1s
    output channel_b        l1_b       [0:N_L1-1],
    output logic [N_L1-1:0] l1_b_valid,
    input  logic [N_L1-1:0] l1_b_ready,

    // channel C facing L1s
    input  channel_c        l1_c       [0:N_L1-1],
    input  logic [N_L1-1:0] l1_c_valid,
    output logic [N_L1-1:0] l1_c_ready,

    // channel D facing L1s
    output channel_d        l1_d       [0:N_L1-1],
    output logic [N_L1-1:0] l1_d_valid,
    input  logic [N_L1-1:0] l1_d_ready,

    // channel E facing L1s
    input  channel_e        l1_e       [0:N_L1-1],
    input  logic [N_L1-1:0] l1_e_valid,
    output logic [N_L1-1:0] l1_e_ready,

    // channel A facing L2
    output channel_a l2_a,
    output logic     l2_a_valid,
    input  logic     l2_a_ready,

    // channel B facing L2
    input  channel_b l2_b,
    input  logic     l2_b_valid,
    output logic     l2_b_ready,

    // channel C facing L2
    output channel_c l2_c,
    output logic     l2_c_valid,
    input  logic     l2_c_ready,

    // channel D facing L2
    input  channel_d l2_d,
    input  logic     l2_d_valid,
    output logic     l2_d_ready,

    // channel E facing L2
    output channel_e l2_e,
    output logic     l2_e_valid,
    input  logic     l2_e_ready
);

    // ------------------------------------------------------------------
    // channel priority. "pending" means a sender has valid up on that
    // channel, whether or not its message has been presented yet
    // ------------------------------------------------------------------
    logic e_pend, d_pend, c_pend, b_pend;
    logic e_start_ok, d_start_ok, c_start_ok, b_start_ok, a_start_ok;

    assign e_pend = |l1_e_valid;
    assign d_pend = l2_d_valid;
    assign c_pend = |l1_c_valid;
    assign b_pend = l2_b_valid;

    assign e_start_ok = 1'b1; // highest priority, never held off
    assign d_start_ok = !e_pend;
    assign c_start_ok = !e_pend && !d_pend;
    assign b_start_ok = !e_pend && !d_pend && !c_pend;
    assign a_start_ok = !e_pend && !d_pend && !c_pend && !b_pend;

    // ------------------------------------------------------------------
    // which messages are multi-beat bursts. opcode encodings overlap
    // between channels, so each channel decodes its own. A burst holds its
    // channel's grant from first beat to last so beats from different L1s
    // never interleave on the same channel
    // ------------------------------------------------------------------
    logic [N_L1-1:0] a_multi, c_multi;
    logic            d_multi;

    always_comb begin
        for (int i = 0; i < N_L1; i++) begin
            a_multi[i] = (l1_a[i].opcode == PUT_FULL_DATA);
            c_multi[i] = (l1_c[i].opcode == PROBE_ACK_DATA) || (l1_c[i].opcode == RELEASE_DATA);
        end
    end
    assign d_multi = (l2_d.opcode == GRANT_DATA) || (l2_d.opcode == ACCESS_ACK_DATA);

    // ------------------------------------------------------------------
    // L1 -> L2 channels: round-robin arbiters
    // ------------------------------------------------------------------
    tl_rr_arbiter #(.T(channel_e), .N(N_L1)) u_arb_e (
        .clk(clk), .rst(rst),
        .in(l1_e), .in_valid(l1_e_valid), .in_ready(l1_e_ready), .in_multi('0),
        .start_ok(e_start_ok),
        .out(l2_e), .out_valid(l2_e_valid), .out_ready(l2_e_ready)
    );

    tl_rr_arbiter #(.T(channel_c), .N(N_L1)) u_arb_c (
        .clk(clk), .rst(rst),
        .in(l1_c), .in_valid(l1_c_valid), .in_ready(l1_c_ready), .in_multi(c_multi),
        .start_ok(c_start_ok),
        .out(l2_c), .out_valid(l2_c_valid), .out_ready(l2_c_ready)
    );

    tl_rr_arbiter #(.T(channel_a), .N(N_L1)) u_arb_a (
        .clk(clk), .rst(rst),
        .in(l1_a), .in_valid(l1_a_valid), .in_ready(l1_a_ready), .in_multi(a_multi),
        .start_ok(a_start_ok),
        .out(l2_a), .out_valid(l2_a_valid), .out_ready(l2_a_ready)
    );

    // ------------------------------------------------------------------
    // L2 -> L1 channels: routed by source
    // ------------------------------------------------------------------
    tl_router #(.T(channel_d), .N(N_L1)) u_route_d (
        .clk(clk), .rst(rst),
        .in(l2_d), .in_valid(l2_d_valid), .in_ready(l2_d_ready),
        .dest(l2_d.source), .in_multi(d_multi), .start_ok(d_start_ok),
        .out(l1_d), .out_valid(l1_d_valid), .out_ready(l1_d_ready)
    );

    tl_router #(.T(channel_b), .N(N_L1)) u_route_b (
        .clk(clk), .rst(rst),
        .in(l2_b), .in_valid(l2_b_valid), .in_ready(l2_b_ready),
        .dest(l2_b.source), .in_multi(1'b0), .start_ok(b_start_ok),
        .out(l1_b), .out_valid(l1_b_valid), .out_ready(l1_b_ready)
    );

endmodule


// ----------------------------------------------------------------------
// Round-robin arbiter for one many-to-one channel. Generic over the
// channel's struct type so A, C and E share one implementation.
//
// rr_ptr is the requester with highest priority for the next new message.
// The search starts there and wraps, and once a message finishes rr_ptr
// moves to one past its winner, so every requester gets a turn.
//
// The winner is sticky. Once its message has been put on the output it
// keeps the grant until the last beat is accepted, even if another
// requester would now win or start_ok drops, because changing the output
// payload (or dropping valid) before ready would break TileLink.
// ----------------------------------------------------------------------
module tl_rr_arbiter
import tilelink_pkg::*;
#(
    parameter type T = channel_a,
    parameter int  N = 4
)(
    input  logic         clk,
    input  logic         rst,

    input  T             in       [0:N-1],
    input  logic [N-1:0] in_valid,
    output logic [N-1:0] in_ready,
    input  logic [N-1:0] in_multi, // in[i]'s current message is a BEATS-long burst
    input  logic         start_ok, // channel priority allows starting a new message this cycle

    output T             out,
    output logic         out_valid,
    input  logic         out_ready
);
    localparam int IDX_BITS  = (N > 1) ? $clog2(N) : 1;
    localparam int BEAT_BITS = $clog2(BEATS);

    logic                 busy;       // a message is on the output and not fully accepted yet
    logic [IDX_BITS-1:0]  owner;      // requester that message belongs to
    logic [IDX_BITS-1:0]  rr_ptr;     // first requester checked when picking a new winner
    logic [BEAT_BITS-1:0] beat_count; // beats of owner's burst already accepted

    logic [IDX_BITS-1:0] pick, sel;
    logic                found, present, fire, last;

    // pick the first valid requester at or after rr_ptr, wrapping around
    always_comb begin
        found = 1'b0;
        pick  = rr_ptr;
        for (int k = 0; k < N; k++) begin
            if (!found && in_valid[(int'(rr_ptr) + k) % N]) begin
                found = 1'b1;
                pick  = IDX_BITS'((int'(rr_ptr) + k) % N);
            end
        end
    end

    assign sel       = busy ? owner : pick;              // a message in progress keeps its requester
    assign present   = busy || (found && start_ok);     // new messages wait on channel priority, in-progress ones don't
    assign out       = in[sel];
    assign out_valid = present && in_valid[sel];
    assign fire      = out_valid && out_ready;
    assign last      = !in_multi[sel] || (beat_count == BEATS-1);

    always_comb begin
        in_ready      = '0;
        in_ready[sel] = present && out_ready; // only the granted requester ever sees ready
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            owner      <= '0;
            rr_ptr     <= '0;
            beat_count <= '0;
        end else if (fire) begin
            if (last) begin
                // message done. hand priority to the requester after this one
                busy       <= 1'b0;
                beat_count <= '0;
                rr_ptr     <= (int'(sel) == N-1) ? '0 : sel + 1'b1;
            end else begin
                busy       <= 1'b1;
                owner      <= sel;
                beat_count <= beat_count + 1'b1;
            end
        end else if (out_valid) begin
            // presented but not accepted: lock the grant so the output can't change under the receiver
            busy  <= 1'b1;
            owner <= sel;
        end
    end

endmodule


// ----------------------------------------------------------------------
// Router for one one-to-many channel (B or D). The payload is broadcast to
// every L1, only valid is steered, to out[dest]. Like the arbiter, once a
// message has been presented it holds until its last beat is accepted,
// regardless of channel priority.
// ----------------------------------------------------------------------
module tl_router
import tilelink_pkg::*;
#(
    parameter type T = channel_d,
    parameter int  N = 4
)(
    input  logic                    clk,
    input  logic                    rst,

    input  T                        in,
    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic [SOURCE_WIDTH-1:0] dest,     // which L1 this message is for
    input  logic                    in_multi, // current message is a BEATS-long burst
    input  logic                    start_ok, // channel priority allows starting a new message this cycle

    output T                        out       [0:N-1],
    output logic [N-1:0]            out_valid,
    input  logic [N-1:0]            out_ready
);
    localparam int BEAT_BITS = $clog2(BEATS);

    logic                 busy;       // a message is on the output and not fully accepted yet
    logic [BEAT_BITS-1:0] beat_count;
    logic                 present, dest_ok, fire, last;

    assign present = busy || start_ok;
    assign dest_ok = (int'(dest) < N); // always true when N == 2**SOURCE_WIDTH
    assign fire    = in_valid && in_ready;
    assign last    = !in_multi || (beat_count == BEATS-1);

    always_comb begin
        for (int i = 0; i < N; i++) begin
            out[i]       = in;
            out_valid[i] = present && in_valid && (int'(dest) == i);
        end
        in_ready = present && dest_ok && out_ready[dest];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            beat_count <= '0;
        end else if (fire) begin
            if (last) begin
                busy       <= 1'b0;
                beat_count <= '0;
            end else begin
                busy       <= 1'b1;
                beat_count <= beat_count + 1'b1;
            end
        end else if (present && in_valid) begin
            busy <= 1'b1; // presented but not accepted: don't let priority retract it
        end
    end

endmodule
