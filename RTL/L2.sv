module l2_cache
    import tilelink_pkg::*;
    (
        input logic clk,
        input logic rst,

        // Channel A facing L1s

        // Channel B facing L1s

        // Channel C facing L1s

        // Channel D facing L1s

        // Channel E facing L1s

        // Channel A facing main memory
        output channel_a a_mem,
        output logic a_mem_valid,
        input logic a_mem_ready,
        
        // Channel D facing main memory
        input channel_d d_mem,
        input logic d_mem_valid,
        output logic d_mem_ready
    );

    localparam L2_SETS = 32; // divide the rows into 32 sets
    localparam L2_WAYS = 2; // each set contains 2 rows
    localparam OFFSET_BITS = $clog2(LINE_BYTES) // to count all 16 bytes per cache line
    localparam INDEX_BITS = $clog2(L2_SETS) // decided which of the 32 sets to look in
    localparam TAG_BITS = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS; // remaining bits after index and offset

    (*ram_style = "block" *)
    logic [DATA_WIDTH-1:0] l2 [0:L2_SETS*L2_WAYS-1][0:BEATS-1]; // 32 bits per data entry, sets*ways gives rows, beats gives number of entries per line.

    logic [TAG_BITS-1:0] l2_tag [0:L2_SETS*L2_WAYS-1]; // no beat dimension since tag is for line not byte

    logic valid_array [0:L2_SETS*L2_WAYS-1]; // same logic as tag array

    logic dirty_array [0:L2_SETS*L2_WAYS-1]; // same as valid

    typedef enum logic [2:0] {
        IDLE    = 3'd0,
        READ    = 3'd1,
        RESPOND = 3'd2,
        WRITE   = 3'd3,
        ACK     = 3'd4
    } to_mem_state_t;

    to_mem_state_t state, next_state;

    logic [ADDR_WIDTH-1:0]    saved_addr; // register for address when it needs to be captured
    logic [SOURCE_WIDTH-1:0]  saved_source; // same as address but for source
    // BRAM interface signals
    logic [$clog2(BEATS)-1:0] beat_count; // needed since data transactions are multiple beats
    logic [WORD_AW-1:0]       rd_addr;
    logic [WORD_AW-1:0]       wr_addr;
    logic                     wr_en;
    logic [DATA_WIDTH-1:0]    read_data;

    // combinational signals
    logic [WORD_AW-1:0] base_word_addr;
    logic last_beat;
    logic [OFFSET_BITS-1:0] offset;
    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0] tag;
    logic hit;

    assign last_beat = (beat_count == BEATS-1);
    // decode address from L1
    assign offset = a_l1.addr[OFFSET_BITS-1:0];
    assign index = a_l1.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign tag = a_l1.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    // if tags match and data is valid, there is a cache hit
    assign hit = (tag[index] == tag) && valid[index];

    always_comb begin
        next_state = state;
        case (state)
        IDLE: begin
            

        READ:

        RESPOND:

        WRITE:

        ACK:

        default:
        endcase
