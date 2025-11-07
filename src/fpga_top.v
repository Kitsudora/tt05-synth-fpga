module fpga_top(
    input wire clk,
    input wire rst_n,

    output wire aud_pwm_o,
    output wire aud_sd_o
);

assign aud_sd_o = 1'b1;

reg [7:0] data_i;
reg [3:0] addr_audio; 
reg storbe_i;
wire [7:0] uio_out;
wire pwm_o;

assign pwm_o = uio_out[6];
assign aud_pwm_o = pwm_o? 1'bz : 1'b0;

tt_um_toivoh_synth  #(
        .OCT_BITS(4), // 8 octaves is enough for pitch, but the filters need to be able to sweep lower
        .DIVIDER_BITS(16+1), // 14 for the pitch, 2 extra for the sweeps
        .OSC_PERIOD_BITS(8),
        .MOD_PERIOD_BITS(5),
        .SWEEP_PERIOD_BITS(4),
        .LOG2_SWEEP_UPDATE_PERIOD(2),
        .WAVE_BITS(2),
        .LEAST_SHR(2)
	)audio_core(
    .ui_in(data_i),    // Dedicated inputs - connected to the input switches
    // .uo_out(),   // Dedicated outputs - connected to the 7 segment display
    .uio_in({storbe_i, 3'b000, addr_audio}),   // IOs: Bidirectional Input path
    .uio_out(uio_out),  // IOs: Bidirectional Output path
    // .uio_oe(),
    .ena(1'b1),      // will go high when the design is enabled
    .clk(clk),      // clock
    .rst_n(rst_n)     // reset_n - low to reset
);

reg [4:0] step;
reg [7:0] counter = 0;

always @(posedge clk) begin
    if (rst_n) begin

        case (step)
            5'd0: begin
                data_i <= 0;
                storbe_i <= 1'b1;
                addr_audio[3:1] <= addr_audio[3:1] + 1;
                addr_audio[0] <= 1'b0;
            end

            5'd1: begin
                storbe_i <= 1'b0;
            end

            5'd11: begin
                data_i <= counter + 1;
                storbe_i <= 1'b1;
                addr_audio[0] <= 1'b1;
            end

            5'd12: begin
                storbe_i <= 1'b0;
            end
        endcase

        if(step == 5'd22) step <= 0;
        else step <= step + 1 ;


    end else begin
        step <= 0;
        data_i <= 0;
        addr_audio <= 0;
        storbe_i <= 0;
    end
end

//------------------------------------------------------
// reg [7:0] addr
// (* ram_style = "distributed" *) reg [7:0] mem [0:255];
// initial $readmemh("init.hex", mem);
 
// always @(posedge clk) begin
//     data_i <= mem[addr];
// end




endmodule