module main_memory 
    import tilelink_pkg::*;
(
    input logic         clk,
    input logic         rst,
    // Channel A ports
    input channel_a     a_input,
    input logic         a_valid,
    output logic        a_ready,

    // Channel D ports
    output channel_d    d_output,
    output logic        d_valid,
    input logic         d_ready
);
    localparam MEM_DEPTH = (2**ADDR_WIDTH)/(DATA_WIDTH/8); // 32 bits per line, 2^ADDR_WIDTH gives total addressable entries.
                                                           // /(DATA_WIDTH/8) gives number of words instead of bytes

    localparam WORD_AW = $clog2(MEM_DEPTH); // width of word address, not byte address
    localparam BYTE_OFF = $clog2(DATA_WIDTH/8); // BYTE_OFF = 2. byte offset that differentiates word address and byte address
    // 64KB address space
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] ram [0:MEM_DEPTH-1]; 
    
    initial begin // initialize main memory
        $readmemh("initial_ram.hex", ram);
    end

    // states that main memory can be in
    typedef enum logic [2:0] {
        IDLE    = 3'd0,
        READ    = 3'd1,
        RESPOND = 3'd2,
        WRITE   = 3'd3,
        ACK     = 3'd4
    } state_t;

    state_t state;
    state_t next_state;

    // break down needed channel A inputs
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

    assign base_word_addr = saved_addr[ADDR_WIDTH-1:BYTE_OFF]; // registered address when a_valid and a_ready
    assign last_beat = (beat_count == (BEATS-1));
    assign a_ready = (state == IDLE) || (state == WRITE); // ready high on IDLE to capture beat, high on WRITE to capture the rest
    
    // write enable and write address logic
    // wr_en does not depend on a_ready because a_ready is high when state= IDLE or WRITE
    always_comb begin
        if (state == IDLE) begin
            wr_en = a_valid && (a_input.opcode == PUT_FULL_DATA);
            wr_addr = a_input.addr[ADDR_WIDTH-1:BYTE_OFF]; // capture first beat's address
        end else begin
            wr_en = a_valid && (state == WRITE); // wait for write state before continuing the write
            wr_addr = base_word_addr + WORD_AW'(beat_count); // increment address by the beat count
        end
    end
    
    always_ff @(posedge clk) begin
        if (wr_en) begin
            ram[wr_addr] <= a_input.data; // write to ram when wr_en is high
        end
        read_data <= ram[rd_addr]; // reading from ram happens every cycle simply due to BRAM architecture
        end 

    // state update
    always_ff @(posedge clk) begin
        if (rst) state <= IDLE;
        else state <= next_state;
    end
    
    // Combinational FSM. Used for next_state logic
    always_comb begin
        next_state = state;
        case(state)
        IDLE: begin // a_ready is high on IDLE
            if (a_valid) begin
                if (a_input.opcode == PUT_FULL_DATA) next_state = WRITE; // data is written to ram on PUT_FULL_DATA
                else if (a_input.opcode == GET) next_state = READ; // data is read from ram on GET
            end
        end

        READ: next_state = RESPOND; // This state exists purely to make up for the one cycle delay on read_data.

        RESPOND: begin // when response state starts, read_data is available. This is fundamentally different from a register
            if (d_valid && d_ready) begin // this is channel D so wait for d_valid (main memory) and d_ready (L2) to be high
                if (last_beat) next_state = IDLE; // do not return to IDLE until all beats have been transferred
                else next_state = READ; // while transferring beats, one cycle of delay needs to be accounted for between rd_addr incrementing and read_data being available
            end                         // therefore return to READ for one cycle delay
        end

        WRITE: if (a_valid && last_beat) next_state = ACK; // keep writing until last beat reached
        ACK: if (d_valid && d_ready) next_state = IDLE; // once channel d valid-ready handshake complete, return to IDLE
        default: next_state = IDLE;
        endcase
    end

    // sequential data path. Used for actual data storage and transfer
    always_ff @(posedge clk) begin
        if (rst) begin
            beat_count   <= '0;
            saved_addr   <= '0;
            saved_source <= '0;
            rd_addr      <= '0;
            d_valid      <= '0;
            d_output     <= '0;
        end else begin 
            case (state)
            IDLE: begin
                if (a_valid) begin
                    saved_addr <= a_input.addr; // data from L2 is valid, so capture the base address
                    saved_source <= a_input.source; // same as address but for source

                    if (a_input.opcode == PUT_FULL_DATA) begin
                        // beat 0 written in IDLE state to bram block because wr_en goes high in IDLE state causing first beat to be written here
                        // start beat_count at 1 so write handles beats 1-3
                        beat_count <= 1;
                    end else if (a_input.opcode == GET) begin // one cycle delay in reads so nothing is read in IDLE state
                        beat_count <= '0;
                        rd_addr <= a_input.addr[ADDR_WIDTH-1:BYTE_OFF]; // rd_addr is pointed to base addr so data is ready after one cycle delay
                    end
                end
            end

            READ: begin // the one cycle delauy
                // 1 cycle bram latency so read_data holds current
                // rd_addr's data next cycle in RESPOND state
                d_valid <= '0; // data is not valid until RESPOND state
            end

            RESPOND: begin
                // drive valid and data
                d_valid          <= 'd1;
                d_output.opcode  <= ACCESS_ACK_DATA; // this is the message in response to GET. It carries data
                d_output.source  <= saved_source;
                d_output.data    <= read_data; // output the latched data here
                d_output.param   <= '0;
                d_output.size    <= SIZE_WIDTH'($clog2(LINE_BYTES));
                d_output.sink    <= '0;
                d_output.corrupt <= '0; // corrupt is hard-wired zero since generators will not produce incorrect data
                d_output.denied  <= '0; // data will not be denied here

                if (d_valid && d_ready) begin
                    if (last_beat) begin // after last beat return counter to 0 and turn off valid
                        d_valid <= '0;
                        beat_count <= '0;
                    end else begin // ALL OF THIS STUFF HAPPENS DURING THE ONE CYCLE LATENCY IN READ, NOT IN RESPOND
                                   // THE VALID GOING LOW AND BEAT COUNTER AND ADDRESS INCREMENTS HAPPEN IN READ AND VALID DATA RESOLVES AGAIN IN RESPOND
                        d_valid <= '0;
                        beat_count <= beat_count + 1; // drive data until d_valid and d_ready, then increment beat_counter
                        rd_addr <= base_word_addr + WORD_AW'(beat_count + 1); // increment write address every successful transfer
                    end
                end
            end

            WRITE: begin
                if (a_valid) begin // continue writing as long as data is valid from L2
                    if (last_beat) beat_count <= '0;
                    else beat_count <= beat_count + 1;
                end
            end

            ACK: begin
                d_valid          <= 'd1; // valid high so output can be sent
                d_output.opcode  <= ACCESS_ACK; // Response message to a PUT_FULL_DATA. This carries no data
                d_output.source  <= saved_source;
                d_output.data    <= '0;
                d_output.param   <= '0;
                d_output.size    <= SIZE_WIDTH'($clog2(LINE_BYTES));
                d_output.sink    <= '0;
                d_output.corrupt <= '0;
                d_output.denied  <= '0;

                if (d_valid && d_ready) d_valid <= '0; // drop valid once handshake is confirmed
            end
            default: begin
                beat_count   <= '0;
                saved_addr   <= '0;
                saved_source <= '0;
                rd_addr      <= '0;
                d_valid      <= '0;
                d_output     <= '0;
            end
        endcase
        end
    end
endmodule