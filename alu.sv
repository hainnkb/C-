module alu_handshake #(
    parameter WIDTH = 32
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // Input handshake
    input  logic                 in_valid,
    output logic                 in_ready,
    input  logic [WIDTH-1:0]     a,
    input  logic [WIDTH-1:0]     b,
    input  logic [1:0]           op,

    // Output handshake
    output logic                 out_valid,
    input  logic                 out_ready,
    output logic [WIDTH-1:0]     result
);

    typedef enum logic [1:0] {
        ADD = 2'b00,
        SUB = 2'b01,
        AND_OP = 2'b10,
        OR_OP  = 2'b11
    } op_t;

    logic [WIDTH-1:0] result_reg;
    logic             valid_reg;

    // Ready when output stage free
    assign in_ready = !valid_reg || (out_ready && out_valid);

    // Output assignment
    assign out_valid = valid_reg;
    assign result    = result_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_reg <= '0;
            valid_reg  <= 1'b0;
        end
        else begin
            // Accept new transaction
            if (in_valid && in_ready) begin
                case (op)
                    ADD:    result_reg <= a + b;
                    SUB:    result_reg <= a - b;
                    AND_OP: result_reg <= a & b;
                    OR_OP:  result_reg <= a | b;
                    default: result_reg <= '0;
                endcase
                valid_reg <= 1'b1;
            end
            // Transaction completed
            else if (out_valid && out_ready) begin
                valid_reg <= 1'b0;
            end
        end
    end

endmodule
