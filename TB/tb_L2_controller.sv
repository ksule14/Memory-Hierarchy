`timescale 1ns/1ps
// Unit testbench for l2_controller. Simple scripted drivers stand in for
// four L1s on one side and for the L2 on the other, so each property
// (round-robin rotation, sticky grants, burst locking, channel priority,
// source routing) can be provoked on exactly the cycle a test wants.
// Every channel on both sides has a tl_chan_checker, so any valid
// retraction or payload change before ready fails the run.
import tilelink_pkg::*;

module tb_L2_controller;

    localparam int N = 2**SOURCE_WIDTH;

    logic clk = 0;
    logic rst;
    always #5 clk = ~clk;

    // L1 side
    channel_a     l1_a [0:N-1];  logic [N-1:0] l1_a_valid, l1_a_ready;
    channel_b     l1_b [0:N-1];  logic [N-1:0] l1_b_valid, l1_b_ready;
    channel_c     l1_c [0:N-1];  logic [N-1:0] l1_c_valid, l1_c_ready;
    channel_d     l1_d [0:N-1];  logic [N-1:0] l1_d_valid, l1_d_ready;
    channel_e     l1_e [0:N-1];  logic [N-1:0] l1_e_valid, l1_e_ready;

    // L2 side
    channel_a l2_a; logic l2_a_valid, l2_a_ready;
    channel_b l2_b; logic l2_b_valid, l2_b_ready;
    channel_c l2_c; logic l2_c_valid, l2_c_ready;
    channel_d l2_d; logic l2_d_valid, l2_d_ready;
    channel_e l2_e; logic l2_e_valid, l2_e_ready;

    l2_controller #(.N_L1(N)) dut (
        .clk(clk), .rst(rst),
        .l1_a(l1_a), .l1_a_valid(l1_a_valid), .l1_a_ready(l1_a_ready),
        .l1_b(l1_b), .l1_b_valid(l1_b_valid), .l1_b_ready(l1_b_ready),
        .l1_c(l1_c), .l1_c_valid(l1_c_valid), .l1_c_ready(l1_c_ready),
        .l1_d(l1_d), .l1_d_valid(l1_d_valid), .l1_d_ready(l1_d_ready),
        .l1_e(l1_e), .l1_e_valid(l1_e_valid), .l1_e_ready(l1_e_ready),
        .l2_a(l2_a), .l2_a_valid(l2_a_valid), .l2_a_ready(l2_a_ready),
        .l2_b(l2_b), .l2_b_valid(l2_b_valid), .l2_b_ready(l2_b_ready),
        .l2_c(l2_c), .l2_c_valid(l2_c_valid), .l2_c_ready(l2_c_ready),
        .l2_d(l2_d), .l2_d_valid(l2_d_valid), .l2_d_ready(l2_d_ready),
        .l2_e(l2_e), .l2_e_valid(l2_e_valid), .l2_e_ready(l2_e_ready)
    );

    // ------------------------------------------------------------------
    // protocol checkers, both sides of every channel
    // ------------------------------------------------------------------
    chan_a_checker #(.NAME("l2.a")) u_chk_l2_a(.clk(clk), .rst(rst), .valid(l2_a_valid), .ready(l2_a_ready), .data(l2_a));
    chan_b_checker #(.NAME("l2.b")) u_chk_l2_b(.clk(clk), .rst(rst), .valid(l2_b_valid), .ready(l2_b_ready), .data(l2_b));
    chan_c_checker #(.NAME("l2.c")) u_chk_l2_c(.clk(clk), .rst(rst), .valid(l2_c_valid), .ready(l2_c_ready), .data(l2_c));
    chan_d_checker #(.NAME("l2.d")) u_chk_l2_d(.clk(clk), .rst(rst), .valid(l2_d_valid), .ready(l2_d_ready), .data(l2_d));
    chan_e_checker #(.NAME("l2.e")) u_chk_l2_e(.clk(clk), .rst(rst), .valid(l2_e_valid), .ready(l2_e_ready), .data(l2_e));

    for (genvar i = 0; i < N; i++) begin : g_l1_chk
        chan_a_checker #(.NAME($sformatf("l1[%0d].a", i))) u_a(.clk(clk), .rst(rst), .valid(l1_a_valid[i]), .ready(l1_a_ready[i]), .data(l1_a[i]));
        chan_b_checker #(.NAME($sformatf("l1[%0d].b", i))) u_b(.clk(clk), .rst(rst), .valid(l1_b_valid[i]), .ready(l1_b_ready[i]), .data(l1_b[i]));
        chan_c_checker #(.NAME($sformatf("l1[%0d].c", i))) u_c(.clk(clk), .rst(rst), .valid(l1_c_valid[i]), .ready(l1_c_ready[i]), .data(l1_c[i]));
        chan_d_checker #(.NAME($sformatf("l1[%0d].d", i))) u_d(.clk(clk), .rst(rst), .valid(l1_d_valid[i]), .ready(l1_d_ready[i]), .data(l1_d[i]));
        chan_e_checker #(.NAME($sformatf("l1[%0d].e", i))) u_e(.clk(clk), .rst(rst), .valid(l1_e_valid[i]), .ready(l1_e_ready[i]), .data(l1_e[i]));
    end

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
    // monitors: every accepted beat, in order, plus the cycle it fired on
    // ------------------------------------------------------------------
    int cycle = 0;
    always @(posedge clk) cycle++;

    typedef struct { int src; logic [DATA_WIDTH-1:0] data; int cyc; } beat_t;
    beat_t a_log[$], c_log[$], e_log[$];      // as seen by the L2
    beat_t d_log[$], b_log[$];                // as seen by the L1s (src = receiving port)
    bit    stray_d, stray_b;                  // a B/D valid showed up at the wrong port

    int    expect_d_port = -1, expect_b_port = -1;

    always @(posedge clk) if (!rst) begin
        if (l2_a_valid && l2_a_ready) a_log.push_back('{l2_a.source, l2_a.data, cycle});
        if (l2_c_valid && l2_c_ready) c_log.push_back('{l2_c.source, l2_c.data, cycle});
        if (l2_e_valid && l2_e_ready) e_log.push_back('{l2_e.sink, '0, cycle});
        for (int i = 0; i < N; i++) begin
            if (l1_d_valid[i] && l1_d_ready[i]) d_log.push_back('{i, l1_d[i].data, cycle});
            if (l1_b_valid[i] && l1_b_ready[i]) b_log.push_back('{i, '0, cycle});
            if (l1_d_valid[i] && (expect_d_port >= 0) && (i != expect_d_port)) stray_d = 1'b1;
            if (l1_b_valid[i] && (expect_b_port >= 0) && (i != expect_b_port)) stray_b = 1'b1;
        end
    end

    function automatic void clear_logs();
        a_log.delete(); c_log.delete(); e_log.delete(); d_log.delete(); b_log.delete();
        stray_d = 1'b0; stray_b = 1'b0;
    endfunction

    // ------------------------------------------------------------------
    // drivers. Each presents at a negedge and returns on the posedge the
    // last beat is accepted, leaving valid up so back-to-back calls from
    // the same port don't bubble. *_idle drops valid.
    // ------------------------------------------------------------------
    task automatic l1_send_a(input int p, input logic [2:0] op, input logic [ADDR_WIDTH-1:0] addr);
        @(negedge clk);
        l1_a[p] = '{opcode: op, param: '0, size: 3'd4, source: p[SOURCE_WIDTH-1:0], addr: addr, mask: '0, data: '0, corrupt: 1'b0};
        l1_a_valid[p] = 1'b1;
        @(posedge clk);
        while (!l1_a_ready[p]) @(posedge clk);
    endtask

    task automatic l1_idle_a(input int p);
        @(negedge clk);
        l1_a_valid[p] = 1'b0;
    endtask

    // nbeats beats, beat b carries {port, tag, b} so order/ownership can be checked
    task automatic l1_send_c(input int p, input logic [2:0] op, input int nbeats, input logic [7:0] tag);
        for (int b = 0; b < nbeats; b++) begin
            @(negedge clk);
            l1_c[p] = '{opcode: op, param: '0, size: 3'd4, source: p[SOURCE_WIDTH-1:0], addr: '0,
                        data: {8'(p), tag, 16'(b)}, corrupt: 1'b0};
            l1_c_valid[p] = 1'b1;
            @(posedge clk);
            while (!l1_c_ready[p]) @(posedge clk);
        end
        @(negedge clk);
        l1_c_valid[p] = 1'b0;
    endtask

    task automatic l1_send_e(input int p);
        @(negedge clk);
        l1_e[p] = '{sink: p[SINK_WIDTH-1:0]}; // sink doubles as "who sent it" for the log
        l1_e_valid[p] = 1'b1;
        @(posedge clk);
        while (!l1_e_ready[p]) @(posedge clk);
        @(negedge clk);
        l1_e_valid[p] = 1'b0;
    endtask

    task automatic l2_send_d(input int dest, input logic [2:0] op, input int nbeats);
        for (int b = 0; b < nbeats; b++) begin
            @(negedge clk);
            l2_d = '{opcode: op, param: '0, size: 3'd4, source: dest[SOURCE_WIDTH-1:0], sink: '0,
                     data: 32'hD000_0000 | b, corrupt: 1'b0, denied: 1'b0};
            l2_d_valid = 1'b1;
            @(posedge clk);
            while (!l2_d_ready) @(posedge clk);
        end
        @(negedge clk);
        l2_d_valid = 1'b0;
    endtask

    task automatic l2_send_b(input int dest);
        @(negedge clk);
        l2_b = '{opcode: PROBE_PERM, param: TO_N, size: 3'd4, source: dest[SOURCE_WIDTH-1:0],
                 addr: '0, mask: '0, data: '0, corrupt: 1'b0};
        l2_b_valid = 1'b1;
        @(posedge clk);
        while (!l2_b_ready) @(posedge clk);
        @(negedge clk);
        l2_b_valid = 1'b0;
    endtask

    task automatic do_reset();
        rst = 1'b1;
        for (int i = 0; i < N; i++) begin
            l1_a[i] = '0; l1_c[i] = '0; l1_e[i] = '0;
        end
        l1_a_valid = '0; l1_c_valid = '0; l1_e_valid = '0;
        l1_b_ready = '1; l1_d_ready = '1; // like the real L1s, which tie these high
        l2_b = '0; l2_b_valid = 1'b0;
        l2_d = '0; l2_d_valid = 1'b0;
        l2_a_ready = 1'b1; l2_c_ready = 1'b1; l2_e_ready = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
    endtask

    // ------------------------------------------------------------------
    // tests
    // ------------------------------------------------------------------

    // all four L1s hold an Acquire up continuously: grants must rotate
    // 0,1,2,3,0,1,2,3,... rather than favoring any one port
    task automatic test_rr_rotation();
        localparam int PER_PORT = 3;
        clear_logs();
        // spawned directly from this task (no wrapping fork), since wait fork
        // only waits on immediate children
        for (int p = 0; p < N; p++) begin
            automatic int pp = p;
            fork
                begin
                    for (int k = 0; k < PER_PORT; k++) l1_send_a(pp, ACQUIRE_BLOCK, 16'(pp * 16'h100 + k * 16));
                    l1_idle_a(pp);
                end
            join_none
        end
        wait fork;
        check(a_log.size() == N * PER_PORT, $sformatf("rr: expected %0d Acquires, saw %0d", N * PER_PORT, a_log.size()));
        foreach (a_log[i])
            check(a_log[i].src == i % N, $sformatf("rr: grant %0d went to port %0d, expected %0d", i, a_log[i].src, i % N));
    endtask

    // with the L2 not ready, the first winner must keep the grant even when
    // a port with higher round-robin priority shows up afterwards
    task automatic test_sticky_grant();
        clear_logs();
        check(dut.u_arb_a.rr_ptr == 0, "sticky: rr_ptr should be back at port 0 after a full rotation");
        l2_a_ready = 1'b0;
        fork
            begin l1_send_a(1, ACQUIRE_BLOCK, 16'h1000); l1_idle_a(1); end
            begin l1_send_a(3, ACQUIRE_BLOCK, 16'h3000); l1_idle_a(3); end
            begin
                repeat (3) @(posedge clk);
                check(l2_a_valid && l2_a.source == 1, "sticky: port 1 should be presented (first valid at/after rr_ptr=0)");
                l1_send_a(0, ACQUIRE_BLOCK, 16'h0000); l1_idle_a(0); // port 0 now has top rr priority
            end
            begin
                repeat (6) @(posedge clk);
                check(l2_a_valid && l2_a.source == 1, "sticky: port 0 must not steal a grant that is already presented");
                @(negedge clk) l2_a_ready = 1'b1;
            end
        join
        check(a_log.size() == 3, "sticky: all three Acquires should get through");
        if (a_log.size() == 3)
            check(a_log[0].src == 1 && a_log[1].src == 3 && a_log[2].src == 0,
                  $sformatf("sticky: order should be 1,3,0 (got %0d,%0d,%0d)", a_log[0].src, a_log[1].src, a_log[2].src));
    endtask

    // two 4-beat ReleaseData bursts plus a single-beat Release racing for C,
    // with the L2 randomly stalling. Beats from different L1s must never
    // interleave, and each burst must arrive in beat order
    //
    // The setup matters: rr_ptr only moves when a message finishes, so a
    // broken lock would usually just re-pick the same owner by accident.
    // Parking rr_ptr on port 1 and then letting port 2 own a burst puts
    // port 1 *ahead* of the owner in round-robin order when it shows up
    // mid-burst, so it would win the very next beat if the lock failed
    task automatic test_c_burst_lock();
        automatic bit stop = 0;
        l1_send_c(0, RELEASE, 1, 8'hA9); // finishes on port 0, so rr_ptr moves to 1
        check(dut.u_arb_c.rr_ptr == 1, "c-burst: setup should leave C's rr_ptr on port 1");
        clear_logs();
        fork
            l1_send_c(2, RELEASE_DATA, BEATS, 8'hA2);
            begin @(posedge clk); l1_send_c(0, RELEASE_DATA, BEATS, 8'hA0); end
            begin repeat (2) @(posedge clk); l1_send_c(1, RELEASE, 1, 8'hA1); end
            begin
                while (!stop) begin
                    @(negedge clk);
                    l2_c_ready = $urandom_range(0, 1);
                end
                l2_c_ready = 1'b1;
            end
            begin wait (c_log.size() == 2*BEATS + 1); stop = 1; end
        join
        // walk the log: once a port starts a burst, the next BEATS-1 beats must be its own
        for (int i = 0; i < c_log.size(); ) begin
            automatic int src = c_log[i].src;
            automatic int n   = (src == 1) ? 1 : BEATS;
            for (int b = 0; b < n; b++) begin
                check(c_log[i+b].src == src, $sformatf("c-burst: beat %0d of port %0d's burst came from port %0d", b, src, c_log[i+b].src));
                check(c_log[i+b].data[15:0] == b, $sformatf("c-burst: port %0d beat %0d out of order", src, b));
            end
            i += n;
        end
    endtask

    // one of every channel becomes pending on the same cycle with every
    // receiver ready. New messages must start strictly in E,D,C,B,A order
    task automatic test_channel_priority();
        clear_logs();
        expect_d_port = 1; expect_b_port = 3;
        fork
            l1_send_e(0);
            l2_send_d(1, GRANT, 1);
            l1_send_c(2, RELEASE, 1, 8'hC0);
            l2_send_b(3);
            begin l1_send_a(1, ACQUIRE_BLOCK, 16'h4440); l1_idle_a(1); end
        join
        check(e_log.size() == 1 && d_log.size() == 1 && c_log.size() == 1 && b_log.size() == 1 && a_log.size() == 1,
              "priority: each channel should carry exactly one message");
        if (e_log.size() && d_log.size() && c_log.size() && b_log.size() && a_log.size()) begin
            check(e_log[0].cyc < d_log[0].cyc, "priority: E should start before D");
            check(d_log[0].cyc < c_log[0].cyc, "priority: D should start before C");
            check(c_log[0].cyc < b_log[0].cyc, "priority: C should start before B");
            check(b_log[0].cyc < a_log[0].cyc, "priority: B should start before A");
        end
        check(!stray_d && !stray_b, "priority: B/D valid leaked to the wrong L1");
        expect_d_port = -1; expect_b_port = -1;
    endtask

    // priority only gates NEW messages: an Acquire already presented to a
    // stalled L2 must stay up (the checkers enforce that) while higher
    // channels keep flowing past it on their own wires
    task automatic test_no_retraction();
        clear_logs();
        l2_a_ready = 1'b0;
        fork
            begin l1_send_a(2, ACQUIRE_PERM, 16'h5550); l1_idle_a(2); end
            begin
                repeat (2) @(posedge clk);
                check(l2_a_valid, "no-retract: Acquire should be presented to the L2");
                fork
                    l1_send_e(3);
                    l1_send_c(0, RELEASE, 1, 8'hC1);
                    l2_send_d(2, RELEASE_ACK, 1);
                join
                check(a_log.size() == 0, "no-retract: Acquire should still be waiting on the L2");
                check(l2_a_valid && l2_a.source == 2, "no-retract: Acquire must still be presented after higher channels went");
                @(negedge clk) l2_a_ready = 1'b1;
            end
        join
        check(e_log.size() == 1 && c_log.size() == 1 && d_log.size() == 1, "no-retract: E/C/D should all complete while A is stalled");
        check(a_log.size() == 1, "no-retract: Acquire should complete once the L2 is ready");
        l2_a_ready = 1'b1;
    endtask

    // GrantData to port 2 with port 2 stalling, then a probe to port 3:
    // only the addressed port may ever see valid, and the burst arrives in order
    task automatic test_routing();
        automatic bit stop = 0;
        clear_logs();
        expect_d_port = 2;
        fork
            l2_send_d(2, GRANT_DATA, BEATS);
            begin
                while (!stop) begin
                    @(negedge clk);
                    l1_d_ready[2] = $urandom_range(0, 1);
                end
                l1_d_ready[2] = 1'b1;
            end
            begin wait (d_log.size() == BEATS); stop = 1; end
        join
        check(d_log.size() == BEATS, "routing: all GrantData beats should arrive");
        foreach (d_log[i]) begin
            check(d_log[i].src == 2, $sformatf("routing: D beat %0d went to port %0d", i, d_log[i].src));
            check(d_log[i].data[15:0] == i, $sformatf("routing: D beat %0d out of order", i));
        end
        check(!stray_d, "routing: D valid leaked to another port");

        expect_b_port = 3;
        l2_send_b(3);
        check(b_log.size() == 1 && b_log[0].src == 3, "routing: probe should reach port 3 only");
        check(!stray_b, "routing: B valid leaked to another port");
        expect_d_port = -1; expect_b_port = -1;
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    initial begin
        do_reset();
        test_rr_rotation();
        test_sticky_grant();
        test_c_burst_lock();
        test_channel_priority();
        test_no_retraction();
        test_routing();
        repeat (3) @(posedge clk);

        if (errors == 0) $display("TB_L2_CONTROLLER: ALL TESTS PASSED");
        else             $display("TB_L2_CONTROLLER: %0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin
        #100000;
        $error("TB_L2_CONTROLLER: TIMEOUT -- simulation did not finish");
        $finish;
    end

endmodule
