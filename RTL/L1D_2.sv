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

    localparam int L2_SETS     = 8;
    localparam int L2_WAYS     = 2;
    localparam int OFFSET_BITS = $clog2(LINE_BYTES);                    
    localparam int INDEX_BITS  = $clog2(L2_SETS);                       
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
    localparam int L2_LINE_AW  = $clog2(L2_SETS * L2_WAYS);

    logic [DATA_WIDTH-1:0] data2 [0:L2_SETS*L2_WAYS-1][0:BEATS-1];

    logic [TAG_BITS-1] tag2 [0:L2_SETS*L2_WAYS-1];
    logic              valid2 [0:L2_SETS*L2_WAYS-1];
    logic              dirty2 [0:L2_SETS*L2_WAYS-1];
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

    assign hit_way0 = valid2[{index, 1'b0}] && (tag2[{index, 1'b0}] == tag);
    assign hit_way1 = valid2[{index, 1'b0}] && (tag2[{index, 1'b1}] == tag);
    assign hit = (hit_way0 || hit_way1) && (perms[index] != PERM_N);

    always_comb begin
        if (hit) outs.rdata = data2[index];
        else outs.stall;
    end