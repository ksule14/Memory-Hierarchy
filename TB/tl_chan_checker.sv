// Generic TileLink valid/ready/payload discipline checks, one small module
// per channel type so each can bind its port to the channel's own struct
// type directly (no width/packing gymnastics needed at the instantiation
// site). Used by both tb_L1D_1.sv and tb_L1D_2.sv against every channel.
import tilelink_pkg::*;

module chan_a_checker #(parameter string NAME = "chan_a") (
    input logic     clk,
    input logic     rst,
    input logic     valid,
    input logic     ready,
    input channel_a data
);
    // valid must not be retracted before ready accepts it
    a_valid_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> valid
    ) else $error("%s: valid dropped while waiting for ready", NAME);

    // payload must not change while valid is asserted and not yet accepted
    a_payload_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> $stable(data)
    ) else $error("%s: payload changed while valid && !ready", NAME);

    a_valid_known: assert property (
        @(posedge clk) disable iff (rst) !$isunknown(valid)
    ) else $error("%s: valid is X/Z", NAME);
endmodule

module chan_b_checker #(parameter string NAME = "chan_b") (
    input logic     clk,
    input logic     rst,
    input logic     valid,
    input logic     ready,
    input channel_b data
);
    b_valid_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> valid
    ) else $error("%s: valid dropped while waiting for ready", NAME);

    b_payload_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> $stable(data)
    ) else $error("%s: payload changed while valid && !ready", NAME);

    b_valid_known: assert property (
        @(posedge clk) disable iff (rst) !$isunknown(valid)
    ) else $error("%s: valid is X/Z", NAME);
endmodule

module chan_c_checker #(parameter string NAME = "chan_c") (
    input logic     clk,
    input logic     rst,
    input logic     valid,
    input logic     ready,
    input channel_c data
);
    c_valid_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> valid
    ) else $error("%s: valid dropped while waiting for ready", NAME);

    c_payload_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> $stable(data)
    ) else $error("%s: payload changed while valid && !ready", NAME);

    c_valid_known: assert property (
        @(posedge clk) disable iff (rst) !$isunknown(valid)
    ) else $error("%s: valid is X/Z", NAME);
endmodule

module chan_d_checker #(parameter string NAME = "chan_d") (
    input logic     clk,
    input logic     rst,
    input logic     valid,
    input logic     ready,
    input channel_d data
);
    d_valid_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> valid
    ) else $error("%s: valid dropped while waiting for ready", NAME);

    d_payload_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> $stable(data)
    ) else $error("%s: payload changed while valid && !ready", NAME);

    d_valid_known: assert property (
        @(posedge clk) disable iff (rst) !$isunknown(valid)
    ) else $error("%s: valid is X/Z", NAME);
endmodule

module chan_e_checker #(parameter string NAME = "chan_e") (
    input logic     clk,
    input logic     rst,
    input logic     valid,
    input logic     ready,
    input channel_e data
);
    e_valid_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> valid
    ) else $error("%s: valid dropped while waiting for ready", NAME);

    e_payload_stable: assert property (
        @(posedge clk) disable iff (rst) (valid && !ready) |=> $stable(data)
    ) else $error("%s: payload changed while valid && !ready", NAME);

    e_valid_known: assert property (
        @(posedge clk) disable iff (rst) !$isunknown(valid)
    ) else $error("%s: valid is X/Z", NAME);
endmodule
