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

    localparam int L1_SETS     = 8;
    localparam int L1_WAYS     = 2;
    localparam int OFFSET_BITS = $clog2(LINE_BYTES); // number of bits needed to address each byte in a line
    localparam int INDEX_BITS  = $clog2(L1_SETS); // number of bits needed to select a set
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS; // remaining bits after offset and index
    localparam int BEAT_BITS   = $clog2(BEATS); // number of bits to represent the number of beats on a data transfer
    localparam int LINE_BITS   = ADDR_WIDTH - OFFSET_BITS; // tag+index, identifies a whole cache line

    // request buffer depth. Only one Acquire can be outstanding at a time
    // (this L1 has a single TileLink source id), so this buffer is what lets
    // the CPU keep issuing while that one miss is in flight
    localparam int RQ_DEPTH    = 4;
    localparam int RQ_PTR_BITS = $clog2(RQ_DEPTH);

    // cache's fixed TileLink source id
    localparam logic [SOURCE_WIDTH-1:0] L1_ID = 2'd1;

    logic [DATA_WIDTH-1:0] data1  [0:L1_SETS*L1_WAYS-1][0:BEATS-1]; // cache that is 4*DATA_WIDTH wide (16 bytes wide) and 16 rows deep
    logic [TAG_BITS-1:0]   tag1   [0:L1_SETS*L1_WAYS-1]; // tag cache for each row
    logic                  valid1 [0:L1_SETS*L1_WAYS-1]; // valid cache for each row (16 entries)
    logic                  dirty1 [0:L1_SETS*L1_WAYS-1]; // dirty cache for each row (16 entries)
    perm_t                 perms  [0:L1_SETS*L1_WAYS-1]; // permission cache for each row (16 entries)

    // round-robin victim-way pointer, one bit per set. On a true miss
    // (!tag_hit), hit_way is always 0 (see below), so it can't also serve
    // as "which way to fill" -- without this, way 1 could never become
    // valid. Toggled when a true-miss fill (not a same-line permission
    // upgrade) commits.
    logic rr_way1 [0:L1_SETS-1];

    function automatic logic [LINE_BITS-1:0] line_of(input logic [ADDR_WIDTH-1:0] a);
        return a[ADDR_WIDTH-1:OFFSET_BITS];
    endfunction

    // ------------------------------------------------------------------
    // MSHR (miss status holding register). Captured when a miss is
    // allocated. Because the cache is non-blocking, ins has usually moved
    // on to other requests by the time beats arrive, so the miss FSM
    // works ONLY off these saved copies, never off ins/index/tag.
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]  saved_addr;
    logic                   saved_way;
    logic [PARAM_WIDTH-1:0] saved_perm;
    logic [SINK_WIDTH-1:0]  saved_sink;   // bookmark sent by D for D-E transaction. Echoed back on Channel E to close the transaction
    logic [BEAT_BITS-1:0]   beat_count;
    logic                   last_beat;
    logic                   saved_new_fill; // true miss (needs a victim way), as opposed to a same-line upgrade

    // victim line's state, latched alongside saved_addr/saved_way at miss
    // allocation. decides Release vs ReleaseData and the shrink_t param
    // for the voluntary eviction if one is needed
    logic                   saved_evict;       // this miss has to write back a valid victim first
    logic                   saved_evict_dirty;
    logic [PARAM_WIDTH-1:0] saved_evict_param;
    logic [ADDR_WIDTH-1:0]  saved_evict_addr;  // victim's own line address, which is what Release(Data) must carry

    logic [INDEX_BITS-1:0]  saved_index;
    assign saved_index = saved_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];

    assign last_beat = (beat_count == BEATS-1);

    // states for cache miss FSM. EVICT/RELEASE_WAIT only run ahead of
    // REQUEST when the fill has to replace an already-valid line; a
    // same-line permission upgrade (tag_hit but !perm_ok) skips straight
    // to REQUEST since there's nothing to write back.
    //
    // Declared here (ahead of its own always blocks below) because the
    // probe section's evict_c_req needs miss_state/EVICT, and the miss
    // FSM's own blocks need probe_c_req/probe_state from that section --
    // Questa requires each declaration to textually precede every use.
    typedef enum logic [2:0] {
        IDLE         = 3'b000,
        EVICT        = 3'b001,
        RELEASE_WAIT = 3'b011,
        REQUEST      = 3'b010,
        WAIT         = 3'b110,
        ACK          = 3'b111
    } miss_t;

    miss_t miss_state, next_miss_state;

    // CHANNEL B-C TRANSACTION (Probe / ProbeAck(Data))

    // Decode the incoming probe the same way the main datapath decodes
    // the lookup address, but off the live chan_b bus. chan_b isn't guaranteed to
    // still be around after PROBE_IDLE, which is why we capture the data now
    logic [INDEX_BITS-1:0]  probe_in_index;
    logic [TAG_BITS-1:0]    probe_in_tag;
    logic                   probe_in_way; // L2 only ever probes a line we actually hold, so exactly one way matches
    perm_t                  probe_in_cur_perm, probe_in_cap_level, probe_in_new_perm;
    logic [PARAM_WIDTH-1:0] probe_in_resp_param;

    assign probe_in_index = chan_b.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]; // index of address to be probed, used to find matching way
    assign probe_in_tag   = chan_b.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS]; // tag of address to be probed
    assign probe_in_way   = valid1[{probe_in_index, 1'b1}] && (tag1[{probe_in_index, 1'b1}] == probe_in_tag); // if true probe_way = 1, if false probe_way = 0

    assign probe_in_cur_perm  = perms[{probe_in_index, probe_in_way}]; // current permission state of address
    // cap_t's encoding (TO_T=0/TO_B=1/TO_N=2) isn't perm-ordered, so translate
    // it to a perm_t ceiling before comparing against what we currently hold
    assign probe_in_cap_level = (chan_b.param == TO_T) ? PERM_T :
                                 (chan_b.param == TO_B) ? PERM_B : PERM_N; // assign a permission from chan_b cap_t
    // perm_t is ordered N < B < T numerically, so the resulting permission
    // is the smaller permission between current perm and cap perm
    assign probe_in_new_perm  = (probe_in_cur_perm < probe_in_cap_level) ? probe_in_cur_perm : probe_in_cap_level;

    // code for response param on channel C
    always_comb begin
        if (probe_in_new_perm != probe_in_cur_perm) begin
            // actually downgrading, report transition with a shrink_t code
            case (probe_in_cur_perm)
                PERM_T: probe_in_resp_param = (probe_in_new_perm == PERM_B) ? T_TO_B : T_TO_N;
                PERM_B: probe_in_resp_param = B_TO_N;
                default: probe_in_resp_param = B_TO_N;
            endcase
        end else begin
            // already at or below the requested cap report_t, no real change
            case (probe_in_cur_perm)
                PERM_T: probe_in_resp_param = T_TO_T;
                PERM_B: probe_in_resp_param = B_TO_B;
                PERM_N: probe_in_resp_param = N_TO_N;
                default: probe_in_resp_param = N_TO_N;
            endcase
        end
    end

    // own beat counter for ProbeAckData because it must not share the miss FSM's
    // beat_count/last_beat, since a probe can be in flight independently of an Acquire
    logic [BEAT_BITS-1:0] probe_beat_count;
    logic                 probe_last_beat;
    assign probe_last_beat = (probe_beat_count == BEATS-1);

    // captured in PROBE_IDLE, safe to latch off chan_b before ready ever
    // asserts, since valid/ready requires the source to hold chan_b stable
    // from the moment valid goes high until we accept it in PROBE_RECEIVE
    logic [ADDR_WIDTH-1:0]  probe_addr;
    logic                   probe_way;
    logic                   probe_send_data;   // PROBE_ACK_DATA vs plain PROBE_ACK
    logic [PARAM_WIDTH-1:0] probe_resp_param;
    perm_t                  probe_new_perm;
    logic [SIZE_WIDTH-1:0]  probe_size;

    logic [INDEX_BITS-1:0] probe_reg_index;
    assign probe_reg_index = probe_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]; // used to store permission change

    // FSM for Channel B-C transaction
    typedef enum logic {
        PROBE_IDLE = 1'b0,
        PROBE_SEND = 1'b1
    } b_probe_t;

    b_probe_t probe_state;
    b_probe_t next_probe_state;

    // ready/valid for the channels this FSM drives, based on probe_state
    // same pattern as chan_a_valid/chan_d_ready/chan_e_valid
    assign chan_b_ready = 'b1; // always high to avoid deadlock with two L1s.

    // Channel C now has two logical sources. This probe FSM and the miss
    // FSM's EVICT state (voluntary Release/ReleaseData). Both are funneled
    // through this one arbitrated assign so chan_c/chan_c_valid still only
    // has a single driver. Probe has priority over miss to avoid deadlock
    logic probe_c_req, evict_c_req;
    assign probe_c_req  = (probe_state == PROBE_SEND); // channel C is actively responding to probe
    assign evict_c_req  = (miss_state == EVICT); // channel C is actively releasing
    assign chan_c_valid = probe_c_req || evict_c_req;

    always_ff @(posedge clk) begin
        if (rst) probe_state <= PROBE_IDLE;
        else probe_state <= next_probe_state;
    end

    always_comb begin
        next_probe_state = probe_state;
        case (probe_state)
            PROBE_IDLE: begin
                if (chan_b_valid) next_probe_state = PROBE_SEND; // proceed if channel b wants to initiate transaction
            end

            PROBE_SEND: begin
                // no need for an ack state here because channel C is itself
                // the acknowledgement so there's no channel E equivalent.
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

    // Probe-private datapath. none of these registers are touched by the
    // miss FSM, so this can safely be its own always_ff. perms/dirty1
    // themselves are deliberately NOT written here even though this is
    // where their new values are decided. Did this to avoid multiple drivers error.
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
                    if (chan_b_valid) begin // capture everything when data is valid
                        probe_addr       <= chan_b.addr;
                        probe_way        <= probe_in_way;
                        probe_send_data  <= (chan_b.opcode == PROBE_BLOCK) && dirty1[{probe_in_index, probe_in_way}];
                        probe_resp_param <= probe_in_resp_param;
                        probe_new_perm   <= probe_in_new_perm;
                        probe_size       <= chan_b.size;
                        probe_beat_count <= '0; // defensive, start PROBE_SEND counting from 0
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

    // line the probe FSM is currently working on. Covers both the capture
    // cycle (PROBE_IDLE with chan_b_valid, when dirty1/perms are sampled)
    // and every PROBE_SEND cycle (when data1 is streamed out). The CPU side
    // must not hit this line during that window, otherwise a store could
    // land after the probe already sampled dirty/sent the data and be lost.
    logic                 probe_active;
    logic [LINE_BITS-1:0] probe_line;
    assign probe_active = (probe_state == PROBE_SEND) || chan_b_valid;
    assign probe_line   = (probe_state == PROBE_SEND) ? line_of(probe_addr) : line_of(chan_b.addr);

    // ------------------------------------------------------------------
    // REQUEST BUFFER. A small FIFO that latches CPU requests that can't be
    // finished the cycle they arrive: misses, anything to the same line as
    // a request that is already buffered (keeps same-line program order),
    // anything touching a line the MSHR or probe FSM owns, and anything
    // that arrives while the buffer head is using the lookup port.
    //
    // Invariant: whenever the MSHR is busy (miss_state != IDLE), the
    // request that allocated it is sitting at the head of this buffer. It
    // stays there until the fill commits, then replays as a hit.
    // ------------------------------------------------------------------
    cpu_req_t               rq     [0:RQ_DEPTH-1];
    logic                   rq_vld [0:RQ_DEPTH-1];
    logic [RQ_PTR_BITS-1:0] rq_head, rq_tail;
    logic [RQ_PTR_BITS:0]   rq_count;
    logic                   rq_empty, rq_full;
    cpu_req_t               rq_head_req;

    assign rq_empty    = (rq_count == 0);
    assign rq_full     = (rq_count == RQ_DEPTH);
    assign rq_head_req = rq[rq_head];

    // does this address share a line with any request still in the buffer
    function automatic logic rq_line_match(input logic [ADDR_WIDTH-1:0] a);
        rq_line_match = 1'b0;
        for (int i = 0; i < RQ_DEPTH; i++)
            if (rq_vld[i] && (line_of(rq[i].addr) == line_of(a))) rq_line_match = 1'b1;
    endfunction

    // does this address touch a line the MSHR currently owns: either the
    // line being fetched/upgraded, or the victim being written back. The
    // victim keeps its old tag/valid bits until the fill commits, but its
    // data slot is streamed out by EVICT and then overwritten by GrantData
    // beats, so it can't be hit while the miss is in flight
    function automatic logic mshr_line_match(input logic [ADDR_WIDTH-1:0] a);
        mshr_line_match = (miss_state != IDLE) &&
                          ((line_of(a) == line_of(saved_addr)) ||
                           (saved_evict && (line_of(a) == line_of(saved_evict_addr))));
    endfunction

    function automatic logic probe_line_match(input logic [ADDR_WIDTH-1:0] a);
        probe_line_match = probe_active && (line_of(a) == probe_line);
    endfunction

    // ------------------------------------------------------------------
    // LOOKUP PORT. One tag/data lookup per cycle, shared by the buffer
    // head (replaying) and the new request on ins. The head gets priority
    // whenever it can make progress, i.e. the MSHR is free (so it either
    // hits or allocates the MSHR) and no probe is working on its line.
    // While the MSHR is busy the port belongs to ins, which is what gives
    // hit-under-miss.
    // ------------------------------------------------------------------
    logic     sel_head;   // the lookup this cycle is the buffer head replaying
    cpu_req_t lk;         // request occupying the lookup port
    logic     new_bypass; // ins gets the port directly instead of going into the buffer

    // always_comb rather than assign: the match functions read rq/rq_vld/
    // saved_*/probe state from the module, and only always_comb is
    // sensitive to variables read inside a function body
    always_comb begin
        sel_head   = !rq_empty && (miss_state == IDLE) && !probe_line_match(rq_head_req.addr);
        new_bypass = !sel_head && ins.valid && !rq_line_match(ins.addr) &&
                     !mshr_line_match(ins.addr) && !probe_line_match(ins.addr);
    end
    assign lk = sel_head ? rq_head_req : ins;

    logic [OFFSET_BITS-1:0] offset; // selects beat (and byte but we don't use that)
    logic [INDEX_BITS-1:0]  index; // selects set
    logic [TAG_BITS-1:0]    tag; // identifies correct line
    logic [BEAT_BITS-1:0]   beat_sel; // beat within line

    logic hit_way0, hit_way1;
    logic tag_hit, hit_way, perm_ok, hit, wr_en;
    logic victim_way; // which way a true miss should fill/evict, per the round-robin pointer

    assign offset   = lk.addr[OFFSET_BITS-1:0];
    assign index    = lk.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign tag      = lk.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    // equates to offset[3:2]. bits 0-1 choose byte, bits 3-2 choose beat which is what we want
    assign beat_sel = offset[OFFSET_BITS-1:$clog2(DATA_WIDTH/8)]; // which beat within the line this word lives in

    // tag match only, independent of what permission we currently hold on it
    assign hit_way0 = valid1[{index, 1'b0}] && (tag1[{index, 1'b0}] == tag); // append 0 to choose set and way0
    assign hit_way1 = valid1[{index, 1'b1}] && (tag1[{index, 1'b1}] == tag); // append 1 to choose set and way1
    assign tag_hit  = hit_way0 || hit_way1;
    // hit_way0/hit_way1 are mutually exclusive for a valid cache, so this
    // correctly identifies the hit way whenever tag_hit is true. On a true
    // miss (tag_hit == 0) it's always 0, which is meaningless as a fill
    // target -- victim_way (below) is used for that case instead.
    assign hit_way  = hit_way1;
    assign victim_way = rr_way1[index];

    // a load is satisfied by either B or T; a store needs exclusive (T) permission
    assign perm_ok = lk.opcode ? (perms[{index, hit_way}] == PERM_T)
                               : (perms[{index, hit_way}] != PERM_N);
    assign hit = tag_hit && perm_ok;

    // what the lookup port actually does this cycle
    logic lk_active;  // a real lookup is happening (head replay or bypassing ins)
    logic lk_serve;   // ...and it hits, so the request completes now
    logic mshr_alloc; // ...and it misses with the MSHR free, so start a miss
    logic alloc_evict;
    logic rq_enq, rq_deq;

    assign lk_active  = sel_head || new_bypass;
    assign lk_serve   = lk_active && hit;
    assign wr_en      = lk_serve && lk.opcode; // store hit means write CPU data into the line
    // a bypassing miss may only take the MSHR if nothing older is buffered,
    // otherwise it would jump ahead of the head (and break the invariant)
    assign mshr_alloc = !hit && (sel_head || (new_bypass && rq_empty && (miss_state == IDLE)));
    // a true miss (!tag_hit) targets the round-robin victim way. if that
    // slot already holds a valid line we have to write it back first. A
    // tag_hit (upgrade, or refetch of a line a probe left at N) reuses its
    // own way and never evicts anything.
    assign alloc_evict = !tag_hit && valid1[{index, victim_way}];

    // anything on ins that isn't completed right now gets latched. That
    // includes a bypassing miss, which becomes the new head while it also
    // allocates the MSHR in the same cycle
    assign outs.stall = ins.valid && !(new_bypass && hit) && rq_full;
    assign rq_enq     = ins.valid && !outs.stall && !(new_bypass && hit);
    assign rq_deq     = sel_head && hit;

    always_ff @(posedge clk) begin
        if (rst) begin
            rq_head  <= '0;
            rq_tail  <= '0;
            rq_count <= '0;
            for (int i = 0; i < RQ_DEPTH; i++) rq_vld[i] <= 1'b0;
        end else begin
            if (rq_enq) begin
                rq[rq_tail]     <= ins;
                rq_vld[rq_tail] <= 1'b1;
                rq_tail         <= rq_tail + 1'b1;
            end
            if (rq_deq) begin
                rq_vld[rq_head] <= 1'b0;
                rq_head         <= rq_head + 1'b1;
            end
            rq_count <= rq_count + rq_enq - rq_deq;
        end
    end

    // ------------------------------------------------------------------
    // CPU response. Registered, so a request that completes in the lookup
    // port this cycle shows up on outs.valid for exactly one cycle starting
    // next cycle. Only one lookup per cycle, so only one response per cycle.
    // ------------------------------------------------------------------
    logic                    resp_valid_q;
    logic [CPU_ID_WIDTH-1:0] resp_id_q;
    logic [DATA_WIDTH-1:0]   resp_rdata_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            resp_valid_q <= 1'b0;
            resp_id_q    <= '0;
            resp_rdata_q <= '0;
        end else begin
            resp_valid_q <= lk_serve;
            if (lk_serve) begin
                resp_id_q    <= lk.id;
                resp_rdata_q <= lk.opcode ? '0 : data1[{index, hit_way}][beat_sel];
            end
        end
    end

    assign outs.valid = resp_valid_q;
    assign outs.id    = resp_id_q;
    assign outs.rdata = resp_rdata_q;

    // Channel C content. same probe wins priority as chan_c_valid above
    always_comb begin
        if (probe_c_req) begin
            chan_c.opcode  = probe_send_data ? PROBE_ACK_DATA : PROBE_ACK;
            chan_c.param   = probe_resp_param;
            chan_c.size    = probe_size;
            chan_c.source  = L1_ID;
            chan_c.addr    = probe_addr;
            chan_c.data    = probe_send_data ? data1[{probe_reg_index, probe_way}][probe_beat_count] : '0;
            chan_c.corrupt = '0;
        end else begin
            // evict_c_req. voluntary write back of the line the incoming
            // miss is about to replace. saved_index/saved_way point at the
            // victim's slot. the new line's tag/valid/perm/dirty are only
            // committed later, when the miss FSM's GrantAck is accepted.
            chan_c.opcode  = saved_evict_dirty ? RELEASE_DATA : RELEASE;
            chan_c.param   = saved_evict_param;
            chan_c.size    = SIZE_WIDTH'($clog2(LINE_BYTES));
            chan_c.source  = L1_ID;
            chan_c.addr    = saved_evict_addr;
            chan_c.data    = saved_evict_dirty ? data1[{saved_index, saved_way}][beat_count] : '0;
            chan_c.corrupt = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) miss_state <= IDLE;
        else     miss_state <= next_miss_state;
    end

    // valid/ready for the channels miss FSM drives
    assign chan_a_valid = (miss_state == REQUEST); // when channel A ACQUIRE is sent to L2
    assign chan_d_ready = 'd1; // always high to avoid deadlock with this L1 and L2 due to another acquire
    assign chan_e_valid = (miss_state == ACK); // when E responds with sink
    // saved_sink is final by the time ACK is entered (captured on every
    // accepted D beat in WAIT), so drive it straight through. Registering
    // it inside ACK would put a stale sink on the bus for ACK's first cycle
    assign chan_e.sink  = saved_sink;

    // ------------------------------------------------------------------
    // Next-state logic only, no outputs driven here
    // ------------------------------------------------------------------
    always_comb begin
        next_miss_state = miss_state;
        case (miss_state)
            IDLE: begin
                if (mshr_alloc) next_miss_state = alloc_evict ? EVICT : REQUEST;
            end

            EVICT: begin
                // Channel C is arbitrated below (probe FSM wins ties); only
                // count this as accepted if our Release/ReleaseData actually
                // won the bus this cycle
                if (!probe_c_req && chan_c_ready) begin
                    if (!saved_evict_dirty || last_beat) next_miss_state = RELEASE_WAIT;
                end
            end

            RELEASE_WAIT: begin
                if (chan_d_valid && chan_d_ready && (chan_d.opcode == RELEASE_ACK)) next_miss_state = REQUEST;
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
    // beats into data1, commits the tag/valid/perm arrays, and performs
    // store hits. Every write to data1/dirty1/perms lives in this one block
    // so each array has a single procedural driver. The lookup-port
    // conflict checks above guarantee a store hit never targets the slot
    // the MSHR or the probe FSM is writing in the same cycle.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            saved_addr <= '0;
            saved_way  <= '0;
            saved_perm <= '0;
            saved_sink <= '0;
            beat_count <= '0;
            saved_evict       <= '0;
            saved_evict_dirty <= '0;
            saved_evict_param <= '0;
            saved_evict_addr  <= '0;
            chan_a     <= '0;
            saved_new_fill <= '0;
            for (int i = 0; i < L1_SETS*L1_WAYS; i++) valid1[i] <= 1'b0; // avoid X-valued lines looking like hits
            for (int i = 0; i < L1_SETS; i++) rr_way1[i] <= 1'b0;
        end else begin
            // store hit: write into the array and mark the line dirty
            if (wr_en) begin
                data1[{index, hit_way}][beat_sel] <= lk.st_data;
                dirty1[{index, hit_way}]          <= 1'b1;
            end

            case (miss_state)
            IDLE: begin
                if (mshr_alloc) begin
                    // latch everything the rest of the transaction needs.
                    // lk (head or ins) will be a different request entirely
                    // by the time the transaction is several cycles into WAIT
                    saved_addr <= lk.addr;
                    // tag_hit: keep the line's current way.
                    // true miss: target the round-robin victim way.
                    saved_way  <= tag_hit ? hit_way : victim_way;
                    saved_new_fill <= !tag_hit;
                    beat_count <= '0; // fresh count for whichever of EVICT/WAIT reads it next

                    saved_evict       <= alloc_evict;
                    saved_evict_dirty <= dirty1[{index, victim_way}];
                    saved_evict_param <= (perms[{index, victim_way}] == PERM_T) ? T_TO_N : B_TO_N;
                    saved_evict_addr  <= {tag1[{index, victim_way}], index, {OFFSET_BITS{1'b0}}};

                    chan_a.size    <= SIZE_WIDTH'($clog2(LINE_BYTES));
                    chan_a.source  <= L1_ID;
                    chan_a.addr    <= lk.addr;
                    chan_a.mask    <= '0; // whole line transfers only, never a partial write mask
                    chan_a.data    <= '0; // Acquire carries no data, it comes back on GrantDATA
                    chan_a.corrupt <= '0;

                    if (tag_hit && (perms[{index, hit_way}] == PERM_B)) begin
                        // already hold the line with B, so this is a store
                        // that just needs more permission
                        chan_a.opcode <= ACQUIRE_PERM;
                        chan_a.param  <= B_TO_T; // store needs TIP permission
                    end else begin
                        // don't have the line at all (or a probe left it at
                        // N, so its data can't be trusted). fetch it plus
                        // the minimum permission the access needs
                        chan_a.opcode <= ACQUIRE_BLOCK;
                        chan_a.param  <= lk.opcode ? N_TO_T : N_TO_B; // store needs TIP, load needs BRANCH
                    end
                end
            end

            EVICT: begin
                if (!probe_c_req && chan_c_ready) begin
                    beat_count <= beat_count + 1'b1; // counts ReleaseData beats; harmless no-op path for a single-beat Release
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
                        data1[{saved_index, saved_way}][beat_count] <= chan_d.data; // assign each beat to data1
                        beat_count <= beat_count + 1'b1; // wraps back to 0 on the last beat (BEAT_BITS-wide)
                    end
                end
            end

            ACK: begin
                // commit the fill/upgrade once, on the cycle GrantAck is
                // accepted. Doing it every ACK cycle would toggle rr_way1
                // repeatedly whenever channel E is backpressured
                if (chan_e_valid && chan_e_ready) begin
                    tag1[{saved_index, saved_way}]   <= saved_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
                    valid1[{saved_index, saved_way}] <= 1'b1;
                    dirty1[{saved_index, saved_way}] <= 1'b0; // freshly filled line is clean
                    case (saved_perm) // assign whatever permission it was assigned from chan D
                        TO_T:    perms[{saved_index, saved_way}] <= PERM_T;
                        TO_B:    perms[{saved_index, saved_way}] <= PERM_B;
                        TO_N:    perms[{saved_index, saved_way}] <= PERM_N;
                        default: perms[{saved_index, saved_way}] <= PERM_B;
                    endcase

                    // only alternate the pointer for a true-miss fill; an
                    // upgrade reused the line's existing way, so the next
                    // true miss to this set should still land on the way
                    // that wasn't just filled/refreshed
                    if (saved_new_fill) rr_way1[saved_index] <= ~rr_way1[saved_index];
                end
            end
            endcase

            // Channel B-C's permission-downgrade commit lives here rather
            // than in the probe FSM's own always_ff above, even though
            // it's that FSM's decision. perms/dirty1 already have this
            // block as their writer, and a variable can only have one
            // procedural driver, so a second always_ff writing them
            // is a multiple-driver error.
            if (probe_state == PROBE_SEND && chan_c_valid && chan_c_ready) begin
                perms[{probe_reg_index, probe_way}] <= probe_new_perm;
                if (probe_send_data) dirty1[{probe_reg_index, probe_way}] <= 1'b0;
            end
        end
    end

endmodule
