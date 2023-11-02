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
		parameter OCT_BITS = 4, // 8 octaves is enough for pitch, but the filters need to be able to sweep lower
		parameter DIVIDER_BITS = 18, // 14 for the pitch, 4 extra for the sweeps
		parameter OSC_PERIOD_BITS = 10,
		parameter MOD_PERIOD_BITS = 6,
		parameter WAVE_BITS = 2,
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

	localparam CEIL_LOG2_NUM_OSCS = 1;
	localparam NUM_OSCS = 2;

	localparam CEIL_LOG2_NUM_MODS = 2;
	localparam NUM_MODS = 3;
	localparam CUTOFF_INDEX = 0;
	localparam DAMP_INDEX = 1;
	localparam VOL_INDEX = 2;

	localparam EXTRA_BITS = LEAST_SHR + (1 << OCT_BITS) - 1;
	localparam FEED_SHL = (1 << OCT_BITS) - 1;
	localparam STATE_BITS = WAVE_BITS + EXTRA_BITS;
	localparam SHIFTER_BITS = WAVE_BITS + (1 << OCT_BITS) - 1;

	wire reset = !rst_n;

	// Configuration input
	assign uio_oe = 0; assign uio_out = 0; // Let the bidirectional signals be inputs
	wire [7:0] cfg_in = uio_in;
	wire [7:0] cfg_in_en = ui_in;


	genvar i;

	reg [2:0] state;
	wire [3:0] next_state = state + 1;

	// Octave divider
	// ==============
	reg [DIVIDER_BITS-1:0] oct_counter;
	wire [DIVIDER_BITS-1:0] next_oct_counter = oct_counter + 1;
	wire [DIVIDER_BITS:0] oct_enables;
	assign oct_enables[0] = 1;
	assign oct_enables[DIVIDER_BITS:1] = next_oct_counter & ~oct_counter; // Could optimize oct_enables[1] to just next_oct_counter[0]

	always @(posedge clk) begin
		if (reset) begin
			state <= 0;
			oct_counter <= 0;
		end else begin
			state <= state + next_state;
			oct_counter <= oct_counter + next_state[3];
		end
	end


	// Sawtooth oscillators
	// ====================
	wire update_saw = state < NUM_OSCS;
	wire [CEIL_LOG2_NUM_OSCS-1:0] saw_index = state[CEIL_LOG2_NUM_OSCS-1:0];

	wire saw_en = oct_enables[saw_oct[saw_index]];
	wire saw_trigger;

	wire [OSC_PERIOD_BITS-1:0] saw_period[NUM_OSCS]; // = {1'b1, cfg[OSC_PERIOD_BITS-2:0]}; // TODO: cfg
	wire [OCT_BITS-1:0] saw_oct[NUM_OSCS]; // = cfg[OSC_PERIOD_BITS-2+OCT_BITS -: OCT_BITS]; // TODO: cfg
	reg [WAVE_BITS-1:0] saw;
	wire [WAVE_BITS-1:0] curr_saw = saw[saw_index];
	wire [WAVE_BITS-1:0] next_saw = curr_saw + saw_trigger;

	reg [OSC_PERIOD_BITS-1:0] saw_counter_state[NUM_OSCS];
	wire [OSC_PERIOD_BITS-1:0] saw_counter_next_state;
	wire saw_counter_state_we;
	Counter #(.PERIOD_BITS(OSC_PERIOD_BITS), .LOG2_STEP(WAVE_BITS)) saw_counter(
		.period0('0), .period1(saw_period[saw_index]), .enable(saw_en),
		.trigger(saw_trigger),

		.counter(saw_counter_state[saw_index]), .counter_we(saw_counter_state_we), .next_counter(saw_counter_next_state)
	);

	generate
		for (i=0; i < NUM_OSCS; i++) begin : osc_update
			always @(posedge clk) begin
				if (reset) begin
					saw_counter_state[i] <= '0;
					saw[i] <= '0;
				end else if (update_saw && saw_index == i) begin
					if (saw_counter_state_we) saw_counter_state[i] <= saw_counter_next_state;
					saw[i] <= next_saw;
				end
			end
		end
	endgenerate


	// Mod counters
	// ============
	wire update_mod = state < NUM_MODS;
	wire [CEIL_LOG2_NUM_MODS-1:0] mod_index = state[CEIL_LOG2_NUM_MODS-1:0];

	wire [MOD_PERIOD_BITS:0] mod_period[NUM_MODS];
	wire [OCT_BITS-1:0] mod_oct[NUM_MODS];

	wire mod_trigger;

	reg [MOD_PERIOD_BITS:0] mod_counter_state[NUM_MODS];
	wire [MOD_PERIOD_BITS:0] mod_counter_next_state;
	wire mod_counter_state_we;

	reg do_mod[NUM_MODS];

	generate
		for (i = 0; i < NUM_MODS; i++) begin : mod_counters
			// TODO: update offset into cfg
			//assign mod_period[i] = {2'b01, cfg[16*(i+1) + MOD_PERIOD_BITS-2 -: MOD_PERIOD_BITS-1]};
			//assign mod_oct[i]    = cfg[16*(i+1) + MOD_PERIOD_BITS-2+OCT_BITS -: OCT_BITS];
		end
	endgenerate

	wire [MOD_PERIOD_BITS:0] curr_mod_period = mod_period[mod_index];
	Counter #(.PERIOD_BITS(MOD_PERIOD_BITS+1), .LOG2_STEP(MOD_PERIOD_BITS)) mod_counter(
		.period0(curr_mod_period), .period1(curr_mod_period << 1), .enable(update_mod),
		.trigger(mod_trigger),

		.counter(mod_counter_state[mod_index]), .counter_we(mod_counter_state_we), .next_counter(mod_counter_next_state)
	);

	generate
		for (i = 0; i < NUM_MODS; i++) begin : mod_counter_update
			always @(posedge clk) begin
				if (reset) begin
					do_mod[i] <= 0;
					mod_counter_state[i] <= 0; // TODO: way to reset that rhymes better with non-reset-case?
				end else begin
					if (i == mod_index) begin
						if (update_mod) do_mod[i] <= mod_trigger;
						if (mod_counter_state_we) mod_counter_state[i] <= mod_counter_next_state[i];
					end
				end
			end
		end
	endgenerate


	// State variable filter
	// =====================
	localparam FSTATE_VOL0 = 0; // FSTATE_VOL0 and FSTATE_VOL1 must differ in the last bit
	localparam FSTATE_VOL1 = 1;
	localparam FSTATE_DAMP = 2;
	localparam FSTATE_CUTOFF_Y = 3;
	localparam FSTATE_CUTOFF_V = 4;

	localparam TARGET_Y = 0;
	localparam TARGET_V = 1;
	localparam TARGET_NONE = 2;

	reg signed [STATE_BITS-1:0] y;
	reg signed [STATE_BITS-1:0] v;

	// Not registers, but assigned in the case below:
	reg signed [STATE_BITS-1:0] a_src;
	reg signed [SHIFTER_BITS-1:0] shifter_src;
	reg [CEIL_LOG2_NUM_MODS-1:0] nf_index;
	reg [1:0] filter_target;
	always @(*) begin
		case (state)
			FSTATE_VOL0, FSTATE_VOL1: begin
				filter_target = TARGET_V;
				a_src = v;
				// curr_saw will depend on state[0]
				//shifter_src = {curr_saw, {(FEED_SHL-1){1'b0}}};
				shifter_src = {~curr_saw[WAVE_BITS-1], curr_saw[WAVE_BITS-2:0], {(FEED_SHL-1){1'b0}}};
				nf_index = VOL_INDEX;
			end
			FSTATE_DAMP: begin
				filter_target = TARGET_V;
				a_src = v;
				shifter_src = ~(v >>> LEAST_SHR); // cheaper negation
				nf_index = DAMP_INDEX;
			end
			FSTATE_CUTOFF_Y: begin
				filter_target = TARGET_Y;
				a_src = y;
				shifter_src = v >>> LEAST_SHR;
				nf_index = CUTOFF_INDEX;
			end
			FSTATE_CUTOFF_V: begin
				filter_target = TARGET_V;
				a_src = v;
				shifter_src = ~(y >>> LEAST_SHR); // cheaper negation
				nf_index = CUTOFF_INDEX;
			end
			default: begin
				filter_target = TARGET_NONE;
				a_src = 'X;
				shifter_src = 'X;
				nf_index = 'X;
			end
		endcase
	end

	// TODO: consider overflow
	wire [OCT_BITS-1:0] nf = mod_oct[nf_index] + ~do_mod[nf_index];

	wire signed [SHIFTER_BITS-1:0] b_src = shifter_src >>> nf;
	wire [STATE_BITS-1:0] next_filter_state = a_src + b_src;

	always @(posedge clk) begin
		if (reset) begin
			y <= 0;
			v <= 0;
		end else begin
			if (filter_target == TARGET_Y) y <= next_filter_state;
			if (filter_target == TARGET_V) v <= next_filter_state;
		end
	end

	//assign uo_out = saw;
	assign uo_out = y >>> EXTRA_BITS;
endmodule
