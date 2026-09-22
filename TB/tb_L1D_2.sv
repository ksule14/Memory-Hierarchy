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
    // CPU-side driver
    // ------------------------------------------------------------------
    task automatic cpu_op(input logic op, input logic [ADDR_WIDTH-1:0] a,
                           input logic [DATA_WIDTH-1:0] wdata, output logic [DATA_WIDTH-1:0] rdata);
        ins.opcode  <= op;
        ins.addr    <= a;
        ins.st_data <= wdata;
        @(posedge clk);
        while (outs.stall) @(posedge clk);
        rdata = outs.rdata;
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
        ins = '{opcode: 1'b0, addr: '0, st_data: '0};
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
    int errors = 0;
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
        check(outs.stall === 1'b1, "reset: outs.stall should be high (nothing valid yet)");
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
