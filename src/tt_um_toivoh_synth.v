`default_nettype none

module Counter #( parameter PERIOD_BITS = 8, LOG2_STEP = 0 ) (
		input wire [PERIOD_BITS-1:0] period0,
		input wire [PERIOD_BITS-1:0] period1,
		input wire enable,
		output wire trigger,

		// External state: Provide current state in counter, update it to next_counter if counter_we is true.
		input wire [PERIOD_BITS-1:0] counter,
		output wire counter_we,
		output wire [PERIOD_BITS-1:0] next_counter
	);

	assign trigger = enable & !(|counter[PERIOD_BITS-1:LOG2_STEP]); // Trigger if decreasing by 1 << LOG2_STEP would wrap around.

	wire [PERIOD_BITS-1:0] delta_counter = (trigger ? period1 : period0) - (1 << LOG2_STEP);
	assign counter_we = enable;
	assign next_counter = counter + delta_counter;
endmodule

module tt_um_toivoh_synth #(
		parameter DIVIDER_BITS = 7, parameter OCT_BITS = 3, parameter OSC_PERIOD_BITS = 10, parameter MOD_PERIOD_BITS = 6, parameter WAVE_BITS = 8,
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

	localparam NUM_MODS = 2;
	localparam CUTOFF_INDEX = 0;
	localparam DAMP_INDEX = 1;

	localparam EXTRA_BITS = LEAST_SHR + (1 << OCT_BITS) - 1;
	localparam FEED_SHL = (1 << OCT_BITS) - 1;
	localparam STATE_BITS = WAVE_BITS + EXTRA_BITS;
	localparam SHIFTER_BITS = WAVE_BITS + (1 << OCT_BITS) - 1;

	wire reset = !rst_n;

	reg [1:0] state;

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
	wire [OSC_PERIOD_BITS-1:0] saw_period = {1'b1, cfg[OSC_PERIOD_BITS-2:0]};
	wire [OCT_BITS-1:0] oct = cfg[OSC_PERIOD_BITS-2+OCT_BITS -: OCT_BITS];
	wire saw_en = oct_enables[oct];
	wire saw_trigger;

	reg [OSC_PERIOD_BITS-1:0] saw_counter_state;
	wire [OSC_PERIOD_BITS-1:0] saw_counter_next_state;
	wire saw_counter_state_we;
	Counter #(.PERIOD_BITS(OSC_PERIOD_BITS), .LOG2_STEP(WAVE_BITS)) saw_counter(
		.period0({OSC_PERIOD_BITS{1'b0}}), .period1(saw_period), .enable(saw_en & counter_en),
		.trigger(saw_trigger),

		.counter(saw_counter_state), .counter_we(saw_counter_state_we), .next_counter(saw_counter_next_state)
	);
	reg [WAVE_BITS-1:0] saw;


	// Mod counters
	wire [MOD_PERIOD_BITS:0] mod_period[NUM_MODS];
	wire [OCT_BITS-1:0] mod_oct[NUM_MODS];

	wire mod_trigger;

	reg [MOD_PERIOD_BITS:0] mod_counter_state[NUM_MODS];
	wire [MOD_PERIOD_BITS:0] mod_counter_next_state;
	wire mod_counter_state_we;

	reg do_mod[NUM_MODS];
	// TODO: consider overflow
	wire [OCT_BITS-1:0] nf_mod[NUM_MODS];

	wire [OCT_BITS-1:0] nf_cutoff = nf_mod[CUTOFF_INDEX];
	wire [OCT_BITS-1:0] nf_damp = nf_mod[DAMP_INDEX];

	generate
		genvar i;
		for (i = 0; i < NUM_MODS; i++) begin : counters
			// TODO: update offset into cfg
			assign mod_period[i] = {2'b01, cfg[16*(i+1) + MOD_PERIOD_BITS-2 -: MOD_PERIOD_BITS-1]};
			assign mod_oct[i]    = cfg[16*(i+1) + MOD_PERIOD_BITS-2+OCT_BITS -: OCT_BITS];

			assign nf_mod[i] = mod_oct[i] + do_mod[i]; // TODO: multiplex?
		end
	endgenerate

	wire mod_index = state;
	wire counter_en = state < NUM_MODS;

	wire [MOD_PERIOD_BITS:0] curr_mod_period = mod_period[mod_index];
	Counter #(.PERIOD_BITS(MOD_PERIOD_BITS+1), .LOG2_STEP(MOD_PERIOD_BITS)) mod_counter(
		.period0(curr_mod_period), .period1(curr_mod_period << 1), .enable(counter_en),
		.trigger(mod_trigger),

		.counter(mod_counter_state[mod_index]), .counter_we(mod_counter_state_we), .next_counter(mod_counter_next_state)
	);


	reg signed [STATE_BITS-1:0] y;
	reg signed [STATE_BITS-1:0] v;

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
			1, 2, 3: nf = nf_cutoff;
		endcase
	end

	wire signed [SHIFTER_BITS-1:0] b_src = shifter_src >>> nf;
	wire [STATE_BITS-1:0] next_state = a_src + b_src;

	always @(posedge clk) begin
		if (reset) begin
			state <= 0;
			oct_counter <= 0;
			cfg[15:0] <= {3'd3, 9'd56};
			
			//cfg[31:16] <= {3'd3, 9'd56}; cfg[47:32] <= {3'd4, 9'd56};
			cfg[31:16] <= {3'd3, 9'd56} >> 4; cfg[47:32] <= {3'd4, 9'd56} >> 4;
			
			saw <= 0;
			y <= 0;
			v <= 0;

			saw_counter_state <= 0;
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

				//v <= v - ((v >>> LEAST_SHR) >>> nf_damp);
				v <= next_state;
			end else if (state == 1) begin
				//v <= v + ($signed({saw, {(FEED_SHL-1){1'b0}}}) >>> nf_cutoff);
				v <= next_state;
			end else if (state == 2) begin
				//y <= y + ((v >>> LEAST_SHR) >>> nf_cutoff);
				y <= next_state;
			end else if (state == 3) begin
				//v <= v - ((y >>> LEAST_SHR) >>> nf_cutoff);
				v <= next_state;
			end

			if (saw_counter_state_we) saw_counter_state <= saw_counter_next_state;

			state <= state + 1;
		end
	end

	generate
		for (i = 0; i < NUM_MODS; i++) begin : counter_update

			always @(posedge clk) begin
				if (reset) begin
					do_mod[i] <= 0;
					mod_counter_state[i] <= 0; // TODO: way to reset that rhymes better with non-reset-case?
				end else begin
					if (i == mod_index) begin
						if (counter_en) do_mod[i] <= mod_trigger;
						if (mod_counter_state_we) mod_counter_state[i] <= mod_counter_next_state[i];
					end
				end
			end

		end
	endgenerate

	//assign uo_out = saw;
	assign uo_out = y >>> EXTRA_BITS;
endmodule
