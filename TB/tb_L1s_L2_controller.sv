`timescale 1ns/1ps
// Integration testbench: both real L1 data caches talking through
// l2_controller to a single l2_bfm standing in for the L2. Port 1 is
// L1_cache1 and port 2 is L1_cache2 (port index == TileLink source id);
// ports 0 and 3 are tied off. Both CPUs run miss/eviction-heavy traffic
// at the same time, so Acquires, ReleaseData bursts and GrantAcks from the
// two caches race through the arbiters while GrantData/ReleaseAck have to
// be routed back to the right cache. The two caches use disjoint
// addresses, since l2_bfm doesn't model coherence between them.
import tilelink_pkg::*;

module tb_L1s_L2_controller;

    localparam int N = 2**SOURCE_WIDTH;

    logic clk = 0;
    logic rst;
    always #5 clk = ~clk;

    cpu_req_t  ins1, ins2;
    cpu_resp_t outs1, outs2;

    // L1 side of the controller
    channel_a l1_a [0:N-1];  wire [N-1:0] l1_a_valid, l1_a_ready;
    channel_b l1_b [0:N-1];  wire [N-1:0] l1_b_valid, l1_b_ready;
    channel_c l1_c [0:N-1];  wire [N-1:0] l1_c_valid, l1_c_ready;
    channel_d l1_d [0:N-1];  wire [N-1:0] l1_d_valid, l1_d_ready;
    channel_e l1_e [0:N-1];  wire [N-1:0] l1_e_valid, l1_e_ready;

    // L2 side of the controller
    channel_a l2_a; logic l2_a_valid, l2_a_ready;
    channel_b l2_b; logic l2_b_valid, l2_b_ready;
    channel_c l2_c; logic l2_c_valid, l2_c_ready;
    channel_d l2_d; logic l2_d_valid, l2_d_ready;
    channel_e l2_e; logic l2_e_valid, l2_e_ready;

    L1_cache1 u_l1d1 (
        .clk(clk), .rst(rst), .ins(ins1), .outs(outs1),
        .chan_a(l1_a[1]), .chan_a_valid(l1_a_valid[1]), .chan_a_ready(l1_a_ready[1]),
        .chan_b(l1_b[1]), .chan_b_valid(l1_b_valid[1]), .chan_b_ready(l1_b_ready[1]),
        .chan_c(l1_c[1]), .chan_c_valid(l1_c_valid[1]), .chan_c_ready(l1_c_ready[1]),
        .chan_d(l1_d[1]), .chan_d_valid(l1_d_valid[1]), .chan_d_ready(l1_d_ready[1]),
        .chan_e(l1_e[1]), .chan_e_valid(l1_e_valid[1]), .chan_e_ready(l1_e_ready[1])
    );

    L1_cache2 u_l1d2 (
        .clk(clk), .rst(rst), .ins(ins2), .outs(outs2),
        .chan_a(l1_a[2]), .chan_a_valid(l1_a_valid[2]), .chan_a_ready(l1_a_ready[2]),
        .chan_b(l1_b[2]), .chan_b_valid(l1_b_valid[2]), .chan_b_ready(l1_b_ready[2]),
        .chan_c(l1_c[2]), .chan_c_valid(l1_c_valid[2]), .chan_c_ready(l1_c_ready[2]),
        .chan_d(l1_d[2]), .chan_d_valid(l1_d_valid[2]), .chan_d_ready(l1_d_ready[2]),
        .chan_e(l1_e[2]), .chan_e_valid(l1_e_valid[2]), .chan_e_ready(l1_e_ready[2])
    );

    // unused ports 0 and 3: never request, always accept
    for (genvar i = 0; i < N; i += 3) begin : g_tieoff
        assign l1_a[i] = '0; assign l1_a_valid[i] = 1'b0;
        assign l1_c[i] = '0; assign l1_c_valid[i] = 1'b0;
        assign l1_e[i] = '0; assign l1_e_valid[i] = 1'b0;
        assign l1_b_ready[i] = 1'b1;
        assign l1_d_ready[i] = 1'b1;
    end

    l2_controller #(.N_L1(N)) u_ctrl (
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

    l2_bfm #(.CHECK_SOURCE(1'b0)) bfm (
        .clk(clk), .rst(rst),
        .chan_a(l2_a), .chan_a_valid(l2_a_valid), .chan_a_ready(l2_a_ready),
        .chan_b(l2_b), .chan_b_valid(l2_b_valid), .chan_b_ready(l2_b_ready),
        .chan_c(l2_c), .chan_c_valid(l2_c_valid), .chan_c_ready(l2_c_ready),
        .chan_d(l2_d), .chan_d_valid(l2_d_valid), .chan_d_ready(l2_d_ready),
        .chan_e(l2_e), .chan_e_valid(l2_e_valid), .chan_e_ready(l2_e_ready)
    );

    // protocol checkers on the shared L2-side channels
    chan_a_checker #(.NAME("l2.a")) u_chk_a(.clk(clk), .rst(rst), .valid(l2_a_valid), .ready(l2_a_ready), .data(l2_a));
    chan_c_checker #(.NAME("l2.c")) u_chk_c(.clk(clk), .rst(rst), .valid(l2_c_valid), .ready(l2_c_ready), .data(l2_c));
    chan_d_checker #(.NAME("l2.d")) u_chk_d(.clk(clk), .rst(rst), .valid(l2_d_valid), .ready(l2_d_ready), .data(l2_d));
    chan_e_checker #(.NAME("l2.e")) u_chk_e(.clk(clk), .rst(rst), .valid(l2_e_valid), .ready(l2_e_ready), .data(l2_e));

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $error("CHECK FAILED: %s", msg);
        end
    endtask

    // the BFM's own source check is off, so check here that only the two
    // live caches ever reach the L2, and count traffic from each
    int a_from [N], c_from [N];
    always @(posedge clk) if (!rst) begin
        if (l2_a_valid && l2_a_ready) begin
            check(l2_a.source inside {2'd1, 2'd2}, $sformatf("Acquire from unexpected source %0d", l2_a.source));
            a_from[l2_a.source]++;
        end
        if (l2_c_valid && l2_c_ready) c_from[l2_c.source]++;
    end

    // ------------------------------------------------------------------
    // one blocking CPU op per cache (overlap here comes from the two CPUs
    // running at once; the caches' own non-blocking behavior is covered
    // by tb_L1D_1/tb_L1D_2)
    // ------------------------------------------------------------------
    task automatic cpu1_op(input logic op, input logic [ADDR_WIDTH-1:0] a,
                           input logic [DATA_WIDTH-1:0] wdata, output logic [DATA_WIDTH-1:0] rdata);
        @(negedge clk);
        ins1 = '{valid: 1'b1, opcode: op, id: '0, addr: a, st_data: wdata};
        @(posedge clk);
        while (outs1.stall) @(posedge clk);
        @(negedge clk) ins1.valid = 1'b0;
        do @(posedge clk); while (!outs1.valid);
        rdata = outs1.rdata;
    endtask

    task automatic cpu2_op(input logic op, input logic [ADDR_WIDTH-1:0] a,
                           input logic [DATA_WIDTH-1:0] wdata, output logic [DATA_WIDTH-1:0] rdata);
        @(negedge clk);
        ins2 = '{valid: 1'b1, opcode: op, id: '0, addr: a, st_data: wdata};
        @(posedge clk);
        while (outs2.stall) @(posedge clk);
        @(negedge clk) ins2.valid = 1'b0;
        do @(posedge clk); while (!outs2.valid);
        rdata = outs2.rdata;
    endtask

    task automatic cpu_op(input int which, input logic op, input logic [ADDR_WIDTH-1:0] a,
                          input logic [DATA_WIDTH-1:0] wdata, output logic [DATA_WIDTH-1:0] rdata);
        if (which == 1) cpu1_op(op, a, wdata, rdata);
        else            cpu2_op(op, a, wdata, rdata);
    endtask

    function automatic logic [ADDR_WIDTH-1:0] mk_addr(input logic [8:0] tag, input logic [2:0] set);
        mk_addr = {tag, set, 4'h0};
    endfunction

    // per set: store-miss A0 (dirty), load-miss A1, load-miss A2 (evicts the
    // dirty A0 -> 4-beat ReleaseData), then reload A0 (evicts clean A1 ->
    // Release, and A0 must come back with the stored word). Every op is a
    // miss, so each one crosses the controller on A, D, E and usually C
    localparam int SETS_USED = 4;
    task automatic workload(input int which, input int pass);
        automatic logic [8:0] tbase = ((which == 1) ? 9'h0A0 : 9'h0B0) + 9'(pass * 8); // fresh lines every pass
        automatic logic [DATA_WIDTH-1:0] rdata;
        for (int s = 0; s < SETS_USED; s++) begin
            automatic logic [ADDR_WIDTH-1:0] a0 = mk_addr(tbase + 9'd0, 3'(s));
            automatic logic [ADDR_WIDTH-1:0] a1 = mk_addr(tbase + 9'd1, 3'(s));
            automatic logic [ADDR_WIDTH-1:0] a2 = mk_addr(tbase + 9'd2, 3'(s));
            automatic logic [DATA_WIDTH-1:0] wval = {8'(which), 8'(s), 16'hBEEF};

            cpu_op(which, 1'b1, a0, wval, rdata);
            cpu_op(which, 1'b0, a1, '0, rdata);
            check(rdata == bfm.default_fill(a1, 0), $sformatf("cpu%0d set %0d: A1 fill mismatch", which, s));
            cpu_op(which, 1'b0, a2, '0, rdata);
            check(rdata == bfm.default_fill(a2, 0), $sformatf("cpu%0d set %0d: A2 fill mismatch", which, s));
            cpu_op(which, 1'b0, a0, '0, rdata);
            check(rdata == wval, $sformatf("cpu%0d set %0d: A0 should come back with the written-back store", which, s));
        end
    endtask

    initial begin
        rst  = 1'b1;
        ins1 = '{valid: 1'b0, opcode: 1'b0, id: '0, addr: '0, st_data: '0};
        ins2 = '{valid: 1'b0, opcode: 1'b0, id: '0, addr: '0, st_data: '0};
        repeat (3) @(posedge clk);
        rst = 1'b0;

        // first pass with an always-ready BFM, second with random stalls on every BFM channel
        for (int pass = 0; pass < 2; pass++) begin
            if (pass == 1) bfm.set_delays(3, 3);
            fork
                workload(1, pass);
                workload(2, pass);
            join
            bfm.set_delays(0, 0);
        end

        check(a_from[1] == 2 * 4 * SETS_USED, $sformatf("expected %0d Acquires from cache 1, saw %0d", 2*4*SETS_USED, a_from[1]));
        check(a_from[2] == 2 * 4 * SETS_USED, $sformatf("expected %0d Acquires from cache 2, saw %0d", 2*4*SETS_USED, a_from[2]));
        check(c_from[1] > 0 && c_from[2] > 0, "both caches should have sent Releases through the controller");

        if (errors == 0) $display("TB_L1S_L2_CONTROLLER: ALL TESTS PASSED");
        else             $display("TB_L1S_L2_CONTROLLER: %0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin
        #500000;
        $error("TB_L1S_L2_CONTROLLER: TIMEOUT -- simulation did not finish");
        // where everything is stuck, to make a hang diagnosable from the log
        $display("  L1_1: miss_state=%s probe_state=%s rq_count=%0d", u_l1d1.miss_state.name(), u_l1d1.probe_state.name(), u_l1d1.rq_count);
        $display("  L1_2: miss_state=%s probe_state=%s rq_count=%0d", u_l1d2.miss_state.name(), u_l1d2.probe_state.name(), u_l1d2.rq_count);
        $display("  L1-side valid a=%b c=%b e=%b", l1_a_valid, l1_c_valid, l1_e_valid);
        $display("  L2-side a v/r=%b%b c v/r=%b%b d v/r=%b%b e v/r=%b%b", l2_a_valid, l2_a_ready, l2_c_valid, l2_c_ready,
                 l2_d_valid, l2_d_ready, l2_e_valid, l2_e_ready);
        $display("  l2_d opcode=%0d source=%0d   l2_c opcode=%0d source=%0d", l2_d.opcode, l2_d.source, l2_c.opcode, l2_c.source);
        $display("  arb_c busy=%b owner=%0d beat=%0d   route_d busy=%b beat=%0d", u_ctrl.u_arb_c.busy, u_ctrl.u_arb_c.owner,
                 u_ctrl.u_arb_c.beat_count, u_ctrl.u_route_d.busy, u_ctrl.u_route_d.beat_count);
        $display("  acquires from 1/2: %0d/%0d", a_from[1], a_from[2]);
        $finish;
    end

endmodule
