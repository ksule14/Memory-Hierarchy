interface tilelink_a_channel #(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 32,
    parameter SIZE_WIDTH = 3,
    parameter SOURCE_WIDTH = 1
);
    logic [ADDR_WIDTH-1:0]   addr;
    logic [DATA_WIDTH-1:0]   data;
    logic [SIZE_WIDTH-1:0]   size;
    logic [SOURCE_WIDTH-1:0] source;
    logic [DATA_WIDTH/8-1:0] mask;
    logic [2:0]              opcode;
    logic [2:0]              param;
    logic                    valid;
    logic                    ready;
    logic                    corrupt;

    modport master (
        input ready,
        output addr, data, size, source, mask, opcode, param, valid, corrupt
    );

    modport slave (
        input addr, data, size, source, mask, opcode, param, valid, corrutpt,
        output ready
    );
endinterface

interface tilelink_b_channel #(
    parameter ADDR_WIDTH = 16
    parameter DATA_WIDTH = 32,
    parameter SIZE_WIDTH = 3,
    parameter SOURCE_WIDTH = 1
);
    logic [ADDR_WIDTH-1:0]   addr;
    logic [DATA_WIDTH-1:0]   data;
    logic [SIZE_WIDTH-1:0]   size;
    logic [SOURCE_WIDTH-1:0] source;
    logic [DATA_WIDTH/8-1:0] mask;
    logic [2:0]              opcode;
    logic [2:0]              param;
    logic                    valid;
    logic                    ready;
    logic                    corrupt;

    modport master (
        input addr, data, size, source, mask, opcode, param, valid, corrupt,
        output ready 
    );

    modport slave (
        input ready,
        output addr, data, size, source, mask, opcode, param, valid, corrupt
    );

endinterface

interface tilelink_c_channel #(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 32,
    parameter SIZE_WIDTH = 3,
    parameter SOURCE_WIDTH = 1
);
    logic [ADDR_WIDTH-1:0]   addr;
    logic [DATA_WIDTH-1:0]   data;
    logic [SIZE_WIDTH-1:0]   size;
    logic [SOURCE_WIDTH-1:0] source;
    logic [2:0]              opcode;
    logic [2:0]              param;
    logic                    valid;
    logic                    ready;
    logic                    corrupt;

    modport master (
        input ready,
        output addr, data, size, source, opcode, param, valid, corrupt
    );

    modport slave (
        input addr, data, size, source, opcode, param, valid, corrupt,
        output ready
    );
endinterface

interface tilelink_d_channel #(
    parameter SINK_WIDTH = 1,
    parameter DATA_WIDTH = 32,
    parameter SIZE_WIDTH = 3,
    parameter SOURCE_WIDTH = 1
);
    logic [SINK_WIDTH-1:0]   sink;
    logic [DATA_WIDTH-1:0]   data;
    logic [SIZE_WIDTH-1:0]   size;
    logic [SOURCE_WIDTH-1:0] source;
    logic [2:0]              opcode;
    logic [2:0]              param;
    logic                    valid;
    logic                    ready;
    logic                    corrupt;
    logic                    denied;

    modport master (
        input sink, data, size, source, opcode, param, valid, corrupt, denied,
        output ready
    );

    master slave (
        input ready,
        output sink, data, size, source, opcode, param, valid, corrupt, denied
    );
endinterface

interface tilelink_e_channel #(
    parameter SINK_WIDTH = 1
);
    logic [SINK_WIDTH-1:0] sink,
    logic                  valid;
    logic                  ready;

    modport master (
        input ready,
        output sink, valid
    );

    modport slave (
        input sink, valid,
        output ready
    );
endinterface






