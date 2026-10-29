`timescale 1ns/1ps
// Unit testbench for main_memory. A scripted L2-side driver sends whole-line
// Get and PutFullData bursts and a monitor collects every D beat. A
// reference model of the RAM checks read data, and each response is checked
// for opcode, source echo, size, beat count and corrupt/denied. Runs once
// with D always ready and A beats back to back, then again with random
// d_ready stalls and random gaps between PutFullData beats.
import tilelink_pkg::*;

module tb_main_memory;

    localparam int OFFSET_BITS = $clog2(LINE_BYTES);
    localparam int N_LINES     = 2**(ADDR_WIDTH - OFFSET_BITS);

    logic clk = 0;
    logic rst;
    always #5 clk = ~clk;

    channel_a a;  logic a_valid, a_ready;
    channel_d d;  logic d_valid, d_ready;

    main_memory dut (
        .clk(clk), .rst(rst),
        .a_input(a),  .a_valid(a_valid), .a_ready(a_ready),
        .d_output(d), .d_valid(d_valid), .d_ready(d_ready)
    );

    chan_a_checker #(.NAME("mem.a")) u_chk_a(.clk(clk), .rst(rst), .valid(a_valid), .ready(a_ready), .data(a));
    chan_d_checker #(.NAME("mem.d")) u_chk_d(.clk(clk), .rst(rst), .valid(d_valid), .ready(d_ready), .data(d));

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $error("CHECK FAILED: %s", msg);
        end
    endtask

    // reference model, one entry per word ever written. anything else is 0
    logic [DATA_WIDTH-1:0] model [int];
    function automatic logic [DATA_WIDTH-1:0] model_rd(input int word);
        return model.exists(word) ? model[word] : '0;
    endfunction

    // ------------------------------------------------------------------
    // D side: random ready, every accepted beat goes into a queue
    // ------------------------------------------------------------------
    int d_stall_pct = 0;
    channel_d d_q [$];

    always @(negedge clk) d_ready <= rst ? 1'b0 : ($urandom_range(99) >= d_stall_pct);

    always @(posedge clk) if (!rst) begin
        if (d_valid && d_ready) d_q.push_back(d);
        check(!$isunknown(a_ready), "a_ready is X");
        if (d_valid) check(!$isunknown(d), "D payload has X while valid");
    end

    // ------------------------------------------------------------------
    // A side driver
    // ------------------------------------------------------------------
    int a_gap_pct = 0;

    // drive one A beat starting at a negedge and return at the negedge after
    // it's accepted, with a_valid still high so the next beat can follow
    // back to back. the caller drops a_valid when the message is done
    task automatic send_a(input logic [2:0] op, input logic [SOURCE_WIDTH-1:0] src,
                          input logic [ADDR_WIDTH-1:0] addr, input logic [DATA_WIDTH-1:0] data);
        a        = '0;
        a.opcode = op;
        a.size   = SIZE_WIDTH'($clog2(LINE_BYTES));
        a.source = src;
        a.addr   = addr;
        a.data   = data;
        a_valid  = 1'b1;
        do @(posedge clk); while (!a_ready);
        @(negedge clk);
    endtask

    // wait for n D beats, with a cap so a lost response is reported instead of hanging
    task automatic wait_d(input int n, input string what);
        automatic int cyc = 0;
        while ((d_q.size() < n) && (cyc < 2000)) begin
            @(posedge clk);
            cyc++;
        end
        check(d_q.size() >= n, $sformatf("%s: expected %0d D beats, got %0d", what, n, d_q.size()));
    endtask

    task automatic put_line(input logic [SOURCE_WIDTH-1:0] src, input logic [ADDR_WIDTH-1:0] addr,
                            input logic [DATA_WIDTH-1:0] data [BEATS]);
        automatic channel_d rsp;
        automatic string what = $sformatf("Put 0x%04h src %0d", addr, src);
        @(negedge clk);
        for (int b = 0; b < BEATS; b++) begin
            while ((b != 0) && ($urandom_range(99) < a_gap_pct)) begin // legal gap between beats
                a_valid = 1'b0;
                @(negedge clk);
            end
            send_a(PUT_FULL_DATA, src, addr, data[b]);
        end
        a_valid = 1'b0;
        for (int b = 0; b < BEATS; b++) model[(addr >> 2) + b] = data[b];
        wait_d(1, what);
        repeat (6) @(posedge clk); // make sure no stray extra beat follows the AccessAck
        check(d_q.size() == 1, $sformatf("%s: expected exactly 1 AccessAck, got %0d beats", what, d_q.size()));
        if (d_q.size() != 0) begin
            rsp = d_q.pop_front();
            check(rsp.opcode == ACCESS_ACK, $sformatf("%s: opcode %0d, expected AccessAck", what, rsp.opcode));
            check(rsp.source == src, $sformatf("%s: source %0d not echoed", what, rsp.source));
            check(rsp.size == SIZE_WIDTH'($clog2(LINE_BYTES)), $sformatf("%s: size %0d", what, rsp.size));
            check(!rsp.corrupt && !rsp.denied, $sformatf("%s: corrupt/denied set", what));
        end
        d_q.delete();
    endtask

    task automatic get_line(input logic [SOURCE_WIDTH-1:0] src, input logic [ADDR_WIDTH-1:0] addr);
        automatic channel_d rsp;
        automatic string what = $sformatf("Get 0x%04h src %0d", addr, src);
        @(negedge clk);
        send_a(GET, src, addr, '0);
        a_valid = 1'b0;
        wait_d(BEATS, what);
        repeat (6) @(posedge clk);
        check(d_q.size() == BEATS, $sformatf("%s: expected %0d AccessAckData beats, got %0d", what, BEATS, d_q.size()));
        for (int b = 0; (b < BEATS) && (d_q.size() != 0); b++) begin
            rsp = d_q.pop_front();
            check(rsp.opcode == ACCESS_ACK_DATA, $sformatf("%s beat %0d: opcode %0d, expected AccessAckData", what, b, rsp.opcode));
            check(rsp.source == src, $sformatf("%s beat %0d: source %0d not echoed", what, b, rsp.source));
            check(rsp.size == SIZE_WIDTH'($clog2(LINE_BYTES)), $sformatf("%s beat %0d: size %0d", what, b, rsp.size));
            check(!rsp.corrupt && !rsp.denied, $sformatf("%s beat %0d: corrupt/denied set", what, b));
            check(rsp.data == model_rd((addr >> 2) + b),
                  $sformatf("%s beat %0d: data 0x%08h, expected 0x%08h", what, b, rsp.data, model_rd((addr >> 2) + b)));
        end
        d_q.delete();
    endtask

    function automatic logic [ADDR_WIDTH-1:0] line(input int n);
        return ADDR_WIDTH'(n << OFFSET_BITS);
    endfunction

    task automatic put_pattern(input logic [SOURCE_WIDTH-1:0] src, input logic [ADDR_WIDTH-1:0] addr,
                               input logic [15:0] tag);
        automatic logic [DATA_WIDTH-1:0] data [BEATS];
        for (int b = 0; b < BEATS; b++) data[b] = {tag, addr[15:4], 4'(b)};
        put_line(src, addr, data);
    endtask

    initial begin
        rst     = 1'b1;
        a       = '0;
        a_valid = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        for (int pass = 0; pass < 2; pass++) begin
            automatic logic [15:0] tag = 16'hA000 + 16'(pass);
            if (pass == 1) begin
                d_stall_pct = 40;
                a_gap_pct   = 40;
            end

            // never-written lines read back zero, at both ends of the address space
            if (pass == 0) begin
                get_line(0, line(0));
                get_line(1, line(N_LINES - 1));
            end

            // write then read back, different sources, including the first and last line
            put_pattern(0, line(0), tag);
            get_line(0, line(0));
            put_pattern(1, line(N_LINES - 1), tag);
            get_line(2, line(N_LINES - 1));

            // neighbouring lines: a burst must not spill into the next line
            put_pattern(3, line(5), tag);
            put_pattern(2, line(6), tag);
            get_line(1, line(5));
            get_line(3, line(6));
            get_line(0, line(7)); // still untouched

            // overwrite a line and check the old data is gone
            put_pattern(0, line(5), tag ^ 16'h0FFF);
            get_line(0, line(5));

            // random mix of Puts and Gets over a small pool of lines
            for (int i = 0; i < 200; i++) begin
                automatic logic [ADDR_WIDTH-1:0] addr = line($urandom_range(15) * 97 % N_LINES);
                automatic logic [SOURCE_WIDTH-1:0] src = SOURCE_WIDTH'($urandom);
                if ($urandom_range(1)) begin
                    automatic logic [DATA_WIDTH-1:0] data [BEATS];
                    for (int b = 0; b < BEATS; b++) data[b] = $urandom;
                    put_line(src, addr, data);
                end else begin
                    get_line(src, addr);
                end
            end

            d_stall_pct = 0;
            a_gap_pct   = 0;
        end

        // a back-to-back Get right after an AccessAck is accepted
        put_pattern(1, line(42), 16'hC0DE);
        get_line(1, line(42));

        check(dut.state.name() == "IDLE", "memory should be back in IDLE at the end");

        if (errors == 0) $display("TB_MAIN_MEMORY: ALL TESTS PASSED");
        else             $display("TB_MAIN_MEMORY: %0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin
        #2000000;
        $error("TB_MAIN_MEMORY: TIMEOUT -- simulation did not finish");
        $display("  state=%s beat_count=%0d a v/r=%b%b d v/r=%b%b", dut.state.name(), dut.beat_count,
                 a_valid, a_ready, d_valid, d_ready);
        $finish;
    end

endmodule
