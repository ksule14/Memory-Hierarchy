`timescale 1ns/1ps
// Isolated testbench for L1_cache2: mirrors tb_L1D_1.sv exactly, against
// the second cache's own (separately hand-written) module. Kept as its own
// file rather than a parameterized/shared TB because L1_cache1/L1_cache2
// are themselves separate, non-parameterized modules -- this is exactly
// what will catch behavioral divergence between the two.
import tilelink_pkg::*;

module tb_L1D_2;

    localparam int L1_ID_VAL = 2;

    logic clk = 0;
    logic rst;
    always #5 clk = ~clk; // 10ns period

    cpu_req_t  ins;
    cpu_resp_t outs;

    channel_a chan_a;
    logic     chan_a_valid, chan_a_ready;
    channel_b chan_b;
    logic     chan_b_valid, chan_b_ready;
    channel_c chan_c;
    logic     chan_c_valid, chan_c_ready;
    channel_d chan_d;
    logic     chan_d_valid, chan_d_ready;
    channel_e chan_e;
    logic     chan_e_valid, chan_e_ready;

    L1_cache2 dut (
        .clk(clk), .rst(rst), .ins(ins), .outs(outs),
        .chan_a(chan_a), .chan_a_valid(chan_a_valid), .chan_a_ready(chan_a_ready),
        .chan_b(chan_b), .chan_b_valid(chan_b_valid), .chan_b_ready(chan_b_ready),
        .chan_c(chan_c), .chan_c_valid(chan_c_valid), .chan_c_ready(chan_c_ready),
        .chan_d(chan_d), .chan_d_valid(chan_d_valid), .chan_d_ready(chan_d_ready),
        .chan_e(chan_e), .chan_e_valid(chan_e_valid), .chan_e_ready(chan_e_ready)
    );

    l2_bfm #(.EXPECTED_SOURCE(L1_ID_VAL[1:0])) bfm (
        .clk(clk), .rst(rst),
        .chan_a(chan_a), .chan_a_valid(chan_a_valid), .chan_a_ready(chan_a_ready),
        .chan_b(chan_b), .chan_b_valid(chan_b_valid), .chan_b_ready(chan_b_ready),
        .chan_c(chan_c), .chan_c_valid(chan_c_valid), .chan_c_ready(chan_c_ready),
        .chan_d(chan_d), .chan_d_valid(chan_d_valid), .chan_d_ready(chan_d_ready),
        .chan_e(chan_e), .chan_e_valid(chan_e_valid), .chan_e_ready(chan_e_ready)
    );

    // channel protocol checks (valid/ready/payload discipline)
    chan_a_checker #(.NAME("tb_L1D_2.chan_a")) u_chk_a(.clk(clk), .rst(rst), .valid(chan_a_valid), .ready(chan_a_ready), .data(chan_a));
    chan_b_checker #(.NAME("tb_L1D_2.chan_b")) u_chk_b(.clk(clk), .rst(rst), .valid(chan_b_valid), .ready(chan_b_ready), .data(chan_b));
    chan_c_checker #(.NAME("tb_L1D_2.chan_c")) u_chk_c(.clk(clk), .rst(rst), .valid(chan_c_valid), .ready(chan_c_ready), .data(chan_c));
    chan_d_checker #(.NAME("tb_L1D_2.chan_d")) u_chk_d(.clk(clk), .rst(rst), .valid(chan_d_valid), .ready(chan_d_ready), .data(chan_d));
    chan_e_checker #(.NAME("tb_L1D_2.chan_e")) u_chk_e(.clk(clk), .rst(rst), .valid(chan_e_valid), .ready(chan_e_ready), .data(chan_e));

    // internal-state invariants, bound onto this DUT's own array/FSM names
    bind L1_cache2 l1d_internal_checks #(.NUM_LINES(L1_SETS*L1_WAYS), .L1_SETS(L1_SETS)) u_internal_checks (
        .clk(clk), .rst(rst),
        .perms(perms2), .dirty(dirty2),
        .hit_way0(hit_way0), .hit_way1(hit_way1),
        .miss_state(miss_state), .probe_state(probe_state)
    );

    // ------------------------------------------------------------------
    // CPU-side driver. The cache is non-blocking: cpu_issue only waits for
    // the request to be accepted (valid && !stall), and responses are
    // collected by id in the background by the monitor below, so a test
    // can have several requests in flight and check completion order.
    // ------------------------------------------------------------------
    localparam int NUM_IDS = 2**CPU_ID_WIDTH;

    int errors = 0; // declared up here because the response monitor below also bumps it

    logic [CPU_ID_WIDTH-1:0] next_id = '0;
    bit                      resp_seen  [NUM_IDS];
    logic [DATA_WIDTH-1:0]   resp_rdata [NUM_IDS];
    int                      resp_order [$]; // ids in the order their responses came back
    bit                      saw_stall;      // set whenever a presented request was pushed back

    // outs.valid/id/rdata are registered, so sampling at posedge sees the
    // value the DUT held for the whole previous cycle, exactly once
    always @(posedge clk) begin
        if (!rst && outs.valid) begin
            if (resp_seen[outs.id]) begin
                errors++;
                $error("CHECK FAILED: duplicate response for id %0d", outs.id);
            end
            resp_seen[outs.id]  = 1'b1;
            resp_rdata[outs.id] = outs.rdata;
            resp_order.push_back(outs.id);
        end
        if (!rst && ins.valid && outs.stall) saw_stall = 1'b1;
    end

    // present one request starting at the next negedge, hold it until the
    // posedge it's accepted on, then return (leaving it on the bus so a
    // following cpu_issue can go back-to-back). Call cpu_idle when done.
    task automatic cpu_issue(input logic op, input logic [ADDR_WIDTH-1:0] a,
                              input logic [DATA_WIDTH-1:0] wdata, output logic [CPU_ID_WIDTH-1:0] id);
        @(negedge clk);
        id = next_id;
        next_id++;
        resp_seen[id] = 1'b0;
        ins = '{valid: 1'b1, opcode: op, id: id, addr: a, st_data: wdata};
        @(posedge clk);
        while (outs.stall) @(posedge clk);
    endtask

    task automatic cpu_idle();
        @(negedge clk);
        ins.valid = 1'b0;
    endtask

    task automatic cpu_wait(input logic [CPU_ID_WIDTH-1:0] id, output logic [DATA_WIDTH-1:0] rdata);
        wait (resp_seen[id] === 1'b1);
        rdata = resp_rdata[id];
    endtask

    function automatic int resp_pos(input logic [CPU_ID_WIDTH-1:0] id);
        foreach (resp_order[i]) if (resp_order[i] == id) return i;
        return -1;
    endfunction

    // one request at a time, waits for its response (used by the original
    // directed tests, which don't care about overlap)
    task automatic cpu_op(input logic op, input logic [ADDR_WIDTH-1:0] a,
                           input logic [DATA_WIDTH-1:0] wdata, output logic [DATA_WIDTH-1:0] rdata);
        automatic logic [CPU_ID_WIDTH-1:0] id;
        cpu_issue(op, a, wdata, id);
        cpu_idle();
        cpu_wait(id, rdata);
    endtask

    task automatic cpu_load(input logic [ADDR_WIDTH-1:0] a, output logic [DATA_WIDTH-1:0] rdata);
        cpu_op(1'b0, a, '0, rdata);
    endtask

    task automatic cpu_store(input logic [ADDR_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] wdata);
        automatic logic [DATA_WIDTH-1:0] unused;
        cpu_op(1'b1, a, wdata, unused);
    endtask

    task automatic do_reset();
        rst = 1'b1;
        ins = '{valid: 1'b0, opcode: 1'b0, id: '0, addr: '0, st_data: '0};
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
    endtask

    function automatic logic [ADDR_WIDTH-1:0] mk_addr(input logic [8:0] tag, input logic [2:0] set);
        mk_addr = {tag, set, 4'h0}; // offset=0 -> beat 0, byte 0
    endfunction

    // ------------------------------------------------------------------
    // self-checking
    // ------------------------------------------------------------------
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $error("CHECK FAILED: %s", msg);
        end
    endtask

    // ------------------------------------------------------------------
    // directed tests
    // ------------------------------------------------------------------
    task automatic test_reset();
        check(dut.miss_state == dut.IDLE, "reset: miss_state should be IDLE");
        check(dut.probe_state == dut.PROBE_IDLE, "reset: probe_state should be PROBE_IDLE");
        check(outs.stall === 1'b0, "reset: outs.stall should be low (no request presented, buffer empty)");
        check(outs.valid === 1'b0, "reset: no response should be pending");
        check(dut.rq_count == 0, "reset: request buffer should be empty");
    endtask

    // plain load miss: fill with N_TO_B, verify data + PERM_B, no dirty
    task automatic test_load_miss_fill();
        automatic logic [ADDR_WIDTH-1:0] a = mk_addr(9'h001, 3'd0);
        automatic logic [DATA_WIDTH-1:0] rdata;
        cpu_load(a, rdata);
        check(rdata == bfm.default_fill(a, 0), "load-miss-fill: rdata mismatch");
        check(dut.perms2[{3'd0, dut.saved_way}] == PERM_B, "load-miss-fill: perm should be B");
        check(dut.valid2[{3'd0, dut.saved_way}] == 1'b1, "load-miss-fill: line should be valid");
        check(dut.dirty2[{3'd0, dut.saved_way}] == 1'b0, "load-miss-fill: freshly filled line should be clean");
    endtask

    // store miss: fill with N_TO_T, the same instruction's write-through
    // then lands on the very cycle stall drops, so re-read to confirm it stuck
    task automatic test_store_miss_and_readback();
        automatic logic [ADDR_WIDTH-1:0] a = mk_addr(9'h001, 3'd1);
        automatic logic [DATA_WIDTH-1:0] rdata;
        cpu_store(a, 32'hCAFEF00D);
        check(dut.perms2[{3'd1, dut.saved_way}] == PERM_T, "store-miss: perm should be T");
        cpu_load(a, rdata);
        check(rdata == 32'hCAFEF00D, "store-miss: readback should see the stored word");
        check(bfm.acquire_count > 0, "store-miss: sanity, should have gone through an Acquire");
    endtask

    // load (fills B) then store to the same line: B->T upgrade via ACQUIRE_PERM
    task automatic test_b_to_t_upgrade();
        automatic logic [ADDR_WIDTH-1:0] a = mk_addr(9'h001, 3'd2);
        automatic logic [DATA_WIDTH-1:0] rdata;
        automatic int acq_before;
        cpu_load(a, rdata);
        check(dut.perms2[{3'd2, dut.saved_way}] == PERM_B, "upgrade: should start at B after load");
        acq_before = bfm.acquire_count;
        cpu_store(a, 32'h12345678);
        check(bfm.acquire_count == acq_before + 1, "upgrade: store-hit-on-B should issue exactly one more Acquire");
        check(dut.perms2[{3'd2, dut.saved_way}] == PERM_T, "upgrade: perm should be T after upgrade");
        cpu_load(a, rdata);
        check(rdata == 32'h12345678, "upgrade: readback should see the stored word");
    endtask

    // two distinct tags into the same set: round-robin should place them in
    // different ways, so the second access to the first tag is a pure hit
    task automatic test_second_way_fill_and_hit();
        automatic logic [ADDR_WIDTH-1:0] a0 = mk_addr(9'h010, 3'd3);
        automatic logic [ADDR_WIDTH-1:0] a1 = mk_addr(9'h011, 3'd3);
        automatic logic [DATA_WIDTH-1:0] rdata;
        automatic int acq_before;

        cpu_load(a0, rdata); // fills way rr[3] (0 initially), toggles rr[3] to 1
        check(rdata == bfm.default_fill(a0, 0), "second-way: a0 fill data mismatch");
        cpu_load(a1, rdata); // no eviction: the other way is still invalid
        check(rdata == bfm.default_fill(a1, 0), "second-way: a1 fill data mismatch");
        check(dut.valid2[{3'd3, 1'b0}] && dut.valid2[{3'd3, 1'b1}], "second-way: both ways should now be valid");
        check(dut.tag2[{3'd3, 1'b0}] != dut.tag2[{3'd3, 1'b1}], "second-way: the two ways should hold different tags");

        acq_before = bfm.acquire_count;
        cpu_load(a0, rdata); // pure hit now, should not touch the BFM at all
        check(bfm.acquire_count == acq_before, "second-way: re-accessing a0 should be a pure hit (no Acquire)");
        check(rdata == bfm.default_fill(a0, 0), "second-way: a0 re-read data mismatch");
    endtask

    // a third distinct tag to the same set now must evict whichever way the
    // round-robin points to; both existing lines are clean loads, so this
    // must be a plain Release, not ReleaseData
    task automatic test_clean_evict();
        automatic logic [ADDR_WIDTH-1:0] a2 = mk_addr(9'h012, 3'd3);
        automatic logic [DATA_WIDTH-1:0] rdata;
        cpu_load(a2, rdata);
        check(rdata == bfm.default_fill(a2, 0), "clean-evict: new line fill data mismatch");
        check(bfm.last_release_opcode == RELEASE, "clean-evict: victim was clean, expected plain RELEASE");
    endtask

    // store-fill (dirty) + load-fill second way + third tag forces eviction
    // of the dirty line: must be ReleaseData, and the BFM's memory model
    // should end up holding the written word plus the untouched beats
    task automatic test_dirty_evict_writeback();
        automatic logic [ADDR_WIDTH-1:0] a0 = mk_addr(9'h020, 3'd4); // will be dirtied then evicted
        automatic logic [ADDR_WIDTH-1:0] a1 = mk_addr(9'h021, 3'd4);
        automatic logic [ADDR_WIDTH-1:0] a2 = mk_addr(9'h022, 3'd4); // forces the eviction
        automatic logic [DATA_WIDTH-1:0] rdata;

        cpu_store(a0, 32'hDEAD_BEEF); // true miss, fills+dirties beat 0 of a0's line
        cpu_load(a1, rdata);          // fills the other way, no eviction yet
        cpu_load(a2, rdata);          // forces eviction of a0's line (dirty)

        check(bfm.last_release_opcode == RELEASE_DATA, "dirty-evict: victim was dirty, expected RELEASE_DATA");
        check(bfm.read_beat(a0, 0) == 32'hDEAD_BEEF, "dirty-evict: written beat should have been written back");
        check(bfm.read_beat(a0, 1) == bfm.default_fill(a0, 1), "dirty-evict: untouched beat 1 should be unchanged");
    endtask

    // probe a resident clean line down to N: expect a plain PROBE_ACK
    // (no data, since it was never dirty) and the perm actually dropping
    task automatic test_probe_clean();
        automatic logic [ADDR_WIDTH-1:0] a = mk_addr(9'h001, 3'd0); // filled by test_load_miss_fill, still PERM_B
        automatic logic [PARAM_WIDTH-1:0] resp_param;
        automatic logic resp_has_data;
        automatic logic [DATA_WIDTH-1:0] resp_data [BEATS];

        bfm.send_probe(PROBE_BLOCK, TO_N, a, resp_param, resp_has_data, resp_data);
        check(!resp_has_data, "probe-clean: clean line should ack without data");
        check(resp_param == B_TO_N, "probe-clean: expected B_TO_N shrink report");
        check(dut.perms2[{3'd0, dut.probe_way}] == PERM_N, "probe-clean: perm should now be N");
    endtask

    // probe a resident dirty line: expect PROBE_ACK_DATA carrying the
    // current line content, and dirty cleared afterward
    task automatic test_probe_dirty();
        automatic logic [ADDR_WIDTH-1:0] a = mk_addr(9'h030, 3'd5);
        automatic logic [PARAM_WIDTH-1:0] resp_param;
        automatic logic resp_has_data;
        automatic logic [DATA_WIDTH-1:0] resp_data [BEATS];

        cpu_store(a, 32'hABCD_1234); // true miss, dirties beat 0

        bfm.send_probe(PROBE_BLOCK, TO_N, a, resp_param, resp_has_data, resp_data);
        check(resp_has_data, "probe-dirty: dirty line should ack with data");
        check(resp_data[0] == 32'hABCD_1234, "probe-dirty: probe ack data should match what was stored");
        check(dut.dirty2[{3'd5, dut.probe_way}] == 1'b0, "probe-dirty: dirty should be cleared after probe-with-data");
        check(dut.perms2[{3'd5, dut.probe_way}] == PERM_N, "probe-dirty: perm should now be N");
    endtask

    // race: fill both ways of a set so the next distinct-tag access forces
    // an EVICT, and while that miss is in flight, probe a completely
    // unrelated resident line. Channel C is arbitrated (probe wins), so
    // both transactions must still complete correctly and independently
    task automatic test_probe_during_evict();
        automatic logic [ADDR_WIDTH-1:0] probe_target = mk_addr(9'h040, 3'd6);
        automatic logic [ADDR_WIDTH-1:0] f0 = mk_addr(9'h050, 3'd7);
        automatic logic [ADDR_WIDTH-1:0] f1 = mk_addr(9'h051, 3'd7);
        automatic logic [ADDR_WIDTH-1:0] f2 = mk_addr(9'h052, 3'd7); // forces the eviction race
        automatic logic [DATA_WIDTH-1:0] rdata;
        automatic logic [PARAM_WIDTH-1:0] resp_param;
        automatic logic resp_has_data;
        automatic logic [DATA_WIDTH-1:0] resp_data [BEATS];

        cpu_load(probe_target, rdata); // an unrelated resident line, set 6
        cpu_load(f0, rdata);           // set 7, way rr[7]=0
        cpu_load(f1, rdata);           // set 7, way rr[7]=1, both ways now full

        fork
            begin
                cpu_load(f2, rdata); // set 7: forces EVICT/RELEASE_WAIT/REQUEST/WAIT/ACK
            end
            begin
                // synchronize to the moment the miss FSM actually enters EVICT,
                // then fire an unrelated probe so it lands mid-eviction
                wait (dut.miss_state == dut.EVICT);
                bfm.send_probe(PROBE_PERM, TO_N, probe_target, resp_param, resp_has_data, resp_data);
            end
        join

        check(rdata == bfm.default_fill(f2, 0), "probe-during-evict: the miss that raced the probe should still complete correctly");
        check(!resp_has_data, "probe-during-evict: ProbePerm never carries data");
        check(dut.perms2[{3'd6, dut.probe_way}] == PERM_N, "probe-during-evict: the probed line should still end up at N");
        check(bfm.last_release_opcode == RELEASE, "probe-during-evict: the set-7 eviction victim was clean");
    endtask

    // ------------------------------------------------------------------
    // backpressure: same load-miss-fill flow, but with the BFM randomly
    // stalling ready/valid on every channel it drives
    // ------------------------------------------------------------------
    task automatic test_backpressure();
        automatic logic [ADDR_WIDTH-1:0] a = mk_addr(9'h060, 3'd0);
        automatic logic [DATA_WIDTH-1:0] rdata;
        bfm.set_delays(3, 3);
        cpu_store(a, 32'h5555_AAAA);
        check(dut.perms2[{3'd0, dut.saved_way}] == PERM_T, "backpressure: perm should still end up T");
        cpu_load(a, rdata);
        check(rdata == 32'h5555_AAAA, "backpressure: readback under backpressure should still be correct");
        bfm.set_delays(0, 0);
    endtask

    // ------------------------------------------------------------------
    // non-blocking behavior
    // ------------------------------------------------------------------

    // hit-under-miss: start a miss, then hit a resident line (different set,
    // so the miss can't be evicting it). The hits must come back while the
    // miss is still outstanding, without issuing any extra Acquire
    task automatic test_hit_under_miss();
        automatic logic [ADDR_WIDTH-1:0] h = mk_addr(9'h100, 3'd1); // made resident first
        automatic logic [ADDR_WIDTH-1:0] m = mk_addr(9'h101, 3'd2); // the outstanding miss
        automatic logic [CPU_ID_WIDTH-1:0] id_m, id_h0, id_h1;
        automatic logic [DATA_WIDTH-1:0] rdata;
        automatic int acq_before;

        cpu_load(h, rdata);
        resp_order.delete();
        acq_before = bfm.acquire_count;

        cpu_issue(1'b0, m, '0, id_m);
        cpu_issue(1'b0, h, '0, id_h0);
        cpu_issue(1'b0, h + 16'd4, '0, id_h1); // beat 1 of the same resident line
        cpu_idle();

        cpu_wait(id_h1, rdata);
        check(rdata == bfm.default_fill(h, 1), "hit-under-miss: beat-1 hit data mismatch");
        check(!resp_seen[id_m], "hit-under-miss: hits should complete while the miss is still outstanding");
        check(dut.miss_state != dut.IDLE, "hit-under-miss: MSHR should still be busy when the hits return");
        cpu_wait(id_h0, rdata);
        check(rdata == bfm.default_fill(h, 0), "hit-under-miss: beat-0 hit data mismatch");
        cpu_wait(id_m, rdata);
        check(rdata == bfm.default_fill(m, 0), "hit-under-miss: miss data mismatch");
        check(resp_pos(id_h0) < resp_pos(id_m) && resp_pos(id_h1) < resp_pos(id_m),
              "hit-under-miss: both hits should be answered before the miss");
        check(bfm.acquire_count == acq_before + 1, "hit-under-miss: only the miss should have issued an Acquire");
    endtask

    // miss-under-miss + same-line merge: a store miss, a load to the same
    // (still missing) line, a miss to an unrelated line, then a hit. The
    // same-line load must wait behind the store and see its data without
    // a second Acquire; the unrelated miss is latched until the MSHR frees;
    // the hit bypasses everything
    task automatic test_miss_under_miss_merge();
        automatic logic [ADDR_WIDTH-1:0] a = mk_addr(9'h110, 3'd5);
        automatic logic [ADDR_WIDTH-1:0] b = mk_addr(9'h111, 3'd6);
        automatic logic [ADDR_WIDTH-1:0] h = mk_addr(9'h100, 3'd1); // still resident from test_hit_under_miss
        automatic logic [CPU_ID_WIDTH-1:0] id_st, id_ld, id_b, id_h;
        automatic logic [DATA_WIDTH-1:0] rdata;
        automatic int acq_before;

        resp_order.delete();
        acq_before = bfm.acquire_count;

        cpu_issue(1'b1, a, 32'hFEED_0001, id_st);
        cpu_issue(1'b0, a, '0, id_ld);
        cpu_issue(1'b0, b, '0, id_b);
        cpu_issue(1'b0, h, '0, id_h);
        cpu_idle();

        cpu_wait(id_st, rdata);
        cpu_wait(id_ld, rdata);
        check(rdata == 32'hFEED_0001, "merge: load after a store to the same missing line must see the store");
        cpu_wait(id_b, rdata);
        check(rdata == bfm.default_fill(b, 0), "merge: queued second miss data mismatch");
        cpu_wait(id_h, rdata);
        check(rdata == bfm.default_fill(h, 0), "merge: bypassing hit data mismatch");

        check(resp_pos(id_h) < resp_pos(id_st), "merge: the hit should bypass the outstanding miss");
        check(resp_pos(id_st) < resp_pos(id_ld), "merge: same-line requests must complete in program order");
        check(resp_pos(id_ld) < resp_pos(id_b), "merge: the queued miss should only start after the first one finished");
        check(bfm.acquire_count == acq_before + 2, "merge: the same-line load should not have issued its own Acquire");
    endtask

    // more outstanding misses than the request buffer holds: stall must
    // push back on the CPU, nothing may be dropped, and misses (which all
    // funnel through the one MSHR) complete in the order they were issued
    task automatic test_buffer_full_stall();
        localparam int N = 6;
        automatic logic [ADDR_WIDTH-1:0]   addrs [N];
        automatic logic [CPU_ID_WIDTH-1:0] ids   [N];
        automatic logic [DATA_WIDTH-1:0]   rdata;

        resp_order.delete();
        saw_stall = 1'b0;
        bfm.set_delays(2, 2); // stretch each miss so the buffer actually fills

        for (int i = 0; i < N; i++) begin
            addrs[i] = mk_addr(9'h130 + 9'(i), 3'(i));
            cpu_issue(1'b0, addrs[i], '0, ids[i]);
        end
        cpu_idle();

        for (int i = 0; i < N; i++) begin
            cpu_wait(ids[i], rdata);
            check(rdata == bfm.default_fill(addrs[i], 0), $sformatf("buffer-full: miss %0d data mismatch", i));
            if (i > 0) check(resp_pos(ids[i-1]) < resp_pos(ids[i]), $sformatf("buffer-full: miss %0d completed out of order", i));
        end
        check(saw_stall, "buffer-full: stall should assert once the request buffer is full");
        bfm.set_delays(0, 0);
    endtask

    // a store to the line that the in-flight miss is evicting. Without the
    // victim-line conflict check it would hit the old copy mid-ReleaseData
    // and then be overwritten by the fill, i.e. silently lost
    task automatic test_store_to_victim_during_evict();
        automatic logic [ADDR_WIDTH-1:0] x = mk_addr(9'h120, 3'd3); // becomes the victim
        automatic logic [ADDR_WIDTH-1:0] z = mk_addr(9'h121, 3'd3);
        automatic logic [ADDR_WIDTH-1:0] y = mk_addr(9'h122, 3'd3); // evicts x
        automatic logic [CPU_ID_WIDTH-1:0] id_y, id_x;
        automatic logic [DATA_WIDTH-1:0] rdata;

        cpu_store(x, 32'h1111_1111); // fills way rr[3], pointer flips
        cpu_store(z, 32'h2222_2222); // fills the other way, pointer back on x's way
        resp_order.delete();

        cpu_issue(1'b0, y, '0, id_y);
        cpu_issue(1'b1, x, 32'h3333_3333, id_x);
        cpu_idle();

        cpu_wait(id_y, rdata);
        check(rdata == bfm.default_fill(y, 0), "victim-store: evicting miss data mismatch");
        cpu_wait(id_x, rdata);
        check(resp_pos(id_y) < resp_pos(id_x), "victim-store: store to the victim must wait for the eviction");
        check(bfm.read_beat(x, 0) == 32'h1111_1111, "victim-store: eviction should write back x's pre-store contents");
        cpu_load(x, rdata);
        check(rdata == 32'h3333_3333, "victim-store: the store to the victim line was lost");
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    initial begin
        do_reset();
        test_reset();
        test_load_miss_fill();
        test_store_miss_and_readback();
        test_b_to_t_upgrade();
        test_second_way_fill_and_hit();
        test_clean_evict();
        test_dirty_evict_writeback();
        test_probe_clean();
        test_probe_dirty();
        test_probe_during_evict();
        test_backpressure();
        test_hit_under_miss();
        test_miss_under_miss_merge();
        test_buffer_full_stall();
        test_store_to_victim_during_evict();

        if (errors == 0) $display("TB_L1D_2: ALL TESTS PASSED");
        else              $display("TB_L1D_2: %0d CHECK(S) FAILED", errors);
        $finish;
    end

    // safety net so a stuck DUT/BFM doesn't hang the simulation forever
    initial begin
        #200000;
        $error("TB_L1D_2: TIMEOUT -- simulation did not finish");
        $finish;
    end

endmodule
