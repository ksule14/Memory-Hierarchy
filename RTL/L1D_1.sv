module L1_cache1 
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

    localparam int L2_SETS     = 8;
    localparam int L2_WAYS     = 2;
    localparam int OFFSET_BITS = $clog2(LINE_BYTES);                    
    localparam int INDEX_BITS  = $clog2(L2_SETS);                       
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
    localparam int L2_LINE_AW  = $clog2(L2_SETS * L2_WAYS);

    logic [DATA_WIDTH-1:0] data1 [0:L2_SETS*L2_WAYS-1][0:BEATS-1];

    logic [TAG_BITS-1] tag1 [0:L2_SETS*L2_WAYS-1];
    logic              valid1 [0:L2_SETS*L2_WAYS-1];
    logic              dirty1 [0:L2_SETS*L2_WAYS-1];
    perm_t             perms [0:L2_SETS*L2_WAYS-1];

    logic                   last_beat;
    logic [OFFSET_BITS-1:0] offset;
    logic [INDEX_BITS-1:0]  index;
    logic [TAG_BITS-1:0]    tag;
    logic                   hit_way0, hit_way1;
    logic                   hit;

    assign offset = ins.addr[OFFSET_BITS-1:0];
    assign index = ins.addr [INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    assign tag = ins.addr [ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];

    assign hit_way0 = valid1[{index, 1'b0}] && (tag1[{index, 1'b0}] == tag);
    assign hit_way1 = valid1[{index, 1'b0}] && (tag1[{index, 1'b1}] == tag);
    assign hit = (hit_way0 || hit_way1) && (perms[index] != PERM_N);

    typedef enum logic [] {
        IDLE, REQUEST, WAIT, WRITE, ACK
    } miss_t;

    miss_t miss_state;
    miss_t next_miss_state;
    always_ff @(posedge clk) begin
        if (rst) miss_state <= IDLE;
        else miss_state <= next_miss_state;
    end

    always_comb begin
        outs.rdata = '0;
        outs.stall = '0;
        if (hit) begin
            outs.rdata = data1[ins.addr];
        end
        else begin
            outs.stall = 'd1;
            case(miss_state)
            IDLE: begin
                if (!hit) next_state <= REQUEST;
            end
            REQUEST: begin
                if (tag1[{index, 1'b0}] == tag) channel_a.


    