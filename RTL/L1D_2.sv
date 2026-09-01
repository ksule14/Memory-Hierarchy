module L1_cache2 
import tilelink_pkg::*;
(
    input logic clk,
    input logic rst,
    input cpu_req_t ins,
    output cpu_resp_t outs,

    // channel A
    output channel_a chan_a,
    output logic chan_a_valid,
    input logic chan_a_ready,

    // channel B
    input channel_b chan_b,
    input logic chan_b_valid,
    output logic chan_b_ready,

    // channel C
    output channel_c chan_c,
    output logic chan_b_valid,
    input logic chan_b_ready,

    // channel D
    input channel_d chan_d,
    input logic chan_d_valid,
    output logic chan_d_ready,

    // channel E
    output channel_e chan_e,
    output logic chan_e_valid,
    input logic chan_e_ready
);

    localparam int L1_SETS     = 8;
    localparam int L1_WAYS     = 2;
    localparam int OFFSET_BITS = $clog2(LINE_BYTES); // number of bits needed to address each byte in a line                   
    localparam int INDEX_BITS  = $clog2(L1_SETS);    // number of bits needed to select a set                   
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS; // remaining bits after tag and offset
    localparam int BEAT_BITS   = $clog2(BEATS); // number of bits to represent the number of beats in a data transfer

    localparam logic [SOURCE_WIDTH-1:0] L1_ID = 2'd2; // cache's fixed Tilelink source ID

    // smallest unit is 32 bits, 8*2 = 16 rows, 4 units per row
    logic [DATA_WIDTH-1:0] data2  [0:L1_SETS*L1_WAYS-1][0:BEATS-1];
    logic [TAG_BITS-1:0]   tag2   [0:L1_SETS*L1_WAYS-1]; // tag cache for each row
    logic                  valid2 [0:L1_SETS*L1_WAYS-1]; // valid cache for each row
    logic                  dirty2 [0:L1_SETS*L1_WAYS-1]; // dirty cache for each row
    perm_t                 perms2  [0:L1_SETS*L1_WAYS-1]; // permission cache for each row

    // catured when a miss is first detected in IDLE, since ins.something/
    // the tag-hit way aren't guaranteed to still line up once beats start arriving several
    // cycles later
    logic [ADDR_WIDTH-1:0]  saved_addr;
    logic                   saved_way;
    logic [PARAM_WIDTH-1:0] saved_perm;
    logic [SINK_WIDTH-1:0]  saved_sink; // bookmark sent by D for D-E transaction, echoed back on E
    logic [BEATS-1:0]       beat_count;
    logic                   last_beat;

    // victim line's state, latched alongside saved_addr/saved_way at miss
    // detection. Decides Release vs ReleaseData and the shrink_t param
    // for the voluntary eviction if one is needed.
    logic                   saved_evict_dirty;
    logic [PARAM_WIDTH-1:0] saved_evict_param;

    logic [OFFSET_BITS-1:0] offset; // selects beat (and byte but we don't use that)
    logic [INDEX_BITS-1:0]  index; // selects set
    logic [TAG_BITS-1:0]    tag; // identifies correct line
    logic [BEAT_BITS-1:0]   beat_sel; // beat within line

    logic hit_way0, hit_way1;
    logic tag_hit, hit_way, perm_ok, hit, wr_en;

    assign offset = ins.addr[OFFSET_BITS-1:0];
    assign index  = ins.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign tag    = ins.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    // equates to offset[3:2]. bits 0-1 choose byte, bits 3-2 choose beatr which is what we want
    assign beat_sel = offset[OFFSET_BITS-1:$clog2(DATA_WIDTH/8)]; // which beat within the line this word lives in

    // tag match only, independent of what permission we currently hold on it
    assign hit_way0 = valid2[{index, 1'b0}] && (tag2[{index, 1'b0}] == tag); // append 0 to choose set and way0
    assign hit_way1 = valid2[{index, 1'b1}] && (tag2[{index, 1'b1}] == tag); // append 1 to chooose set and way1
    assign tag_hit = hit_way0 || hit_way1;
    // hit_way0 and hit_way1 are mutually exclusive for a valid cache, so this also 
    // defaults to way0 on a true miss (tag_hit == 0)
    assign hit_way = hit_way1;

    // a load is satisfied by either B or T; a store needs exclusive (T) permission
    assign perm_ok = ins.opcode ? (perms[{index, hit_way}] == PERM_T)
                                  : (perms[{index, hit_way}] != PERM_N);
    
    assign hit = tag_hit && perm_ok;
    assign wr_en = hit && ins.opcode; // store hit means write CPU data into line

    assign last_beat = (beat_count == BEATS-1);

    // states for cache miss FSM. EVICT/RELEASE_WAIT only run ahead of
    // REQUEST when the fill has to replace an already-valid line; a
    // same-line permission upgrade (tag_hit but !perm_ok) skips straight
    // to REQUEST since there's nothing to write back.
    typedef enum logic [2:0] {
        IDLE         = 3'b000,
        EVICT        = 3'b001,
        RELEASE_WAIT = 3'b011,
        REQUEST      = 3'b010,
        WAIT         = 3'b110,
        ACK          = 3'b111
    } miss_t;

    miss_t miss_state, next_state;

    always_ff @(posedge clk) begin
        if (rst) miss_state <= IDLE;
        else miss_state <= next_miss_state;
    end

    // ------------------------------------------------------------------
    // CPU-facing outputs. outs.stall tracks hit=false. true both
    // on the first cycle a miss is discovered (miss_state still IDLE that
    // cycle) and for every cycle the fill is outstanding after that, since
    // hit stays low until the tag/valid/perm arrays are updated in ACK.
    // Assumes the CPU holds ins stable while stall is asserted.
    // ------------------------------------------------------------------

    always_comb begin
        outs.rdata = hit ? data2[{index, hit_way}][beat_sel] : '0; // assign output value depending on hit
        outs.stall = !hit; // stall when miss
    end

    always_ff @(posedge clk) begin
        if (wr_en) begin
            data2[{index, hit_way}][beat_sel] <= ins.st_data;
            dirty2[{index, hit_way}]          <= 1'b1;
        end
    end

    // valid/ready for the channels miss FSM drives
    assign chan_a_valid = (miss_state == REQUEST); // when channel A ACQUIRE is sent to L2
    assign chan_d_ready = 'd1; // always high to avoid deadlock with this L1 and L2 due to another acquire
    assign chan_e_valid = (miss_state == ACK); // when E responds with sink

    // ------------------------------------------------------------------
    // Next-state logic only, no outputs driven here
    // ------------------------------------------------------------------
    