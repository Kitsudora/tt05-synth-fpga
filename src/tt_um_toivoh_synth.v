`default_nettype none

module tt_um_toivoh_synth #(
		parameter DIVIDER_BITS = 7, parameter OCT_BITS = 3, parameter PERIOD_BITS = 10, parameter WAVE_BITS = 8,
		parameter LEAST_SHR = 3
	) (
		input  wire [7:0] ui_in,    // Dedicated inputs - connected to the input switches
		output wire [7:0] uo_out,   // Dedicated outputs - connected to the 7 segment display
		input  wire [7:0] uio_in,   // IOs: Bidirectional Input path
		output wire [7:0] uio_out,  // IOs: Bidirectional Output path
		output wire [7:0] uio_oe,   // IOs: Bidirectional Enable path (active high: 0=input, 1=output)
		input  wire       ena,      // will go high when the design is enabled
		input  wire       clk,      // clock
		input  wire       rst_n     // reset_n - low to reset
	);

	wire reset = !rst_n;

	assign uio_oe = 0; assign uio_out = 0; // Let the bidirectional signals be inputs
	wire [7:0] cfg_in = uio_in;
	wire [7:0] cfg_in_en = ui_in;

	assign uo_out = 0; // TODO: output signal
endmodule
