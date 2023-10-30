`default_nettype none

module Counter #( parameter PERIOD_BITS = 8, parameter LOG2_STEP = 0 ) (
		input wire clk,
		input wire reset,
		input wire [PERIOD_BITS-1:0] period0,
		input wire [PERIOD_BITS-1:0] period1,
		input wire enable,
		output wire trigger
	);

	reg [PERIOD_BITS-1:0] counter;
	wire [PERIOD_BITS-1:0] delta_counter;
	assign trigger = enable & !(|counter[PERIOD_BITS-1:LOG2_STEP]); // Trigger if decreasing by 1 << LOG2_STEP would wrap around.
	assign delta_counter = (trigger ? period1 : period0) - (1 << LOG2_STEP);

	always @(posedge clk) begin
		if (reset) begin
			counter <= 0;
		end else if (enable) begin
			counter <= counter + delta_counter;
		end
	end
endmodule

module tt_um_toivoh_test #(
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

	localparam EXTRA_BITS = LEAST_SHR + (1 << OCT_BITS) - 1;
	localparam FEED_SHL = (1 << OCT_BITS) - 1;
	localparam STATE_BITS = WAVE_BITS + EXTRA_BITS;
	localparam SHIFTER_BITS = WAVE_BITS + (1 << OCT_BITS) - 1;

	wire reset = 0;//!rst_n;

	reg [1:0] state;
	wire counter_en = ena && (state == 0);

	// Configuration input
	assign uio_oe = 0; assign uio_out = 0; // Let the bidirectional signals be inputs
	wire [7:0] cfg_in = uio_in;
	reg [47:0] cfg;
	wire [7:0] cfg_in_en = ui_in;


	// Octave divider
	reg [DIVIDER_BITS-1:0] oct_counter;
	wire [DIVIDER_BITS-1:0] next_oct_counter = oct_counter + 1;
	wire [DIVIDER_BITS:0] oct_enables;
	assign oct_enables[0] = 1;
	assign oct_enables[DIVIDER_BITS:1] = next_oct_counter & ~oct_counter; // Could optimize oct_enables[1] to just next_oct_counter[0]


	// Sawtooth
	wire [PERIOD_BITS-1:0] saw_period = {1'b1, cfg[PERIOD_BITS-2:0]};
	wire [OCT_BITS-1:0] oct = cfg[PERIOD_BITS-2+OCT_BITS -: OCT_BITS];
	wire saw_en = oct_enables[oct];
	wire saw_trigger;
	Counter #(.PERIOD_BITS(PERIOD_BITS), .LOG2_STEP(WAVE_BITS)) saw_counter(
		.clk(clk), .reset(reset), .period0({PERIOD_BITS{1'b0}}), .period1(saw_period), .enable(saw_en & counter_en),
		.trigger(saw_trigger)
	);
	reg [WAVE_BITS-1:0] saw;

	// Osc and damp counters
	wire [PERIOD_BITS:0] osc_period  = {2'b01, cfg[16 + PERIOD_BITS-2 -: PERIOD_BITS-1]};
	wire [PERIOD_BITS:0] damp_period = {2'b01, cfg[32 + PERIOD_BITS-2 -: PERIOD_BITS-1]};
	wire [OCT_BITS-1:0] osc_oct  = cfg[16 + PERIOD_BITS-2+OCT_BITS -: OCT_BITS];
	wire [OCT_BITS-1:0] damp_oct = cfg[32 + PERIOD_BITS-2+OCT_BITS -: OCT_BITS];
	wire osc_trigger, damp_trigger;
	Counter #(.PERIOD_BITS(PERIOD_BITS+1), .LOG2_STEP(PERIOD_BITS)) osc_counter(
		.clk(clk), .reset(reset), .period0(osc_period), .period1(osc_period << 1), .enable(counter_en),
		.trigger(osc_trigger)
	);
	Counter #(.PERIOD_BITS(PERIOD_BITS+1), .LOG2_STEP(PERIOD_BITS)) damp_counter(
		.clk(clk), .reset(reset), .period0(damp_period), .period1(damp_period << 1), .enable(counter_en),
		.trigger(damp_trigger)
	);
	reg do_osc, do_damp; // TODO: Could I do without these?

	reg signed [STATE_BITS-1:0] y;
	reg signed [STATE_BITS-1:0] v;

	wire [OCT_BITS-1:0] nf_osc  = osc_oct  + do_osc;
	wire [OCT_BITS-1:0] nf_damp = damp_oct + do_damp;

	reg signed [STATE_BITS-1:0] a_src;
	reg signed [SHIFTER_BITS-1:0] shifter_src;
	reg [OCT_BITS-1:0] nf;
	always @(*) begin
		case (state)
			0, 1, 3: a_src = v;
			2: a_src = y;
		endcase
		case (state)
			1: shifter_src = $signed({saw, {(FEED_SHL-1){1'b0}}});
			2: shifter_src = v >>> LEAST_SHR;
			3: shifter_src = ~(y >>> LEAST_SHR); // cheaper negation
			0: shifter_src = ~(v >>> LEAST_SHR); // cheaper negation
		endcase
		case (state)
			0: nf = nf_damp;
			1, 2, 3: nf = nf_osc;
		endcase
	end

	wire signed [SHIFTER_BITS-1:0] b_src = shifter_src >>> nf;
	wire [STATE_BITS-1:0] next_state = a_src + b_src;

	always @(posedge clk) begin
		if (reset) begin
			state <= 0;
			oct_counter <= 0;
			//cfg <= 0;
			//cfg <= {3'd3, 9'd56};
			cfg[15:0] <= {3'd3, 9'd56};
			cfg[31:16] <= {3'd3, 9'd56};
			cfg[47:32] <= {3'd4, 9'd56};
			//cfg[47:32] <= {3'd6, 9'd56};
			saw <= 0;
			y <= 0;
			v <= 0;
			do_osc <= 0;
			do_damp <= 0;
		end else begin
			if (cfg_in_en[0]) cfg[ 7: 0] <= cfg_in;
			if (cfg_in_en[1]) cfg[15: 8] <= cfg_in;
			if (cfg_in_en[2]) cfg[23:16] <= cfg_in;
			if (cfg_in_en[3]) cfg[31:24] <= cfg_in;
			if (cfg_in_en[4]) cfg[39:32] <= cfg_in;
			if (cfg_in_en[5]) cfg[47:40] <= cfg_in;

			if (state == 0) begin
				oct_counter <= next_oct_counter;
				saw <= saw + saw_trigger;
				do_osc <= osc_trigger;
				do_damp <= damp_trigger;

				//v <= v - ((v >>> LEAST_SHR) >>> nf_damp);
				v <= next_state;
			end else if (state == 1) begin
				//v <= v + ($signed({saw, {(FEED_SHL-1){1'b0}}}) >>> nf_osc);
				v <= next_state;
			end else if (state == 2) begin
				//y <= y + ((v >>> LEAST_SHR) >>> nf_osc);
				y <= next_state;
			end else if (state == 3) begin
				//v <= v - ((y >>> LEAST_SHR) >>> nf_osc);
				v <= next_state;
			end

			state <= state + 1;
		end
	end

	//assign uo_out = saw;
	assign uo_out = y >>> EXTRA_BITS;
endmodule
