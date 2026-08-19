module L1_cache1
import tilelink_pkg::*;
(
    input  logic      clk,
    input  logic      rst,
    input  cpu_req_t  ins,
    output cpu_resp_t outs,

    // channel A
    output channel_a chan_a,
    output logic     chan_a_valid,
    input  logic     chan_a_ready,

    // channel B
    input  channel_b chan_b,
    input  logic     chan_b_valid,
    output logic     chan_b_ready,

    // channel C
    output channel_c chan_c,
    output logic     chan_c_valid,
    input  logic     chan_c_ready,

    // channel D
    input  channel_d chan_d,
    input  logic     chan_d_valid,
    output logic     chan_d_ready,

    // channel E
    output channel_e chan_e,
    output logic     chan_e_valid,
    input  logic     chan_e_ready
);

    localparam int L2_SETS     = 8;
    localparam int L2_WAYS     = 2;
    localparam int OFFSET_BITS = $clog2(LINE_BYTES);
    localparam int INDEX_BITS  = $clog2(L2_SETS);
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
    localparam int L2_LINE_AW  = $clog2(L2_SETS * L2_WAYS);
    localparam int BEAT_BITS   = $clog2(BEATS);

    // cache's fixed TileLink source id
    localparam logic [SOURCE_WIDTH-1:0] L1_ID = 2'd1;

    logic [DATA_WIDTH-1:0] data1  [0:L2_SETS*L2_WAYS-1][0:BEATS-1];
    logic [TAG_BITS-1:0]   tag1   [0:L2_SETS*L2_WAYS-1];
    logic                  valid1 [0:L2_SETS*L2_WAYS-1];
    logic                  dirty1 [0:L2_SETS*L2_WAYS-1];
    perm_t                 perms  [0:L2_SETS*L2_WAYS-1];

    // captured when a miss is first detected in IDLE, since ins.* /
    // the tag-hit way aren't guaranteed to still line up once beats
    // start arriving several cycles later
    logic [ADDR_WIDTH-1:0]  saved_addr;
    logic                   saved_way;
    logic [PARAM_WIDTH-1:0] saved_perm;   // cap_t reported by L2 in Grant/GrantData
    logic [SINK_WIDTH-1:0]  saved_sink;   // echoed back on Channel E to close the transaction
    logic [BEAT_BITS-1:0]   beat_count;
    logic                   last_beat;

    logic [OFFSET_BITS-1:0] offset;
    logic [INDEX_BITS-1:0]  index;
    logic [TAG_BITS-1:0]    tag;
    logic [BEAT_BITS-1:0]   beat_sel;

    logic hit_way0, hit_way1;
    logic tag_hit, hit_way, perm_ok, hit, wr_en;

    assign offset   = ins.addr[OFFSET_BITS-1:0];
    assign index    = ins.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign tag      = ins.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    assign beat_sel = offset[OFFSET_BITS-1:$clog2(DATA_WIDTH/8)]; // which beat within the line this word lives in

    // tag match only, independent of what permission we currently hold on it
    assign hit_way0 = valid1[{index, 1'b0}] && (tag1[{index, 1'b0}] == tag);
    assign hit_way1 = valid1[{index, 1'b1}] && (tag1[{index, 1'b1}] == tag);
    assign tag_hit  = hit_way0 || hit_way1;
    // hit_way0/hit_way1 are mutually exclusive for a valid cache, so this also
    // correctly defaults to way 0 on a true miss (tag_hit == 0) - our fixed
    // fill target below, since there's no replacement policy yet
    assign hit_way  = hit_way1;

    // a load is satisfied by either B or T; a store needs exclusive (T) permission
    assign perm_ok = ins.opcode ? (perms[{index, hit_way}] == PERM_T)
                                 : (perms[{index, hit_way}] != PERM_N);
    assign hit = tag_hit && perm_ok;
    assign wr_en = hit && ins.opcode; // store hit -> write CPU data into the line

    assign last_beat = (beat_count == BEATS-1);

    typedef enum logic [1:0] {
        IDLE, REQUEST, WAIT, ACK
    } miss_t;

    miss_t miss_state, next_miss_state;

    always_ff @(posedge clk) begin
        if (rst) miss_state <= IDLE;
        else     miss_state <= next_miss_state;
    end

    // ------------------------------------------------------------------
    // CPU-facing outputs. outs.stall tracks "no hit right now" - true both
    // on the first cycle a miss is discovered (miss_state still IDLE that
    // cycle) and for every cycle the fill is outstanding after that, since
    // hit stays low until the tag/valid/perm arrays are updated in ACK.
    // Assumes the CPU holds ins stable while stall is asserted.
    // ------------------------------------------------------------------
    always_comb begin
        outs.rdata = hit ? data1[{index, hit_way}][beat_sel] : '0;
        outs.stall = !hit;
    end

    // store hit: write through into the array and mark the line dirty
    always_ff @(posedge clk) begin
        if (wr_en) begin
            data1[{index, hit_way}][beat_sel] <= ins.st_data;
            dirty1[{index, hit_way}]          <= 1'b1;
        end
    end

    // valid/ready for the channels this FSM drives, straight off the state -
    // same pattern as a_ready in main_memory.sv
    assign chan_a_valid = (miss_state == REQUEST);
    assign chan_d_ready = (miss_state == WAIT);
    assign chan_e_valid = (miss_state == ACK);

    // Channel B/C (Probe/ProbeAck) aren't handled by this FSM - that's a
    // separate listener that needs to run concurrently with this one. Tie
    // off for now so these outputs aren't left floating.
    assign chan_b_ready = 1'b0;
    assign chan_c        = '0;
    assign chan_c_valid  = 1'b0;

    // ------------------------------------------------------------------
    // Next-state logic only - no output driving here
    // ------------------------------------------------------------------
    always_comb begin
        next_miss_state = miss_state;
        case (miss_state)
            IDLE: begin
                if (!hit) next_miss_state = REQUEST; // miss this cycle - request gets latched below
            end

            REQUEST: begin
                if (chan_a_valid && chan_a_ready) next_miss_state = WAIT; // L2 accepted the Acquire
            end

            WAIT: begin
                if (chan_d_valid && chan_d_ready) begin
                    case (chan_d.opcode)
                        GRANT:      next_miss_state = ACK;                // perm-only reply, done in one beat
                        GRANT_DATA: if (last_beat) next_miss_state = ACK; // wait out all BEATS beats
                        default:    next_miss_state = miss_state;
                    endcase
                end
            end

            ACK: begin
                if (chan_e_valid && chan_e_ready) next_miss_state = IDLE; // GrantAck accepted, transaction closed
            end

            default: next_miss_state = IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential datapath: builds the Acquire on chan_a, captures Channel D
    // beats into data1, commits the tag/valid/perm arrays, and drives the
    // GrantAck on chan_e.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            saved_addr <= '0;
            saved_way  <= '0;
            saved_perm <= '0;
            saved_sink <= '0;
            beat_count <= '0;
            chan_a     <= '0;
            chan_e     <= '0;
            for (int i = 0; i < L2_SETS*L2_WAYS; i++) valid1[i] <= 1'b0; // avoid X-valued lines looking like hits
        end else begin
            case (miss_state)
            IDLE: begin
                if (!hit) begin
                    // latch everything the rest of the transaction needs -
                    // ins.addr isn't guaranteed to still be this request
                    // once we're several cycles into WAIT
                    saved_addr <= ins.addr;
                    saved_way  <= hit_way; // upgrade -> the way that matched; true miss -> way 0 (see hit_way comment above)

                    chan_a.size    <= SIZE_WIDTH'($clog2(LINE_BYTES));
                    chan_a.source  <= L1_ID;
                    chan_a.addr    <= ins.addr;
                    chan_a.mask    <= '0; // whole-line transfers only, never a partial write mask
                    chan_a.data    <= '0; // Acquire carries no data - it comes back on Grant(Data)
                    chan_a.corrupt <= '0;

                    if (tag_hit) begin
                        // already hold the line, just need more permission.
                        // Only reachable upgrade today is B->T (a store
                        // following an earlier load), since nothing
                        // downgrades permissions yet.
                        chan_a.opcode <= ACQUIRE_PERM;
                        chan_a.param  <= B_TO_T;
                    end else begin
                        // don't have the line at all - fetch it plus the
                        // minimum permission this access needs
                        chan_a.opcode <= ACQUIRE_BLOCK;
                        chan_a.param  <= ins.opcode ? N_TO_T : N_TO_B;
                    end
                end
            end

            REQUEST: begin
                beat_count <= '0; // defensive: make sure we start WAIT counting from 0
            end

            WAIT: begin
                if (chan_d_valid && chan_d_ready) begin
                    // TileLink repeats param/sink on every beat of GrantData,
                    // so capturing them every accepted beat is safe
                    saved_perm <= chan_d.param;
                    saved_sink <= chan_d.sink;

                    if (chan_d.opcode == GRANT_DATA) begin
                        data1[{index, saved_way}][beat_count] <= chan_d.data;
                        beat_count <= beat_count + 1'b1; // wraps back to 0 on the last beat (BEAT_BITS-wide)
                    end
                end
            end

            ACK: begin
                // commit the fill/upgrade while we hold GrantAck valid -
                // idempotent, so it's fine to re-drive every cycle we sit here
                tag1[{index, saved_way}]   <= saved_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
                valid1[{index, saved_way}] <= 1'b1;
                dirty1[{index, saved_way}] <= 1'b0; // freshly filled/upgraded line is clean
                case (saved_perm)
                    TO_T:    perms[{index, saved_way}] <= PERM_T;
                    TO_B:    perms[{index, saved_way}] <= PERM_B;
                    TO_N:    perms[{index, saved_way}] <= PERM_N;
                    default: perms[{index, saved_way}] <= PERM_B;
                endcase

                chan_e.sink <= saved_sink;
            end
            endcase
        end
    end
endmodule
