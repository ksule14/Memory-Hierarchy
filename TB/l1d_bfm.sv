// Stands in for L2 from one L1D cache's point of view, so the cache can be
// tested completely in isolation (no real L2/main_memory in the loop).
//
// Services:
//   - Channel A (Acquire) -> responds on Channel D with Grant/GrantData
//   - Channel C (Release/ReleaseData) -> responds on Channel D with ReleaseAck
//   - Channel C (ProbeAck/ProbeAckData) -> captured for whoever called send_probe
//   - Channel E (GrantAck) -> always accepted
//   - Channel B (Probe) -> driven only by the explicit send_probe task, so
//     directed tests control exactly when a probe arrives (e.g. mid-EVICT)
//
// A tiny backing "memory" (an associative array keyed by line address+beat)
// supplies GrantData fill content and records what Release(Data) writes
// back, so directed tests can preload expected data and/or check writeback
// content without any real memory hierarchy behind this BFM.
import tilelink_pkg::*;

module l2_bfm #(
    parameter int MAX_READY_DELAY_INIT = 0, // initial value; change at runtime with set_delays()
    parameter int MAX_VALID_DELAY_INIT = 0,
    parameter logic [1:0] EXPECTED_SOURCE = 2'd1, // this L1's fixed TileLink source id, checked against chan_a/chan_c
    parameter bit         CHECK_SOURCE    = 1'b1  // 0 when several L1s share this BFM through l2_controller
)(
    input  logic clk,
    input  logic rst,

    // channel A: L1 -> L2 (Acquire)
    input  channel_a chan_a,
    input  logic     chan_a_valid,
    output logic     chan_a_ready,

    // channel B: L2 -> L1 (Probe), driven only by send_probe()
    output channel_b chan_b,
    output logic     chan_b_valid,
    input  logic     chan_b_ready,

    // channel C: L1 -> L2 (Release / ProbeAck)
    input  channel_c chan_c,
    input  logic     chan_c_valid,
    output logic     chan_c_ready,

    // channel D: L2 -> L1 (Grant / ReleaseAck)
    output channel_d chan_d,
    output logic     chan_d_valid,
    input  logic     chan_d_ready,

    // channel E: L1 -> L2 (GrantAck)
    input  channel_e chan_e,
    input  logic     chan_e_valid,
    output logic     chan_e_ready
);

    localparam int BEAT_BITS = (BEATS > 1) ? $clog2(BEATS) : 1;

    // ------------------------------------------------------------------
    // backing memory model
    // ------------------------------------------------------------------
    typedef logic [ADDR_WIDTH+BEAT_BITS-1:0] mem_key_t;
    logic [DATA_WIDTH-1:0] mem [mem_key_t];

    function automatic logic [ADDR_WIDTH-1:0] line_addr(input logic [ADDR_WIDTH-1:0] addr);
        line_addr = {addr[ADDR_WIDTH-1:$clog2(LINE_BYTES)], {$clog2(LINE_BYTES){1'b0}}};
    endfunction

    function automatic mem_key_t mem_key(input logic [ADDR_WIDTH-1:0] addr, input int beat);
        mem_key = {line_addr(addr), beat[BEAT_BITS-1:0]};
    endfunction

    // deterministic pattern for any beat the test never explicitly preloaded,
    // so expected values can be computed without a preload call
    function automatic logic [DATA_WIDTH-1:0] default_fill(input logic [ADDR_WIDTH-1:0] addr, input int beat);
        default_fill = {line_addr(addr), 16'(beat)};
    endfunction

    function automatic logic [DATA_WIDTH-1:0] read_beat(input logic [ADDR_WIDTH-1:0] addr, input int beat);
        automatic mem_key_t k = mem_key(addr, beat);
        read_beat = mem.exists(k) ? mem[k] : default_fill(addr, beat);
    endfunction

    task automatic preload_line(input logic [ADDR_WIDTH-1:0] addr, input logic [DATA_WIDTH-1:0] beat_data [BEATS]);
        for (int b = 0; b < BEATS; b++) mem[mem_key(addr, b)] = beat_data[b];
    endtask

    // ------------------------------------------------------------------
    // shared helpers
    // ------------------------------------------------------------------
    semaphore d_lock = new(1); // chan_d is driven by both the Acquire responder and the Release acker

    initial begin
        chan_d       = '0;
        chan_d_valid = 1'b0; // otherwise X until the first response, tripping d_valid_known
    end

    // runtime-adjustable backpressure knobs (0 = deterministic/always-ready,
    // matching most directed tests; set_delays() dials in fuzzing for the
    // specific tests that want it)
    int max_ready_delay = MAX_READY_DELAY_INIT;
    int max_valid_delay = MAX_VALID_DELAY_INIT;

    task automatic set_delays(input int ready_max, input int valid_max);
        max_ready_delay = ready_max;
        max_valid_delay = valid_max;
    endtask

    function automatic int rand_delay(int max_delay);
        rand_delay = (max_delay == 0) ? 0 : $urandom_range(0, max_delay);
    endfunction

    task automatic drive_d_beat(input channel_d beat);
        d_lock.get(1);
        repeat (rand_delay(max_valid_delay)) @(negedge clk);
        chan_d       <= beat;
        chan_d_valid <= 1'b1;
        @(posedge clk);
        while (!chan_d_ready) @(posedge clk);
        @(negedge clk);
        chan_d_valid <= 1'b0;
        d_lock.put(1);
    endtask

    task automatic accept_a_beat(output channel_a req);
        @(negedge clk);
        while (!chan_a_valid) @(negedge clk);
        repeat (rand_delay(max_ready_delay)) @(negedge clk);
        chan_a_ready <= 1'b1;
        // a beat only counts on a posedge where valid is actually high. valid
        // seen at the negedge can still fall before the posedge when it's
        // combinational from other inputs (l2_controller's channel priority)
        @(posedge clk);
        while (!chan_a_valid) @(posedge clk);
        req = chan_a;
        @(negedge clk);
        chan_a_ready <= 1'b0;
    endtask

    task automatic accept_c_beat(output channel_c beat);
        @(negedge clk);
        while (!chan_c_valid) @(negedge clk);
        repeat (rand_delay(max_ready_delay)) @(negedge clk);
        chan_c_ready <= 1'b1;
        // a beat only counts on a posedge where valid is actually high. valid
        // seen at the negedge can still fall before the posedge when it's
        // combinational from other inputs (l2_controller's channel priority)
        @(posedge clk);
        while (!chan_c_valid) @(posedge clk);
        beat = chan_c;
        @(negedge clk);
        chan_c_ready <= 1'b0;
    endtask

    // test-visible traffic observed, for directed tests to check e.g. "this
    // access was a pure hit" (acquire_count didn't move) without needing to
    // race the DUT's own internal signals
    int acquire_count = 0;
    logic [2:0] last_release_opcode;

    // ------------------------------------------------------------------
    // Channel A servicer: Acquire -> Grant/GrantData on D
    // ------------------------------------------------------------------
    initial begin
        chan_a_ready = 1'b0;
        forever begin
            automatic channel_a req;
            automatic channel_d resp;
            accept_a_beat(req);
            acquire_count++;

            if (CHECK_SOURCE && req.source !== EXPECTED_SOURCE)
                $error("l2_bfm: chan_a.source=%0d, expected %0d", req.source, EXPECTED_SOURCE);

            resp.sink    = '0;
            resp.size    = req.size;
            resp.source  = req.source;
            resp.corrupt = 1'b0;
            resp.denied  = 1'b0;

            if (req.opcode == ACQUIRE_PERM) begin
                // only reachable upgrade in this design is B_TO_T
                resp.opcode = GRANT;
                resp.param  = TO_T;
                resp.data   = '0;
                drive_d_beat(resp);
            end else begin // ACQUIRE_BLOCK
                resp.opcode = GRANT_DATA;
                resp.param  = (req.param == N_TO_T) ? TO_T : TO_B;
                for (int b = 0; b < BEATS; b++) begin
                    resp.data = read_beat(req.addr, b);
                    drive_d_beat(resp);
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Channel C monitor: demuxes Release(Data) (-> ReleaseAck on D) from
    // ProbeAck(Data) (-> handed back to whichever send_probe() is waiting)
    // ------------------------------------------------------------------
    logic [PARAM_WIDTH-1:0] probe_resp_param;
    logic                   probe_resp_has_data;
    logic [DATA_WIDTH-1:0]  probe_resp_data [BEATS];
    event                   probe_resp_ready;

    initial begin
        chan_c_ready = 1'b0;
        forever begin
            automatic channel_c beat;
            accept_c_beat(beat);

            if (CHECK_SOURCE && beat.source !== EXPECTED_SOURCE)
                $error("l2_bfm: chan_c.source=%0d, expected %0d", beat.source, EXPECTED_SOURCE);

            case (beat.opcode)
                RELEASE, RELEASE_DATA: begin
                    automatic logic [ADDR_WIDTH-1:0] raddr    = beat.addr;
                    automatic logic                  has_data = (beat.opcode == RELEASE_DATA);
                    automatic int                    nbeats   = has_data ? BEATS : 1;
                    automatic channel_d               dresp;

                    last_release_opcode = beat.opcode;
                    if (has_data) mem[mem_key(raddr, 0)] = beat.data;
                    for (int b = 1; b < nbeats; b++) begin
                        accept_c_beat(beat);
                        mem[mem_key(raddr, b)] = beat.data;
                    end

                    dresp.opcode  = RELEASE_ACK;
                    dresp.param   = '0;
                    dresp.size    = beat.size;
                    dresp.source  = beat.source;
                    dresp.sink    = '0;
                    dresp.data    = '0;
                    dresp.corrupt = 1'b0;
                    dresp.denied  = 1'b0;
                    drive_d_beat(dresp);
                end

                PROBE_ACK, PROBE_ACK_DATA: begin
                    automatic logic has_data = (beat.opcode == PROBE_ACK_DATA);
                    automatic int   nbeats   = has_data ? BEATS : 1;

                    probe_resp_param    = beat.param;
                    probe_resp_has_data = has_data;
                    probe_resp_data[0]  = beat.data;
                    for (int b = 1; b < nbeats; b++) begin
                        accept_c_beat(beat);
                        probe_resp_data[b] = beat.data;
                    end
                    -> probe_resp_ready;
                end

                default: $error("l2_bfm: unexpected chan_c opcode %0d", beat.opcode);
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Channel E acceptor: always services GrantAck
    // ------------------------------------------------------------------
    initial begin
        chan_e_ready = 1'b0;
        forever begin
            @(negedge clk);
            while (!chan_e_valid) @(negedge clk);
            repeat (rand_delay(max_ready_delay)) @(negedge clk);
            chan_e_ready <= 1'b1;
            @(posedge clk);
            while (!chan_e_valid) @(posedge clk); // same posedge-handshake rule as accept_a_beat
            @(negedge clk);
            chan_e_ready <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // send_probe: called directly by directed tests to inject a Probe at a
    // chosen moment (including mid-EVICT/WAIT, to hit the arbitration path)
    // ------------------------------------------------------------------
    initial begin
        chan_b_valid = 1'b0;
    end

    task automatic send_probe(
        input  logic [2:0]            opcode,
        input  logic [PARAM_WIDTH-1:0] param,
        input  logic [ADDR_WIDTH-1:0]  addr,
        output logic [PARAM_WIDTH-1:0] resp_param,
        output logic                   resp_has_data,
        output logic [DATA_WIDTH-1:0]  resp_data [BEATS]
    );
        automatic channel_b b;
        b.opcode  = opcode;
        b.param   = param;
        b.size    = SIZE_WIDTH'($clog2(LINE_BYTES));
        b.source  = '0;
        b.addr    = addr;
        b.mask    = '0;
        b.data    = '0;
        b.corrupt = 1'b0;

        @(negedge clk);
        chan_b       <= b;
        chan_b_valid <= 1'b1;
        @(posedge clk);
        while (!chan_b_ready) @(posedge clk);
        @(negedge clk);
        chan_b_valid <= 1'b0;

        @(probe_resp_ready);
        resp_param    = probe_resp_param;
        resp_has_data = probe_resp_has_data;
        resp_data     = probe_resp_data;
    endtask

endmodule
