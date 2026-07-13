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
    localparam int L2_WAYS     = 2;
    localparam int OFFSET_BITS = $clog2(LINE_BYTES);                    
    localparam int INDEX_BITS  = $clog2(L2_SETS);                       
    localparam int TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
    localparam int L2_LINE_AW  = $clog2(L2_SETS * L2_WAYS);           

    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] l2 [0:L2_SETS*L2_WAYS-1][0:BEATS-1];

    logic [TAG_BITS-1:0] l2_tag     [0:L2_SETS*L2_WAYS-1];
    logic                valid_array [0:L2_SETS*L2_WAYS-1];
    logic                dirty_array [0:L2_SETS*L2_WAYS-1];

    typedef enum logic [3:0] {  
        IDLE       = 4'd0,
        MM_READ    = 4'd1,
        MM_RESPOND = 4'd2,
        MM_WRITE   = 4'd3,
        MM_ACK     = 4'd4,      
        L2_READ    = 4'd5,
        L2_RESPOND = 4'd6,
        L2_WRITE   = 4'd7,
        L2_ACK     = 4'd8
    } to_mem_state_t;

    to_mem_state_t state, next_state;

    logic [ADDR_WIDTH-1:0]    saved_addr;
    logic [SOURCE_WIDTH-1:0]  saved_source;
    logic [$clog2(BEATS)-1:0] beat_count;
    logic [L2_LINE_AW-1:0]    rd_addr;       
    logic [L2_LINE_AW-1:0]    wr_addr;       
    logic                     wr_en;
    logic [DATA_WIDTH-1:0]    read_data;
    logic                     reg_hit;        

    // combinational signals
    logic [L2_LINE_AW-1:0] base_line_addr;   // line address into BRAM (set*WAYS + way),
                                              // will be driven in the sequential block
    logic                  last_beat;
    logic [OFFSET_BITS-1:0] offset;
    logic [INDEX_BITS-1:0]  index;
    logic [TAG_BITS-1:0]    tag;
    logic                   hit_way0, hit_way1;
    logic                   hit;
    logic                   hit_way;          // which way had the hit (0 or 1)

    assign last_beat = (beat_count == BEATS-1);

    // decode incoming L1 address into offset, index, and tag
    assign offset = a_L1.addr[OFFSET_BITS-1:0];             
    assign index  = a_L1.addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS]; 
    assign tag    = a_L1.addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];  

    // check both ways for a hit                                       
    assign hit_way0 = valid_array[{index, 1'b0}] &&    // append 0 for all Way0 in a set because set*ways is ordered with a zero at the end              
                      (l2_tag[{index, 1'b0}] == tag);                
    assign hit_way1 = valid_array[{index, 1'b1}] &&
                      (l2_tag[{index, 1'b1}] == tag); // append 1 for all Way1 in a set because set*ways is ordered with a one at the end
    assign hit      = hit_way0 || hit_way1;
    assign hit_way  = hit_way1 ? 1'b1 : 1'b0;

    assign a_L1_ready = (state == IDLE);


    // state register
    always_ff @(posedge clk) begin
        if (rst) state <= IDLE;
        else     state <= next_state;
    end

    // combinational FSM — state transitions only
    always_comb begin
        next_state = state;
        case (state)

            IDLE: begin
                if (a_L1_valid) begin
                    if (a_L1.opcode == ACQUIRE_BLOCK) begin
                        if (hit) next_state = L2_READ;  // hit: go fetch from L2 BRAM
                        else if (dirty_victim) next_state = MM_WRITE;  // miss: go fetch from memory first
                        else next_state = MM_READ;
                    end
                end
            end  

            L2_READ: begin               // Only enter this stage on cache hit
                next_state = L2_RESPOND; // 1-cycle BRAM latency, then go respond to L1
            end                          

            MM_READ: begin                      // state where GET is sent
                if (a_mem_valid && a_mem_ready) 
                    next_state = MM_RESPOND;  
            end                                 

            MM_RESPOND: begin
                if (d_mem_valid && d_mem_ready) begin  // Data comes back on Channel D.
                    if (last_beat) next_state = L2_READ; // on last beat go to L2_READ so we can send data on GrantData to L1 
                    else           next_state = MM_RESPOND; 
                end                                         
            end                                            

            MM_WRITE: begin
                if (a_mem_valid && a_mem_ready) begin // keep writing last beat has been transferred.
                    if (last_beat) next_state = MM_ACK;
                end
            end
                    
            MM_ACK: begin
                if (d_mem_valid && d_mem_ready) next_state = MM_READ;  // collects AcessAck, which has no data, so move to writing the new Get value.
            end

            L2_RESPOND: begin
                if (d_L1_valid && d_L1_ready) begin
                    if (last_beat) next_state = IDLE;
                    else           next_state = L2_READ; // between beats go to L2_READ to fetch next beat
                end                                      
            end                                          

            L2_WRITE: ;  // placeholder

            L2_ACK:   ;  // placeholder

            default: next_state = IDLE;
        endcase
    end

endmodule