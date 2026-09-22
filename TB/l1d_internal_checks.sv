// Internal-state invariants for one L1D cache instance. Bound (not
// instantiated directly) into L1_cache1/L1_cache2 in tb_L1D_1.sv/tb_L1D_2.sv
// so it can see each DUT's arrays/FSM state regardless of the "1"/"2"
// naming each file happens to use for them.
import tilelink_pkg::*;

module l1d_internal_checks #(
    parameter int NUM_LINES  = 16,
    parameter int L1_SETS    = 8
)(
    input logic       clk,
    input logic       rst,
    input perm_t       perms  [0:NUM_LINES-1],
    input logic        dirty  [0:NUM_LINES-1],
    input logic        hit_way0,
    input logic        hit_way1,
    input logic [2:0]  miss_state,   // IDLE=0 EVICT=1 REQUEST=2 RELEASE_WAIT=3 WAIT=6 ACK=7
    input logic        probe_state   // PROBE_IDLE=0 PROBE_SEND=1
);

    localparam logic [2:0] IDLE         = 3'b000;
    localparam logic [2:0] EVICT        = 3'b001;
    localparam logic [2:0] RELEASE_WAIT = 3'b011;
    localparam logic [2:0] REQUEST      = 3'b010;
    localparam logic [2:0] WAIT         = 3'b110;
    localparam logic [2:0] ACK          = 3'b111;

    // a set's two ways can never both report a tag hit at once
    hit_ways_exclusive: assert property (
        @(posedge clk) disable iff (rst) !(hit_way0 && hit_way1)
    ) else $error("hit_way0 and hit_way1 both asserted");

    // dirty is only meaningful (and only ever set) under Tip permission
    genvar i;
    generate
        for (i = 0; i < NUM_LINES; i++) begin : g_dirty_implies_tip
            dirty_implies_tip: assert property (
                @(posedge clk) disable iff (rst) dirty[i] |-> (perms[i] == PERM_T)
            ) else $error("line %0d dirty but not in PERM_T", i);
        end
    endgenerate

    // miss_state must only ever take one of the six encoded values, and
    // must only move along an edge the FSM's case statement actually has
    function automatic bit legal_transition(logic [2:0] from, logic [2:0] to);
        case (from)
            IDLE:         legal_transition = (to == IDLE)  || (to == EVICT) || (to == REQUEST);
            EVICT:        legal_transition = (to == EVICT) || (to == RELEASE_WAIT);
            RELEASE_WAIT: legal_transition = (to == RELEASE_WAIT) || (to == REQUEST);
            REQUEST:      legal_transition = (to == REQUEST) || (to == WAIT);
            WAIT:         legal_transition = (to == WAIT) || (to == ACK);
            ACK:          legal_transition = (to == ACK) || (to == IDLE);
            default:      legal_transition = 1'b0;
        endcase
    endfunction

    miss_state_known: assert property (
        @(posedge clk) disable iff (rst) !$isunknown(miss_state)
    ) else $error("miss_state is X/Z");

    miss_state_legal_transition: assert property (
        @(posedge clk) disable iff (rst)
        legal_transition($past(miss_state), miss_state)
    ) else $error("illegal miss_state transition %0d -> %0d", $past(miss_state), miss_state);

    probe_state_known: assert property (
        @(posedge clk) disable iff (rst) !$isunknown(probe_state)
    ) else $error("probe_state is X/Z");

endmodule
