package tilelink_pkg;
    // channel width parameters
    parameter int ADDR_WIDTH = 16; // address width of main memory
    parameter int DATA_WIDTH = 32; // data is 32 bits = 4 bytes
    parameter int LINE_BYTES = 16; // 16 bytes per cache line
    parameter int SIZE_WIDTH = 3; // size = 4 (log2(16)) so 3 bits needed
    local parameter int BEATS = LINE_BYTES/(DATA_WIDTH/8); // data path is 4 bytes, need to transfer 16 bytes = 4 beats total
    local parameter int SOURCE_WIDTH = 2; // L2 communicates with 4 L1s so 2 bits needed
    local parameter int SINK_WIDTH = 2; // each L1 can have an outstanding grant, so 4 total = 2 bits
    local parameter int OPCODE_WIDTH = 3; // 3 bits for the opcode
    local parameter int PARAM_WIDTH = 3; // 3 bits for parameter (permission) changes

    // CHANNEL A OPCODES (master -> student)
    local parameter logic [2:0] PUT_FULL_DATA = 3'd0; // L2 writes full line back to main memory
    local parameter logic [2:0] GET           = 3'd4; // L2 reads a line from main memory for cache fill
    local parameter logic [2:0] ACQUIRE_BLOCK = 3'd6; // L1 reads a line from L2 and gets read and/or write permissions
    local parameter logic [2:0] ACQUIRE_PERM  = 3'd7; // L1 asks L2 for permissions only, no data

    // CHANNEL B OPCODES (student -> master)
    local parameter logic [2:0] PROBE_BLOCK = 3'd6; // L2 downgrades L1 permissions and sends data back if dirty
    local parameter logic [2:0] PROBE_PERM  = 3'd7; // same thing as ProbeBlock but does not take data back

    // CHANNEL C OPCODES (master -> student)
    local parameter logic [2:0] PROBE_ACK      = 3'd4; // L1's reply to a probe where line is unmodified
    local parameter logic [2:0] PROBE_ACK_DATA = 3'd5; // L1's reply to a ProbeBlock
    local parameter logic [2:0] RELEASE        = 3'd6; // L1 voluntarily gives up permission on a clean line
    local parameter logic [2:0] RELEASE_DATA   = 3'd7; // Same as Release but the line is dirty

    // CHANNEL D OPCODES (student -> master)
    local parameter logic [2:0] ACCESS_ACK      = 3'd0; // Main memory's acknowledgement of completed Put
    local parameter logic [2:0] ACCESS_ACK_DATA = 3'd1; // Memory's respone to a Get, carrying requested data to L2
    local parameter logic [2:0] GRANT           = 3'd4; // L2 response to any Acquire where no data is transferred
    local parameter logic [2:0] GRANT_DATA      = 3'd5; // L2 response to Acquire Block
    local parameter logic [2:0] RELEASE_ACK     = 3'd6; // L2 acknowledgement for Release or ReleaseData


    // used in tag array to identify what permission each line has
    typedef enum logic [1:0] {
        PERM_N = 2'b00,
        PERM_B = 2'b01,
        PERM_T = 2'b10
    } perm_t;

    // report permission state with no change, used in Channel C
    typedef enum logic [PARAM_WIDTH-1:0] {
        T_TO_T = 3'd3, 
        B_TO_B = 3'd4, 
        N_TO_N = 3'd5
    } report_t;

    // grow to more permissive state, used in Channel A
    typedef enum logic [PARAM_WIDTH-1:0] {
        N_TO_B = 3'd0, 
        N_TO_T = 3'd1, 
        B_TO_T = 3'd2
    } grow_t;

    // Cap permission state to certain level, used in Channels B and D
    typedef enum logic [PARAM_WIDTH-1:0] {
        TO_T = 3'd0, 
        TO_B = 3'd1, 
        TO_N = 3'd2
    } cap_t;

    // Shrink permissions to more restrictive state, used in Channel C
    typedef enum logic [PARAM_WIDTH-1:0] {
        T_TO_B = 3'd0,
        T_TO_N = 3'd1,
        B_TO_N = 3'd2
    } shrink_t;

    // signals on channel A
    typedef struct packed {
        logic [OPCODE_WIDTH-1:0]    opcode; // decodes message
        logic [PARAM_WIDTH-1:0]     param; // identifies transition of permission. Grow for channel A
        logic [SIZE_WIDTH-1:0]      size; // log2(LINE_BYTES) = 4
        logic [SOURCE_WIDTH-1:0]    source; // identifies the cache sending request
        logic [ADDR_WIDTH-1:0]      addr; // cache line that being modified
        logic [DATA_WIDTH/8-1:0]    mask; // which bits to modify. Hardwired 0 since we modify by cache line
        logic [DATA_WIDTH-1:0]      data; // data being transferred
        logic                       corrupt; // identifies if cache line has been corrupted
    } channel_a;

    // Signals on channel B
    typedef struct packed {
        logic [OPCODE_WIDTH-1:0]    opcode;
        logic [PARAM_WIDTH-1:0]     param; // cap for channel B
        logic [SIZE_WIDTH-1:0]      size;
        logic [SOURCE_WIDTH-1:0]    source;
        logic [ADDR_WIDTH-1:0]      addr;
        logic [DATA_WIDTH/8-1:0]    mask;
        logic [DATA_WIDTH-1:0]      data;
        logic                       corrupt;
    } channel_b;

    // signals on channel C
    typedef struct packed {
        logic [OPCODE_WIDTH-1:0]    opcode;
        logic [PARAM_WIDTH-1:0]     param; // either shrink or report for channel C    
        logic [SIZE_WIDTH-1:0]      size;
        logic [SOURCE_WIDTH-1:0]    source;
        logic [ADDR_WIDTH-1:0]      addr;
        logic [DATA_WIDTH-1:0]      data;
        logic                       corrupt;
    } channel_c;

    // signals on channel D
    typedef struct packed {
        logic [OPCODE_WIDTH-1:0]    opcode;
        logic [PARAM_WIDTH-1:0]     param; // cap for channel D
        logic [SIZE_WIDTH-1:0]      size;
        logic [SOURCE_WIDTH-1:0]    source;
        logic [SINK_WIDTH-1:0]      sink; // identifies which L1's outstanding grant is being addressed
        logic [DATA_WIDTH-1:0]      data;
        logic                       corrupt;
        logic                       denied; // tracks if a request has been denied
    } channel_d;

    // signal on channel e
    typedef struct packed {
        logic [SINK_WIDTH-1:0] sink; // sends save value as sink on channel D back to D as grant ack.
    } channel_e;

    // cpu requests and responses
    typedef struct packed {
        logic                  opcode;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] st_data;
    } cpu_req_t;

    typedef struct packed {
        logic [DATA_WIDTH-1:0] rdata;
        logic                  stall;
    } cpu_resp_t;
endpackage