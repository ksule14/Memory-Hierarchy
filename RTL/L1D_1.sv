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
    localparam int OFFSET_BITS = $clog2(LINE_BYTES); // number of bits needed to address each byte in a line
    localparam int INDEX_BITS  = $clog2(L2_SETS); // number of bits needed to select a set
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS; // remaining bits after offset and index
    localparam int BEAT_BITS   = $clog2(BEATS); // number of bits to represent the number of beats on a data transfer

    // cache's fixed TileLink source id
    localparam logic [SOURCE_WIDTH-1:0] L1_ID = 2'd1;

    logic [DATA_WIDTH-1:0] data1  [0:L2_SETS*L2_WAYS-1][0:BEATS-1]; // cache that is 4*DATA_WIDTH wide (16 bytes wide) and 16 rows deep
    logic [TAG_BITS-1:0]   tag1   [0:L2_SETS*L2_WAYS-1]; // tag cache for each row
    logic                  valid1 [0:L2_SETS*L2_WAYS-1]; // valid cache for each row (16 entries)
    logic                  dirty1 [0:L2_SETS*L2_WAYS-1]; // dirty cache for each row (16 entries)
    perm_t                 perms  [0:L2_SETS*L2_WAYS-1]; // permission cache for each row (16 entries)

    // captured when a miss is first detected in IDLE, since ins.something/
    // the tag-hit way aren't guaranteed to still line up once beats
    // start arriving several cycles later
    logic [ADDR_WIDTH-1:0]  saved_addr;
    logic                   saved_way;
    logic [PARAM_WIDTH-1:0] saved_perm;   
    logic [SINK_WIDTH-1:0]  saved_sink;   // bookmark sent by D for D-E transaction. Echoed back on Channel E to close the transaction
    logic [BEAT_BITS-1:0]   beat_count;
    logic                   last_beat;

    logic [OFFSET_BITS-1:0] offset; // selects beat (and byte but we don't use that)
    logic [INDEX_BITS-1:0]  index; // selects set
    logic [TAG_BITS-1:0]    tag; // identifies correct line
    logic [BEAT_BITS-1:0]   beat_sel; // beat within line

    logic hit_way0, hit_way1;
    logic tag_hit, hit_way, perm_ok, hit, wr_en;

    assign offset   = ins.addr[OFFSET_BITS-1:0];
    assign index    = ins.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign tag      = ins.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    // equates to offset[3:2]. bits 0-1 choose byte, bits 3-2 choose beat which is what we want
    assign beat_sel = offset[OFFSET_BITS-1:$clog2(DATA_WIDTH/8)]; // which beat within the line this word lives in

    // tag match only, independent of what permission we currently hold on it
    assign hit_way0 = valid1[{index, 1'b0}] && (tag1[{index, 1'b0}] == tag); // append 0 to choose set and way0
    assign hit_way1 = valid1[{index, 1'b1}] && (tag1[{index, 1'b1}] == tag); // append 1 to choose set and way1
    assign tag_hit  = hit_way0 || hit_way1;
    // hit_way0/hit_way1 are mutually exclusive for a valid cache, so this also
    // correctly defaults to way 0 on a true miss (tag_hit == 0)
    assign hit_way  = hit_way1;

    // a load is satisfied by either B or T; a store needs exclusive (T) permission
    assign perm_ok = ins.opcode ? (perms[{index, hit_way}] == PERM_T)
                                 : (perms[{index, hit_way}] != PERM_N);
    assign hit = tag_hit && perm_ok;
    assign wr_en = hit && ins.opcode; // store hit means write CPU data into the line

    assign last_beat = (beat_count == BEATS-1);

    // states for cache miss FSM
    typedef enum logic [1:0] {
        IDLE    = 00,
        REQUEST = 01, 
        WAIT    = 11, 
        ACK     = 10
    } miss_t;

    miss_t miss_state, next_miss_state;

    always_ff @(posedge clk) begin
        if (rst) miss_state <= IDLE;
        else     miss_state <= next_miss_state;
    end

    // ------------------------------------------------------------------
    // CPU-facing outputs. outs.stall tracks hit=false. true both
    // on the first cycle a miss is discovered (miss_state still IDLE that
    // cycle) and for every cycle the fill is outstanding after that, since
    // hit stays low until the tag/valid/perm arrays are updated in ACK.
    // Assumes the CPU holds ins stable while stall is asserted.
    // ------------------------------------------------------------------
    always_comb begin
        outs.rdata = hit ? data1[{index, hit_way}][beat_sel] : '0; // assign output value depending on hit or miss
        outs.stall = !hit; // stall when miss
    end

    // store hit: write through into the array and mark the line dirty
    always_ff @(posedge clk) begin
        if (wr_en) begin
            data1[{index, hit_way}][beat_sel] <= ins.st_data;
            dirty1[{index, hit_way}]          <= 1'b1;
        end
    end

    // valid/ready for the channels miss FSM drives
    assign chan_a_valid = (miss_state == REQUEST); // when channel A ACQUIRE is sent to L2
    assign chan_d_ready = (miss_state == WAIT); // when D sends GRANT/GRANTDATA
    assign chan_e_valid = (miss_state == ACK); // when E responds with sink

    // ------------------------------------------------------------------
    // Next-state logic only, no outputs driven here
    // ------------------------------------------------------------------
    always_comb begin
        next_miss_state = miss_state;
        case (miss_state)
            IDLE: begin
                if (!hit) next_miss_state = REQUEST; // miss this cycle, request gets latched below
            end

            REQUEST: begin
                if (chan_a_valid && chan_a_ready) next_miss_state = WAIT; // L2 accepted the Acquire with successful handshake
            end

            WAIT: begin
                if (chan_d_valid && chan_d_ready) begin
                    case (chan_d.opcode)
                        GRANT:      next_miss_state = ACK;                // PERM-only reply, done in one beat
                        GRANT_DATA: if (last_beat) next_miss_state = ACK; // wait out all beats for ACQUIRE-PERM
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
    // Sequential datapath: builds the Acquire on A, captures Channel D
    // beats into data1, commits the tag/valid/perm arrays, and drives the
    // GrantAck on E.
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
                    // latch everything the rest of the transaction needs
                    // ins.addr isn't guaranteed to still be this request
                    // once transaction several cycles into WAIT
                    saved_addr <= ins.addr;
                    saved_way  <= hit_way; // on miss it fills way0

                    chan_a.size    <= SIZE_WIDTH'($clog2(LINE_BYTES));
                    chan_a.source  <= L1_ID;
                    chan_a.addr    <= ins.addr;
                    chan_a.mask    <= '0; // whole-line transfers only, never a partial write mask
                    chan_a.data    <= '0; // Acquire carries no data - it comes back on GrantDATA
                    chan_a.corrupt <= '0;

                    if (tag_hit) begin
                        // already hold the line, just need more permission.
                        // Only reachable upgrade is B->T (a store
                        // following an earlier load), since nothing
                        // downgrades permissions yet.
                        chan_a.opcode <= ACQUIRE_PERM;
                        chan_a.param  <= B_TO_T; // store needs TIP permission
                    end else begin
                        // don't have the line at all. fetch it plus the
                        // minimum permission the access needs
                        chan_a.opcode <= ACQUIRE_BLOCK;
                        chan_a.param  <= ins.opcode ? N_TO_T : N_TO_B; // store needs TIP, load needs BRANCH
                    end
                end
            end

            REQUEST: begin
                beat_count <= '0; // ensures counting in WAIT starts at 0
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

            // Channel B-C's permission-downgrade commit lives here rather
            // than in the probe FSM's own always_ff below, even though
            // it's that FSM's decision - perms/dirty1 already have this
            // block as their writer, and a variable can only have one
            // procedural driver, so a second always_ff writing them (even
            // at different indices) is a multiple-driver error.
            if (probe_state == PROBE_SEND && chan_c_valid && chan_c_ready) begin
                perms[{probe_reg_index, probe_way}] <= probe_new_perm;
                if (probe_send_data) dirty1[{probe_reg_index, probe_way}] <= 1'b0;
            end
        end
    end

    // CHANNEL B-C TRANSACTION (Probe / ProbeAck(Data))

    // Decode the incoming probe the same way the main datapath decodes
    // ins.addr, but off the *live* chan_b bus - chan_b isn't guaranteed to
    // still be around once we've moved past PROBE_IDLE, which is exactly
    // why the capture below latches everything derived from it.
    logic [INDEX_BITS-1:0]  probe_in_index;
    logic [TAG_BITS-1:0]    probe_in_tag;
    logic                   probe_in_way; // L2 only ever probes a line we actually hold, so exactly one way matches
    perm_t                  probe_in_cur_perm, probe_in_cap_level, probe_in_new_perm;
    logic [PARAM_WIDTH-1:0] probe_in_resp_param;

    assign probe_in_index = chan_b.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign probe_in_tag   = chan_b.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    assign probe_in_way   = valid1[{probe_in_index, 1'b1}] && (tag1[{probe_in_index, 1'b1}] == probe_in_tag);

    assign probe_in_cur_perm  = perms[{probe_in_index, probe_in_way}];
    // cap_t's encoding (TO_T=0/TO_B=1/TO_N=2) isn't perm-ordered, so translate
    // it to a perm_t ceiling before comparing against what we currently hold
    assign probe_in_cap_level = (chan_b.param == TO_T) ? PERM_T :
                                 (chan_b.param == TO_B) ? PERM_B : PERM_N;
    // perm_t is ordered N < B < T numerically, so the resulting permission
    // is just whichever of the two is smaller
    assign probe_in_new_perm  = (probe_in_cur_perm < probe_in_cap_level) ? probe_in_cur_perm : probe_in_cap_level;

    always_comb begin
        if (probe_in_new_perm != probe_in_cur_perm) begin
            // actually downgrading - report the transition with a shrink_t code
            case (probe_in_cur_perm)
                PERM_T:  probe_in_resp_param = (probe_in_new_perm == PERM_B) ? T_TO_B : T_TO_N;
                default: probe_in_resp_param = B_TO_N; // only B->N can shrink further from here
            endcase
        end else begin
            // already at or below the requested cap - report_t, no real change
            case (probe_in_cur_perm)
                PERM_T:  probe_in_resp_param = T_TO_T;
                PERM_B:  probe_in_resp_param = B_TO_B;
                default: probe_in_resp_param = N_TO_N;
            endcase
        end
    end

    // own beat counter for ProbeAckData because it must not share the miss FSM's
    // beat_count/last_beat, since a probe can be in flight independently of an Acquire
    logic [BEAT_BITS-1:0] probe_beat_count;
    logic                 probe_last_beat;
    assign probe_last_beat = (probe_beat_count == BEATS-1);

    // captured in PROBE_IDLE - safe to latch off chan_b before ready ever
    // asserts, since valid/ready requires the source to hold chan_b stable
    // from the moment valid goes high until we accept it in PROBE_RECEIVE
    logic [ADDR_WIDTH-1:0]  probe_addr;
    logic                   probe_way;
    logic                   probe_send_data;   // PROBE_ACK_DATA vs plain PROBE_ACK
    logic [PARAM_WIDTH-1:0] probe_resp_param;
    perm_t                  probe_new_perm;
    logic [SIZE_WIDTH-1:0]  probe_size;

    logic [INDEX_BITS-1:0] probe_reg_index;
    assign probe_reg_index = probe_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];

    typedef enum logic [1:0] {
        PROBE_IDLE, PROBE_RECEIVE, PROBE_SEND
    } b_probe_t;

    b_probe_t probe_state;
    b_probe_t next_probe_state;

    // ready/valid for the channels this FSM drives, straight off the state -
    // same pattern as chan_a_valid/chan_d_ready/chan_e_valid above
    assign chan_b_ready = (probe_state == PROBE_RECEIVE);
    assign chan_c_valid = (probe_state == PROBE_SEND);

    always_ff @(posedge clk) begin
        if (rst) probe_state <= PROBE_IDLE;
        else probe_state <= next_probe_state;
    end

    always_comb begin
        next_probe_state = probe_state;
        case (probe_state)
            PROBE_IDLE: begin
                if (chan_b_valid) next_probe_state = PROBE_RECEIVE;
            end

            PROBE_RECEIVE: begin
                if (chan_b_valid && chan_b_ready) next_probe_state = PROBE_SEND;
            end

            PROBE_SEND: begin
                // no need for an ack state here because channel C is itself
                // the acknowledgement - there's no channel E equivalent.
                // Only a dirty ProbeBlock's ProbeAckData spans multiple
                // beats; a plain ProbeAck (clean line, or any ProbePerm)
                // always leaves after just one.
                if (chan_c_valid && chan_c_ready) begin
                    if (!probe_send_data || probe_last_beat) next_probe_state = PROBE_IDLE;
                end
            end

            default: next_probe_state = PROBE_IDLE;
        endcase
    end

    // Probe-private datapath - none of these registers are touched by the
    // miss FSM, so this can safely be its own always_ff. perms/dirty1
    // themselves are deliberately NOT written here even though this is
    // where their new values are decided; see the note above the miss FSM's
    // always_ff for why that write lives there instead.
    always_ff @(posedge clk) begin
        if (rst) begin
            probe_addr       <= '0;
            probe_way        <= '0;
            probe_send_data  <= 1'b0;
            probe_resp_param <= '0;
            probe_new_perm   <= PERM_N;
            probe_size       <= '0;
            probe_beat_count <= '0;
        end else begin
            case (probe_state)
            PROBE_IDLE: begin
                if (chan_b_valid) begin
                    probe_addr       <= chan_b.addr;
                    probe_way        <= probe_in_way;
                    probe_send_data  <= (chan_b.opcode == PROBE_BLOCK) && dirty1[{probe_in_index, probe_in_way}];
                    probe_resp_param <= probe_in_resp_param;
                    probe_new_perm   <= probe_in_new_perm;
                    probe_size       <= chan_b.size;
                    probe_beat_count <= '0; // defensive: start PROBE_SEND counting from 0
                end
            end

            PROBE_SEND: begin
                if (chan_c_valid && chan_c_ready) begin
                    probe_beat_count <= probe_beat_count + 1'b1; // irrelevant once a single-beat ProbeAck has already left PROBE_SEND
                end
            end
            endcase
        end
    end

    // Channel C content - combinational off the probe-private registers
    // above, same idea as outs.rdata reading data1 combinationally
    always_comb begin
        chan_c.opcode  = probe_send_data ? PROBE_ACK_DATA : PROBE_ACK;
        chan_c.param   = probe_resp_param;
        chan_c.size    = probe_size;
        chan_c.source  = L1_ID;
        chan_c.addr    = probe_addr;
        chan_c.data    = probe_send_data ? data1[{probe_reg_index, probe_way}][probe_beat_count] : '0;
        chan_c.corrupt = 1'b0;
    end

endmodule