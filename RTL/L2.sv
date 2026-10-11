// Shared, inclusive L2. Sits behind l2_controller (L1 side, full TL-C) and
// in front of main_memory (TL-UL Get / PutFullData).
//
// Coherence is directory based. Every L2 line keeps a presence bit per L1
// source id, plus a tip bit meaning the one L1 that holds it has T. The
// directory has to be exact, because an L1 assumes any probe it gets is for
// a line it really holds. It is kept exact by:
//   - Grant:           sets the requester's presence bit (and tip for T)
//   - ProbeAck(Data):  applies the L1's reported resulting permission
//   - Release(Data):   clears the releaser's presence bit
//
// The L2 is inclusive, so evicting a line some L1 still holds first probes
// those L1s down to N (back-invalidation), then writes the line back to
// memory if it's dirty.
//
// One Acquire is handled at a time. Releases are handled by their own small
// FSM so they can be accepted both while idle and while the main FSM is
// waiting on probe acks. An L1 that is mid-eviction won't answer anything
// on A until its Release is acked, so refusing Releases while probing could
// lock up channel C.
module l2_cache
    import tilelink_pkg::*;
    (
        input logic clk,
        input logic rst,

        // Channel A facing L1s
        input  channel_a a_L1,
        input  logic     a_L1_valid,
        output logic     a_L1_ready,

        // Channel B facing L1s
        output channel_b b_L1,
        output logic     b_L1_valid,
        input  logic     b_L1_ready,

        // Channel C facing L1s
        input  channel_c c_L1,
        input  logic     c_L1_valid,
        output logic     c_L1_ready,

        // Channel D facing L1s
        output channel_d d_L1,
        output logic     d_L1_valid,
        input  logic     d_L1_ready,

        // Channel E facing L1s
        input  channel_e e_L1,
        input  logic     e_L1_valid,
        output logic     e_L1_ready,

        // Channel A facing main memory
        output channel_a a_mem,
        output logic     a_mem_valid,
        input  logic     a_mem_ready,

        // Channel D facing main memory
        input  channel_d d_mem,
        input  logic     d_mem_valid,
        output logic     d_mem_ready
    );

    localparam int L2_SETS     = 32;
    localparam int L2_WAYS     = 2;  // way select below is a single bit, so this must stay 2
    localparam int N_L1        = 2**SOURCE_WIDTH; // one presence bit per possible L1 source id
    localparam int OFFSET_BITS = $clog2(LINE_BYTES);
    localparam int INDEX_BITS  = $clog2(L2_SETS);
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
    localparam int L2_LINE_AW  = $clog2(L2_SETS * L2_WAYS);
    localparam int BEAT_BITS   = $clog2(BEATS);

    // ------------------------------------------------------------------
    // storage. line index is {set, way}, same layout as the L1s. data is
    // one beat per BRAM word so every channel can read/write it a beat at
    // a time with one read and one write port
    // ------------------------------------------------------------------
    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] l2 [0:L2_SETS*L2_WAYS*BEATS-1];

    logic [TAG_BITS-1:0] l2_tag      [0:L2_SETS*L2_WAYS-1];
    logic                valid_array [0:L2_SETS*L2_WAYS-1];
    logic                dirty_array [0:L2_SETS*L2_WAYS-1]; // L2's copy is newer than memory
    logic [N_L1-1:0]     dir_pres    [0:L2_SETS*L2_WAYS-1]; // which L1s hold the line (B or T)
    logic                dir_tip     [0:L2_SETS*L2_WAYS-1]; // the single holder has T, so its copy may be dirty
    logic                mru_way     [0:L2_SETS-1];         // most recently granted way per set, for replacement

    function automatic logic [ADDR_WIDTH-1:0] line_addr(input logic [ADDR_WIDTH-1:0] a);
        return {a[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
    endfunction

    // ProbeAck/ProbeAckData param (shrink_t or report_t) -> the permission
    // the L1 is left holding
    function automatic perm_t probe_result(input logic [PARAM_WIDTH-1:0] p);
        case (p)
            T_TO_T:         return PERM_T;
            T_TO_B, B_TO_B: return PERM_B;
            default:        return PERM_N; // T_TO_N, B_TO_N, N_TO_N
        endcase
    endfunction

    typedef enum logic [3:0] {
        IDLE      = 4'b0000,
        PROBE     = 4'b0001, // send probes on B and collect ProbeAcks on C
        WB_LOAD   = 4'b0011, // read the dirty victim into lbuf
        WB_PUT    = 4'b0010, // PutFullData the victim to memory
        WB_ACK    = 4'b0110, // wait for memory's AccessAck
        MEM_GET   = 4'b0111, // send Get for the requested line
        MEM_FILL  = 4'b0101, // AccessAckData beats -> data array
        G_LOAD    = 4'b0100, // read the requested line into lbuf
        GRANT     = 4'b1100, // Grant / GrantData to the requester
        GRANT_ACK = 4'b1101  // wait for GrantAck on E
    } l2_state_t;

    l2_state_t state, next_state;

    typedef enum logic [1:0] {
        REL_IDLE = 2'b00,
        REL_ACK  = 2'b01  // Release(Data) fully received, sending ReleaseAck
    } rel_state_t;

    rel_state_t rel_state, next_rel_state;

    // ------------------------------------------------------------------
    // MSHR for the one Acquire in flight. A is only accepted in IDLE, so
    // everything after that works off these saved copies
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0]   req_addr;   // line aligned
    logic [SOURCE_WIDTH-1:0] req_source;
    logic [OPCODE_WIDTH-1:0] req_opcode;
    logic                    req_want_t; // N_TO_T or B_TO_T, as opposed to N_TO_B
    logic [L2_LINE_AW-1:0]   slot;       // line the request hits, or the victim slot it will fill
    logic [ADDR_WIDTH-1:0]   victim_addr;
    logic                    grant_data; // GrantData rather than Grant

    // probing. probe_todo = probes not yet sent, probe_pend = acks not yet
    // received. probe_victim says what PROBE does when it finishes
    logic [N_L1-1:0]         probe_todo, probe_pend;
    logic [ADDR_WIDTH-1:0]   probe_addr;
    logic [PARAM_WIDTH-1:0]  probe_cap;
    logic                    probe_victim;

    // beat counters and line buffer for anything sent out of the data array
    logic [DATA_WIDTH-1:0]   lbuf [0:BEATS-1];
    logic [BEAT_BITS:0]      ld_cnt;  // one extra bit, LOAD runs BEATS+1 cycles for BRAM latency
    logic [BEAT_BITS-1:0]    tx_beat; // beats sent on D (GrantData) or A (PutFullData)
    logic [BEAT_BITS-1:0]    rx_beat; // AccessAckData beats received
    logic [BEAT_BITS-1:0]    c_beat;  // beats of the current C burst. C bursts never interleave
    logic [SOURCE_WIDTH-1:0] rel_source;

    logic [L2_LINE_AW-1:0]   rd_addr_line;
    logic [DATA_WIDTH-1:0]   read_data;

    // ------------------------------------------------------------------
    // channel A lookup (live a_L1, used in IDLE only)
    // ------------------------------------------------------------------
    logic [INDEX_BITS-1:0] a_index;
    logic [TAG_BITS-1:0]   a_tag;
    logic                  a_hit_way0, a_hit_way1, a_hit, a_way;
    logic                  a_victim_way;
    logic [L2_LINE_AW-1:0] a_line, a_victim_line;

    assign a_index    = a_L1.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign a_tag      = a_L1.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    assign a_hit_way0 = valid_array[{a_index, 1'b0}] && (l2_tag[{a_index, 1'b0}] == a_tag);
    assign a_hit_way1 = valid_array[{a_index, 1'b1}] && (l2_tag[{a_index, 1'b1}] == a_tag);
    assign a_hit      = a_hit_way0 || a_hit_way1;
    assign a_way      = a_hit_way1;
    assign a_line     = {a_index, a_way};

    // victim: an invalid way first, then a way no L1 holds (avoids
    // back-invalidating an L1), then the least recently granted way
    always_comb begin
        if      (!valid_array[{a_index, 1'b0}])  a_victim_way = 1'b0;
        else if (!valid_array[{a_index, 1'b1}])  a_victim_way = 1'b1;
        else if (dir_pres[{a_index, 1'b0}] == '0 && dir_pres[{a_index, 1'b1}] != '0) a_victim_way = 1'b0;
        else if (dir_pres[{a_index, 1'b1}] == '0 && dir_pres[{a_index, 1'b0}] != '0) a_victim_way = 1'b1;
        else                                     a_victim_way = ~mru_way[a_index];
    end
    assign a_victim_line = {a_index, a_victim_way};

    // probes a hitting Acquire needs before it can be granted. T needs every
    // other holder at N. B only needs a T holder knocked down to B; plain
    // B sharers can stay
    logic [N_L1-1:0] a_others, a_probes;
    logic            a_want_t;

    assign a_want_t = (a_L1.param == N_TO_T) || (a_L1.param == B_TO_T);
    always_comb begin
        a_others = dir_pres[a_line];
        a_others[a_L1.source] = 1'b0;
        if (a_want_t)              a_probes = a_others;
        else if (dir_tip[a_line])  a_probes = a_others;
        else                       a_probes = '0;
    end

    // ------------------------------------------------------------------
    // channel C decode and lookup (live c_L1). A C burst holds its payload
    // for every beat, so looking the address up on each beat is fine
    // ------------------------------------------------------------------
    logic                  c_is_probe_ack, c_is_release, c_has_data, c_last, c_fire;
    logic [INDEX_BITS-1:0] c_index;
    logic [TAG_BITS-1:0]   c_tag;
    logic                  c_hit_way0, c_hit_way1, c_hit;
    logic [L2_LINE_AW-1:0] c_line;
    logic                  c_src_present;

    assign c_is_probe_ack = (c_L1.opcode == PROBE_ACK)   || (c_L1.opcode == PROBE_ACK_DATA);
    assign c_is_release   = (c_L1.opcode == RELEASE)     || (c_L1.opcode == RELEASE_DATA);
    assign c_has_data     = (c_L1.opcode == PROBE_ACK_DATA) || (c_L1.opcode == RELEASE_DATA);
    assign c_last         = !c_has_data || (c_beat == BEATS-1);

    assign c_index    = c_L1.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign c_tag      = c_L1.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    assign c_hit_way0 = valid_array[{c_index, 1'b0}] && (l2_tag[{c_index, 1'b0}] == c_tag);
    assign c_hit_way1 = valid_array[{c_index, 1'b1}] && (l2_tag[{c_index, 1'b1}] == c_tag);
    assign c_hit      = c_hit_way0 || c_hit_way1;
    assign c_line     = {c_index, c_hit_way1};
    assign c_src_present = dir_pres[c_line][c_L1.source];

    // ProbeAcks only while probing. Releases whenever the main FSM is in a
    // state that can't be using D for itself (IDLE, PROBE) and no
    // ReleaseAck is still waiting to go out
    assign c_L1_ready = (c_is_probe_ack && (state == PROBE)) ||
                        (c_is_release && (rel_state == REL_IDLE) && ((state == IDLE) || (state == PROBE)));
    assign c_fire     = c_L1_valid && c_L1_ready;

    // Release data is only kept if the releaser is still a holder. If a probe
    // already took the line to N, its ReleaseData is a stale copy of what
    // the ProbeAckData sent, and another L1 may have written it since
    logic c_data_wr;
    assign c_data_wr = c_fire && c_has_data && c_hit && (c_is_probe_ack || c_src_present);

    // ------------------------------------------------------------------
    // misc handshakes
    // ------------------------------------------------------------------
    logic a_fire, b_fire, d_fire, e_fire, a_mem_fire, d_mem_fire;
    logic c_idle;     // no C burst half received and no ReleaseAck owed
    logic probe_done; // every ack is in and no Release still needs D for its ReleaseAck
    logic need_data;  // what a grant starting from current directory state would send

    assign c_idle = (rel_state == REL_IDLE) && (c_beat == '0);

    // L2 can only start an Acquire once C is quiet, so a Release that's
    // already presented gets handled first
    assign a_L1_ready = (state == IDLE) && c_idle && !c_L1_valid;
    assign a_fire     = a_L1_valid && a_L1_ready;
    assign b_fire     = b_L1_valid && b_L1_ready;
    assign d_fire     = d_L1_valid && d_L1_ready;
    assign e_fire     = e_L1_valid && e_L1_ready;
    assign a_mem_fire = a_mem_valid && a_mem_ready;
    assign d_mem_fire = d_mem_valid && d_mem_ready;

    // a Release accepted this cycle owes a ReleaseAck starting next cycle,
    // so PROBE can't hand D over to a Grant yet
    assign probe_done = (probe_pend == '0) && c_idle && !c_fire;

    // AcquirePerm normally gets a dataless Grant, but if the requester got
    // probed to N while its AcquirePerm was waiting, its copy is gone and
    // it needs the data again
    assign need_data = (req_opcode == ACQUIRE_BLOCK) || !dir_pres[slot][req_source];

    // ------------------------------------------------------------------
    // main FSM
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (a_fire) begin
                    if (a_hit) begin
                        if (a_probes != '0) next_state = PROBE;
                        else if ((a_L1.opcode == ACQUIRE_BLOCK) || !dir_pres[a_line][a_L1.source])
                                                next_state = G_LOAD;
                        else                    next_state = GRANT;
                    end else begin
                        if (!valid_array[a_victim_line])          next_state = MEM_GET;
                        else if (dir_pres[a_victim_line] != '0)   next_state = PROBE;   // back-invalidate first
                        else if (dirty_array[a_victim_line])      next_state = WB_LOAD;
                        else                                      next_state = MEM_GET;
                    end
                end
            end

            PROBE: begin
                if (probe_done) begin
                    if (probe_victim) next_state = dirty_array[slot] ? WB_LOAD : MEM_GET;
                    else              next_state = need_data ? G_LOAD : GRANT;
                end
            end

            WB_LOAD:  if (ld_cnt == BEATS) next_state = WB_PUT;

            WB_PUT:   if (a_mem_fire && (tx_beat == BEATS-1)) next_state = WB_ACK;

            WB_ACK:   if (d_mem_fire && (d_mem.opcode == ACCESS_ACK)) next_state = MEM_GET;

            MEM_GET:  if (a_mem_fire) next_state = MEM_FILL;

            // the line wasn't in L2, so by inclusion no L1 has it, and no
            // probes are needed. it always goes out as GrantData
            MEM_FILL: if (d_mem_fire && (d_mem.opcode == ACCESS_ACK_DATA) && (rx_beat == BEATS-1))
                          next_state = G_LOAD;

            G_LOAD:   if (ld_cnt == BEATS) next_state = GRANT;

            GRANT:    if (d_fire && (!grant_data || (tx_beat == BEATS-1))) next_state = GRANT_ACK;

            GRANT_ACK: if (e_fire) next_state = IDLE;

            default: next_state = IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // release FSM. a Release is received beat by beat (data written as it
    // arrives), then answered with one ReleaseAck on D
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) rel_state <= REL_IDLE;
        else     rel_state <= next_rel_state;
    end

    always_comb begin
        next_rel_state = rel_state;
        case (rel_state)
            REL_IDLE: if (c_fire && c_is_release && c_last) next_rel_state = REL_ACK;
            REL_ACK:  if (d_fire) next_rel_state = REL_IDLE;
            default:  next_rel_state = REL_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // channel outputs
    // ------------------------------------------------------------------

    // B: one ProbeBlock per L1 in probe_todo, lowest id first. the target
    // only changes after a handshake, so the payload holds until accepted
    logic [SOURCE_WIDTH-1:0] probe_target;
    always_comb begin
        probe_target = '0;
        for (int i = N_L1-1; i >= 0; i--)
            if (probe_todo[i]) probe_target = SOURCE_WIDTH'(i);
    end

    assign b_L1_valid    = (state == PROBE) && (probe_todo != '0);
    assign b_L1.opcode   = PROBE_BLOCK; // dirty holders send their data back
    assign b_L1.param    = probe_cap;
    assign b_L1.size     = SIZE_WIDTH'($clog2(LINE_BYTES));
    assign b_L1.source   = probe_target;
    assign b_L1.addr     = probe_addr;
    assign b_L1.mask     = '0;
    assign b_L1.data     = '0;
    assign b_L1.corrupt  = 1'b0;

    // D: ReleaseAck and Grant(Data) never overlap. a Release only starts in
    // IDLE/PROBE, and neither of those leaves until its ReleaseAck is out
    assign d_L1_valid = (rel_state == REL_ACK) || (state == GRANT);

    always_comb begin
        d_L1         = '0;
        d_L1.size    = SIZE_WIDTH'($clog2(LINE_BYTES));
        d_L1.sink    = '0; // only one grant is ever outstanding
        if (rel_state == REL_ACK) begin
            d_L1.opcode = RELEASE_ACK;
            d_L1.source = rel_source;
        end else begin
            d_L1.opcode = grant_data ? GRANT_DATA : GRANT;
            d_L1.param  = req_want_t ? TO_T : TO_B;
            d_L1.source = req_source;
            d_L1.data   = grant_data ? lbuf[tx_beat] : '0;
        end
    end

    assign e_L1_ready = (state == GRANT_ACK);

    // memory side
    assign a_mem_valid = (state == WB_PUT) || (state == MEM_GET);
    assign d_mem_ready = (state == WB_ACK) || (state == MEM_FILL);

    always_comb begin
        a_mem         = '0;
        a_mem.size    = SIZE_WIDTH'($clog2(LINE_BYTES));
        a_mem.source  = '0; // L2 is memory's only client
        a_mem.mask    = '0; // whole line transfers only
        if (state == WB_PUT) begin
            a_mem.opcode = PUT_FULL_DATA;
            a_mem.addr   = victim_addr;
            a_mem.data   = lbuf[tx_beat];
        end else begin
            a_mem.opcode = GET;
            a_mem.addr   = req_addr;
        end
    end

    // ------------------------------------------------------------------
    // data array. one read port (LOAD states), one write port shared by
    // memory fills and C data beats. those never collide since C isn't
    // accepted during MEM_FILL
    // ------------------------------------------------------------------
    logic                              wr_en;
    logic [L2_LINE_AW+BEAT_BITS-1:0]   wr_addr;
    logic [DATA_WIDTH-1:0]             wr_data;

    always_comb begin
        if ((state == MEM_FILL) && d_mem_fire) begin
            wr_en   = (d_mem.opcode == ACCESS_ACK_DATA);
            wr_addr = {slot, rx_beat};
            wr_data = d_mem.data;
        end else begin
            wr_en   = c_data_wr;
            wr_addr = {c_line, c_beat};
            wr_data = c_L1.data;
        end
    end

    assign rd_addr_line = slot;

    always_ff @(posedge clk) begin
        if (wr_en) l2[wr_addr] <= wr_data;
        read_data <= l2[{rd_addr_line, ld_cnt[BEAT_BITS-1:0]}]; // 1 cycle BRAM latency
    end

    // ------------------------------------------------------------------
    // sequential datapath. every tag/state/directory array is written only
    // here so each has a single driver
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            req_addr     <= '0;
            req_source   <= '0;
            req_opcode   <= '0;
            req_want_t   <= 1'b0;
            slot         <= '0;
            victim_addr  <= '0;
            grant_data   <= 1'b0;
            probe_todo   <= '0;
            probe_pend   <= '0;
            probe_addr   <= '0;
            probe_cap    <= '0;
            probe_victim <= 1'b0;
            ld_cnt       <= '0;
            tx_beat      <= '0;
            rx_beat      <= '0;
            c_beat       <= '0;
            rel_source   <= '0;
            for (int i = 0; i < L2_SETS*L2_WAYS; i++) begin
                valid_array[i] <= 1'b0;
                dirty_array[i] <= 1'b0;
                dir_pres[i]    <= '0;
                dir_tip[i]     <= 1'b0;
            end
            for (int i = 0; i < L2_SETS; i++) mru_way[i] <= 1'b0;
        end else begin

            // ---------------- channel C, independent of main state ----------------
            if (c_fire) begin
                c_beat <= c_last ? '0 : c_beat + 1'b1;

                if (c_data_wr) dirty_array[c_line] <= 1'b1;

                if (c_last) begin
                    if (c_is_probe_ack) begin
                        probe_pend[c_L1.source] <= 1'b0;
                        if (c_hit) begin
                            case (probe_result(c_L1.param))
                                PERM_N: begin
                                    dir_pres[c_line][c_L1.source] <= 1'b0;
                                    dir_tip[c_line]               <= 1'b0;
                                end
                                PERM_B: dir_tip[c_line] <= 1'b0;
                                default: ; // still T
                            endcase
                        end
                    end else begin
                        // Release always shrinks to N. if the releaser was
                        // the T holder, nobody holds T anymore. if it wasn't
                        // a holder at all (already probed to N) leave the
                        // directory alone, another L1 may hold T now
                        rel_source <= c_L1.source;
                        if (c_hit && c_src_present) begin
                            dir_pres[c_line][c_L1.source] <= 1'b0;
                            dir_tip[c_line]               <= 1'b0;
                        end
                    end
                end
            end

            // ---------------- main FSM datapath ----------------
            case (state)
                IDLE: begin
                    if (a_fire) begin
                        req_addr   <= line_addr(a_L1.addr);
                        req_source <= a_L1.source;
                        req_opcode <= a_L1.opcode;
                        req_want_t <= a_want_t;
                        tx_beat    <= '0;
                        rx_beat    <= '0;
                        ld_cnt     <= '0;

                        if (a_hit) begin
                            slot         <= a_line;
                            probe_addr   <= line_addr(a_L1.addr);
                            probe_cap    <= a_want_t ? TO_N : TO_B;
                            probe_todo   <= a_probes;
                            probe_pend   <= a_probes;
                            probe_victim <= 1'b0;
                            grant_data   <= (a_L1.opcode == ACQUIRE_BLOCK) || !dir_pres[a_line][a_L1.source];
                        end else begin
                            slot         <= a_victim_line;
                            victim_addr  <= {l2_tag[a_victim_line], a_index, {OFFSET_BITS{1'b0}}};
                            probe_addr   <= {l2_tag[a_victim_line], a_index, {OFFSET_BITS{1'b0}}};
                            probe_cap    <= TO_N;
                            probe_todo   <= valid_array[a_victim_line] ? dir_pres[a_victim_line] : '0;
                            probe_pend   <= valid_array[a_victim_line] ? dir_pres[a_victim_line] : '0;
                            probe_victim <= 1'b1;
                            grant_data   <= 1'b1;
                        end
                    end
                end

                PROBE: begin
                    if (b_fire) probe_todo[probe_target] <= 1'b0;
                    if (probe_done && !probe_victim) grant_data <= need_data;
                    ld_cnt <= '0;
                end

                WB_LOAD, G_LOAD: begin
                    if (ld_cnt != '0) lbuf[ld_cnt-1] <= read_data;
                    ld_cnt <= (ld_cnt == BEATS) ? '0 : ld_cnt + 1'b1;
                    tx_beat <= '0;
                end

                WB_PUT: begin
                    if (a_mem_fire) tx_beat <= tx_beat + 1'b1; // wraps to 0 after the last beat
                end

                WB_ACK: begin
                    if (d_mem_fire) dirty_array[slot] <= 1'b0; // memory has it now
                end

                MEM_GET: begin
                    // the old line is fully gone (probed and written back),
                    // so retag the slot now. it stays invalid until filled
                    if (a_mem_fire) begin
                        l2_tag[slot]      <= req_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
                        valid_array[slot] <= 1'b0;
                        dirty_array[slot] <= 1'b0;
                        dir_pres[slot]    <= '0;
                        dir_tip[slot]     <= 1'b0;
                        rx_beat           <= '0;
                    end
                end

                MEM_FILL: begin
                    if (d_mem_fire && (d_mem.opcode == ACCESS_ACK_DATA)) begin
                        rx_beat <= rx_beat + 1'b1;
                        if (rx_beat == BEATS-1) valid_array[slot] <= 1'b1;
                    end
                    ld_cnt <= '0;
                end

                GRANT: begin
                    if (d_fire) begin
                        tx_beat <= tx_beat + 1'b1;
                        if (!grant_data || (tx_beat == BEATS-1)) begin
                            // requester now holds the line. for T, the probes
                            // already cleared every other holder
                            dir_pres[slot][req_source] <= 1'b1;
                            dir_tip[slot]              <= req_want_t;
                            mru_way[slot[INDEX_BITS:1]] <= slot[0];
                        end
                    end
                end

                GRANT_ACK: ;

                default: ;
            endcase
        end
    end

endmodule
