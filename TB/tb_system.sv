`timescale 1ns/1ps
// Full-system testbench: L1_cache1 (port/source 1) and L1_cache2 (port/
// source 2) through l2_controller into the real l2_cache, backed by the real
// main_memory. Ports 0 and 3 are tied off.
//
// Directed part: cold misses to memory, sharing, upgrades, ping-pong
// stores between the two caches, and L2 evictions that write dirty lines
// back to memory and read them again.
//
// Random part: both CPUs run loads and stores at the same time over a small
// pool of lines that all land in two L2 sets, so the L2 keeps evicting,
// back-invalidating and writing back. Each CPU owns two words of every line
// (false sharing keeps the lines moving between caches), so a load of an
// own word must return exactly the last store, and a load of the other
// CPU's word must return a value that CPU stored, never older than one
// already seen.
import tilelink_pkg::*;

module tb_system;

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

    // controller <-> L2
    channel_a l2_a; logic l2_a_valid, l2_a_ready;
    channel_b l2_b; logic l2_b_valid, l2_b_ready;
    channel_c l2_c; logic l2_c_valid, l2_c_ready;
    channel_d l2_d; logic l2_d_valid, l2_d_ready;
    channel_e l2_e; logic l2_e_valid, l2_e_ready;

    // L2 <-> main memory
    channel_a mem_a; logic mem_a_valid, mem_a_ready;
    channel_d mem_d; logic mem_d_valid, mem_d_ready;

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

    l2_cache u_l2 (
        .clk(clk), .rst(rst),
        .a_L1(l2_a), .a_L1_valid(l2_a_valid), .a_L1_ready(l2_a_ready),
        .b_L1(l2_b), .b_L1_valid(l2_b_valid), .b_L1_ready(l2_b_ready),
        .c_L1(l2_c), .c_L1_valid(l2_c_valid), .c_L1_ready(l2_c_ready),
        .d_L1(l2_d), .d_L1_valid(l2_d_valid), .d_L1_ready(l2_d_ready),
        .e_L1(l2_e), .e_L1_valid(l2_e_valid), .e_L1_ready(l2_e_ready),
        .a_mem(mem_a), .a_mem_valid(mem_a_valid), .a_mem_ready(mem_a_ready),
        .d_mem(mem_d), .d_mem_valid(mem_d_valid), .d_mem_ready(mem_d_ready)
    );

    main_memory u_mem (
        .clk(clk), .rst(rst),
        .a_input(mem_a),  .a_valid(mem_a_valid), .a_ready(mem_a_ready),
        .d_output(mem_d), .d_valid(mem_d_valid), .d_ready(mem_d_ready)
    );

    // protocol checkers on every shared channel
    chan_a_checker #(.NAME("l2.a"))  u_chk_a  (.clk(clk), .rst(rst), .valid(l2_a_valid),  .ready(l2_a_ready),  .data(l2_a));
    chan_b_checker #(.NAME("l2.b"))  u_chk_b  (.clk(clk), .rst(rst), .valid(l2_b_valid),  .ready(l2_b_ready),  .data(l2_b));
    chan_c_checker #(.NAME("l2.c"))  u_chk_c  (.clk(clk), .rst(rst), .valid(l2_c_valid),  .ready(l2_c_ready),  .data(l2_c));
    chan_d_checker #(.NAME("l2.d"))  u_chk_d  (.clk(clk), .rst(rst), .valid(l2_d_valid),  .ready(l2_d_ready),  .data(l2_d));
    chan_e_checker #(.NAME("l2.e"))  u_chk_e  (.clk(clk), .rst(rst), .valid(l2_e_valid),  .ready(l2_e_ready),  .data(l2_e));
    chan_a_checker #(.NAME("mem.a")) u_chk_ma (.clk(clk), .rst(rst), .valid(mem_a_valid), .ready(mem_a_ready), .data(mem_a));
    chan_d_checker #(.NAME("mem.d")) u_chk_md (.clk(clk), .rst(rst), .valid(mem_d_valid), .ready(mem_d_ready), .data(mem_d));

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $error("CHECK FAILED: %s", msg);
        end
    endtask

    // memory traffic counters, to confirm the directed eviction tests really
    // reached memory
    int n_get = 0, n_put = 0;
    always @(posedge clk) if (!rst) begin
        if (mem_a_valid && mem_a_ready && (mem_a.opcode == GET)) n_get++;
        if (mem_a_valid && mem_a_ready && (mem_a.opcode == PUT_FULL_DATA)) n_put++; // counts beats
        if (mem_d_valid) check(!$isunknown(mem_d), "memory D payload has X while valid");
    end

    // ------------------------------------------------------------------
    // one blocking CPU op per cache, same as tb_L1s_L2_controller
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

    task automatic store(input int which, input logic [ADDR_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] v);
        automatic logic [DATA_WIDTH-1:0] unused;
        cpu_op(which, 1'b1, a, v, unused);
    endtask

    task automatic load_check(input int which, input logic [ADDR_WIDTH-1:0] a,
                              input logic [DATA_WIDTH-1:0] expected, input string what);
        automatic logic [DATA_WIDTH-1:0] rdata;
        cpu_op(which, 1'b0, a, '0, rdata);
        check(rdata === expected, $sformatf("%s: cpu%0d load 0x%04h = 0x%08h, expected 0x%08h",
                                            what, which, a, rdata, expected));
    endtask

    // {L2 tag, L2 set, word, byte}. the L1 set is the low 3 bits of the L2 set
    function automatic logic [ADDR_WIDTH-1:0] mk_addr(input int tag, input int l2set, input int word);
        return {7'(tag), 5'(l2set), 2'(word), 2'b00};
    endfunction

    // ------------------------------------------------------------------
    // directed tests
    // ------------------------------------------------------------------
    task automatic directed();
        automatic logic [ADDR_WIDTH-1:0] x = mk_addr(7'h11, 3, 1);
        automatic int puts_before;

        // cold miss all the way to memory: never written, so zero
        load_check(1, x, '0, "cold miss");
        load_check(2, x, '0, "cold miss, second sharer");

        // store from a sharer (upgrade), other cache reads it via probe
        store(1, x, 32'h1111_0001);
        load_check(2, x, 32'h1111_0001, "read after remote store");
        store(2, x, 32'h2222_0002);
        load_check(1, x, 32'h2222_0002, "read after remote upgrade");

        // ping-pong stores between the caches
        for (int i = 0; i < 8; i++) begin
            automatic int w = (i % 2) ? 2 : 1;
            automatic int r = (i % 2) ? 1 : 2;
            automatic logic [DATA_WIDTH-1:0] v = {8'(w), 8'hAB, 16'(i)};
            store(w, x, v);
            load_check(r, x, v, $sformatf("ping-pong %0d", i));
            load_check(w, x, v, $sformatf("ping-pong %0d, writer", i));
        end

        // L2 evictions: four lines in the same L2 set (2 ways), all dirty in
        // L1s, so every new one back-invalidates an old one and the dirty
        // data has to go through memory and come back
        puts_before = n_put;
        for (int t = 0; t < 4; t++) begin
            store(1, mk_addr(7'h20 + t, 9, 0), {16'hD1D1, 16'(t)});
            store(2, mk_addr(7'h20 + t, 9, 2), {16'hD2D2, 16'(t)});
        end
        for (int t = 0; t < 4; t++) begin
            load_check(2, mk_addr(7'h20 + t, 9, 0), {16'hD1D1, 16'(t)}, $sformatf("evicted line %0d word 0", t));
            load_check(1, mk_addr(7'h20 + t, 9, 2), {16'hD2D2, 16'(t)}, $sformatf("evicted line %0d word 2", t));
            load_check(1, mk_addr(7'h20 + t, 9, 1), '0, $sformatf("evicted line %0d word 1", t));
        end
        check(n_put > puts_before, "L2 evictions should have written dirty lines back to memory");
    endtask

    // ------------------------------------------------------------------
    // random concurrent traffic
    // ------------------------------------------------------------------
    localparam int POOL_TAGS = 6;
    localparam int OPS       = 400;
    int pool_sets [2] = '{0, 13};

    // per word: number of stores issued by its owner, and the last value
    // each CPU has seen there. index = {tag, set index, word}
    int unsigned issued [int];
    logic [DATA_WIDTH-1:0] last_seen [3][int];
    logic [DATA_WIDTH-1:0] last_own  [int];

    function automatic int key(input int tag, input int s, input int word);
        return (tag * 2 + s) * 4 + word;
    endfunction

    function automatic int owner(input int word);
        return (word < 2) ? 1 : 2;
    endfunction

    task automatic random_cpu(input int which);
        for (int i = 0; i < OPS; i++) begin
            automatic int tag  = $urandom_range(POOL_TAGS - 1);
            automatic int s    = $urandom_range(1);
            automatic int word = $urandom_range(3);
            automatic int k    = key(tag, s, word);
            automatic logic [ADDR_WIDTH-1:0] a = mk_addr(7'h40 + tag, pool_sets[s], word);
            automatic logic [DATA_WIDTH-1:0] rdata;

            if ((owner(word) == which) && $urandom_range(1)) begin
                // value = {owner, store sequence number}
                automatic logic [DATA_WIDTH-1:0] v;
                issued[k] = (issued.exists(k) ? issued[k] : 0) + 1;
                v = {4'(which), 28'(issued[k])};
                store(which, a, v);
                last_own[k] = v;
            end else begin
                cpu_op(which, 1'b0, a, '0, rdata);
                if (owner(word) == which) begin
                    check(rdata === (last_own.exists(k) ? last_own[k] : '0),
                          $sformatf("random: cpu%0d own word 0x%04h = 0x%08h, expected 0x%08h", which, a, rdata,
                                    last_own.exists(k) ? last_own[k] : '0));
                end else begin
                    automatic logic [DATA_WIDTH-1:0] prev = last_seen[which].exists(k) ? last_seen[which][k] : '0;
                    automatic int unsigned max_seq = issued.exists(k) ? issued[k] : 0;
                    check(!$isunknown(rdata), $sformatf("random: cpu%0d read X at 0x%04h", which, a));
                    check((rdata == '0) || ((rdata[31:28] == 4'(owner(word))) && (rdata[27:0] <= 28'(max_seq))),
                          $sformatf("random: cpu%0d read 0x%08h at 0x%04h, never stored by cpu%0d", which, rdata, a, owner(word)));
                    check(rdata[27:0] >= prev[27:0],
                          $sformatf("random: cpu%0d read 0x%08h at 0x%04h, older than 0x%08h seen before", which, rdata, a, prev));
                    last_seen[which][k] = rdata;
                end
            end
        end
    endtask

    // after both CPUs are done, every word must read back its final value from either cache
    task automatic final_sweep();
        for (int tag = 0; tag < POOL_TAGS; tag++)
            for (int s = 0; s < 2; s++)
                for (int word = 0; word < 4; word++) begin
                    automatic int k = key(tag, s, word);
                    automatic logic [DATA_WIDTH-1:0] v = last_own.exists(k) ? last_own[k] : '0;
                    load_check(1, mk_addr(7'h40 + tag, pool_sets[s], word), v, "final sweep");
                    load_check(2, mk_addr(7'h40 + tag, pool_sets[s], word), v, "final sweep");
                end
    endtask

    initial begin
        rst  = 1'b1;
        ins1 = '{valid: 1'b0, opcode: 1'b0, id: '0, addr: '0, st_data: '0};
        ins2 = '{valid: 1'b0, opcode: 1'b0, id: '0, addr: '0, st_data: '0};
        repeat (3) @(posedge clk);
        rst = 1'b0;

        directed();
        fork
            random_cpu(1);
            random_cpu(2);
        join
        final_sweep();

        check(n_get > 0 && n_put > 0, "memory should have served both Gets and PutFullData");
        $display("memory traffic: %0d Gets, %0d PutFullData beats", n_get, n_put);

        if (errors == 0) $display("TB_SYSTEM: ALL TESTS PASSED");
        else             $display("TB_SYSTEM: %0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin
        #5000000;
        $error("TB_SYSTEM: TIMEOUT -- simulation did not finish");
        $display("  L1_1: miss_state=%s probe_state=%s rq_count=%0d", u_l1d1.miss_state.name(), u_l1d1.probe_state.name(), u_l1d1.rq_count);
        $display("  L1_2: miss_state=%s probe_state=%s rq_count=%0d", u_l1d2.miss_state.name(), u_l1d2.probe_state.name(), u_l1d2.rq_count);
        $display("  L2: state=%s rel_state=%s   mem: state=%s", u_l2.state.name(), u_l2.rel_state.name(), u_mem.state.name());
        $display("  mem a v/r=%b%b d v/r=%b%b", mem_a_valid, mem_a_ready, mem_d_valid, mem_d_ready);
        $finish;
    end

endmodule
