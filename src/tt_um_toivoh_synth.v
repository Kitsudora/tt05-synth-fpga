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
		parameter DIVIDER_BITS = 16, // 14 for the pitch, 2 extra for the sweeps
		parameter OSC_PERIOD_BITS = 10,
		parameter MOD_PERIOD_BITS = 6,
		parameter SWEEP_PERIOD_BITS = 4,
		parameter LOG2_SWEEP_UPDATE_PERIOD = 2,
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

	localparam OUT_BITS = 8;

	localparam CEIL_LOG2_NUM_OSCS = 1;
	localparam NUM_OSCS = 2;

	localparam CEIL_LOG2_NUM_MODS = 2;
	localparam NUM_MODS = 3;
	localparam CUTOFF_INDEX = 0;
	localparam DAMP_INDEX = 1;
	localparam VOL_INDEX = 2;

	localparam CEIL_LOG2_NUM_SWEEPS = 3;
	localparam NUM_SWEEPS = NUM_OSCS + NUM_MODS;

	localparam CEIL_LOG2_CFG_WORDS = 3;
	localparam CFG_WORDS = 8;
	localparam OSC_PERIOD_BASE = 0;
	localparam MOD_PERIOD_BASE = NUM_OSCS;
	localparam SWEEP_PERIOD_BASE = MOD_PERIOD_BASE + NUM_MODS;

	localparam EXTRA_BITS = LEAST_SHR + (1 << OCT_BITS) - 1;
	localparam FEED_SHL = (1 << OCT_BITS) - 1;
	localparam FSTATE_BITS = WAVE_BITS + EXTRA_BITS;
	localparam SHIFTER_BITS = WAVE_BITS + (1 << OCT_BITS) - 1;

	localparam STATE_BITS = 3;

	wire reset = !rst_n;

	genvar i;


	// Configuration registers
	// =======================

	wire [1:0] cfg_we; // byte enables
	wire [15:0] cfg_w_data;
	wire [CEIL_LOG2_CFG_WORDS-1:0] cfg_w_addr;
	reg [15:0] cfg[CFG_WORDS];
	wire [15:0] period_cfg[NUM_SWEEPS]; // Restricted to maybe avoid some multiplexers when reading from it
	wire [7:0] cfg8[CFG_WORDS*2];

	generate
		for (i = 0; i < CFG_WORDS; i++) begin
			assign cfg8[2*i  ] = cfg[i][ 7:0];
			assign cfg8[2*i+1] = cfg[i][15:8];
			always @(posedge clk) begin
				if (reset) begin
					cfg[i] <= '1; // Disable all counters by default
				end else if (i == cfg_w_addr) begin
					if (cfg_we[0]) cfg[i][7:0]  <= cfg_w_data[7:0];
					if (cfg_we[1]) cfg[i][15:8] <= cfg_w_data[15:8];
				end
			end
		end
		for (i = 0; i < NUM_OSCS; i++)                 assign period_cfg[i] = cfg[i][OCT_BITS+OSC_PERIOD_BITS-2:0];
		for (i = NUM_OSCS; i < NUM_OSCS+NUM_MODS; i++) assign period_cfg[i] = cfg[i][OCT_BITS+MOD_PERIOD_BITS-2:0];
	endgenerate


	// Configuration input
	// ===================
	assign uio_oe = 0; assign uio_out = 0; // Let the bidirectional signals be inputs
	wire [7:0] cfg_in_data = uio_in;
	wire [CEIL_LOG2_CFG_WORDS-1:0] cfg_in_addr = ui_in[CEIL_LOG2_CFG_WORDS:1];
	wire cfg_in_addr0 = ui_in[0];
	wire cfg_in_strobe_raw = ui_in[7];

	reg [1:0] strobe_sync; // synchronize strobe to clk
	wire cfg_in_strobe = strobe_sync[0];

	wire cfg_override_we;
	wire [15:0] cfg_override_wdata;
	wire [CEIL_LOG2_CFG_WORDS-1:0] cfg_override_w_addr;

	reg cfg_in_prev_strobe;
	always @(posedge clk) begin
		strobe_sync <= {cfg_in_strobe_raw, strobe_sync[1:1]};

		// Don't update cfg_in_prev_strobe if there is a write override, so that we get a new chance to write next cycle.
		if (reset) cfg_in_prev_strobe <= 1'b0;
		else if (!cfg_override_we) cfg_in_prev_strobe <= strobe_sync[0];
	end

	wire cfg_in_strobed = cfg_in_strobe & ~cfg_in_prev_strobe;
	assign cfg_we[0] = (cfg_in_strobed & ~cfg_in_addr0) | cfg_override_we;
	assign cfg_we[1] = (cfg_in_strobed &  cfg_in_addr0) | cfg_override_we;
	assign cfg_w_data = cfg_override_we ? cfg_override_wdata : {cfg_in_data, cfg_in_data};
	assign cfg_w_addr = cfg_override_we ? cfg_override_w_addr : cfg_in_addr;


	// State machine
	// =============
	reg [STATE_BITS-1:0] state;
	wire [STATE_BITS:0] next_state = state + 1;
	wire last_cycle_of_sample = next_state[STATE_BITS];

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
			state <= next_state[STATE_BITS-1:0];
			if (last_cycle_of_sample) oct_counter <= next_oct_counter;
		end
	end


	// Sawtooth oscillators
	// ====================
	wire update_saw = state < NUM_OSCS;
	wire [CEIL_LOG2_NUM_OSCS-1:0] saw_index = state[CEIL_LOG2_NUM_OSCS-1:0];

	wire [OCT_BITS-1:0] curr_saw_oct = saw_oct[saw_index];
	wire [2**OCT_BITS-1:0] saw_oct_enables = {1'b0, oct_enables[2**OCT_BITS-2:0]};
	wire saw_en = saw_oct_enables[curr_saw_oct];
	wire saw_trigger;

	wire [OSC_PERIOD_BITS-1:0] saw_period[NUM_OSCS];
	wire [OCT_BITS-1:0] saw_oct[NUM_OSCS];
	reg [WAVE_BITS-1:0] saw[NUM_OSCS];
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
		for (i = 0; i < NUM_OSCS; i++) begin : osc
			assign saw_period[i] = {1'b1, cfg[OSC_PERIOD_BASE+i][OSC_PERIOD_BITS-2:0]};
			assign saw_oct[i] = cfg[OSC_PERIOD_BASE+i][OSC_PERIOD_BITS-2+OCT_BITS -: OCT_BITS];

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
			assign mod_period[i] = {2'b01, cfg[MOD_PERIOD_BASE+i][MOD_PERIOD_BITS-2 -: MOD_PERIOD_BITS-1]};
			assign mod_oct[i]    = cfg[MOD_PERIOD_BASE+i][MOD_PERIOD_BITS-2+OCT_BITS -: OCT_BITS];
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
						if (mod_counter_state_we) mod_counter_state[i] <= mod_counter_next_state;
					end
				end
			end
		end
	endgenerate


	// Sweep counters
	// ==============
	wire update_sweep = state < NUM_SWEEPS;
	wire [CEIL_LOG2_NUM_SWEEPS-1:0] sweep_index = state[CEIL_LOG2_NUM_SWEEPS-1:0];

	wire [SWEEP_PERIOD_BITS-1:0] sweep_period[NUM_SWEEPS];
	wire [OCT_BITS-1:0] sweep_oct[NUM_SWEEPS];
	wire sweep_down[NUM_SWEEPS];

	wire [OCT_BITS-1:0] curr_sweep_oct = sweep_oct[sweep_index];
	wire [2**OCT_BITS-1:0] sweep_oct_enables = {1'b0, oct_enables[2**OCT_BITS-2+LOG2_SWEEP_UPDATE_PERIOD -: 2**OCT_BITS-1]};
	wire sweep_en = sweep_oct_enables[curr_sweep_oct];
	wire sweep_trigger;

	reg [SWEEP_PERIOD_BITS-1:0] sweep_counter_state[NUM_SWEEPS];
	wire [SWEEP_PERIOD_BITS-1:0] sweep_counter_next_state;
	wire sweep_counter_state_we;

	generate
		for (i = 0; i < NUM_SWEEPS; i++) begin : sweep_counters
			assign sweep_period[i] = {1'b1, cfg8[2*SWEEP_PERIOD_BASE+i][SWEEP_PERIOD_BITS-2 -: SWEEP_PERIOD_BITS-1]};
			assign sweep_oct[i]    = cfg8[2*SWEEP_PERIOD_BASE+i][SWEEP_PERIOD_BITS-2+OCT_BITS -: OCT_BITS];
			assign sweep_down[i]   = cfg8[2*SWEEP_PERIOD_BASE+i][7];
		end
	endgenerate

	wire [SWEEP_PERIOD_BITS-1:0] curr_sweep_period = sweep_period[sweep_index];
	Counter #(.PERIOD_BITS(SWEEP_PERIOD_BITS), .LOG2_STEP(0)) sweep_counter(
		.period0('0), .period1(curr_sweep_period), .enable(sweep_en & update_sweep),
		.trigger(sweep_trigger),

		.counter(sweep_counter_state[sweep_index]), .counter_we(sweep_counter_state_we), .next_counter(sweep_counter_next_state)
	);

	generate
		for (i = 0; i < NUM_SWEEPS; i++) begin : sweep_counter_update
			always @(posedge clk) begin
				if (reset) begin
					sweep_counter_state[i] <= 0; // TODO: way to reset that rhymes better with non-reset-case?
				end else begin
					if (i == sweep_index) begin
						if (sweep_counter_state_we) sweep_counter_state[i] <= sweep_counter_next_state;
					end
				end
			end
		end
	endgenerate

	// Update cfg when a sweep counter triggers
	// ----------------------------------------
	wire sweep_osc = state < NUM_OSCS;
	wire curr_sweep_down = sweep_down[sweep_index];
	wire [OCT_BITS+OSC_PERIOD_BITS-2:0] curr_sweep_cfg = cfg[sweep_index][OCT_BITS+OSC_PERIOD_BITS-2:0];
	wire [OCT_BITS+OSC_PERIOD_BITS-2:0] next_sweep_cfg = curr_sweep_cfg + (curr_sweep_down ? -1 : 1);
	wire sweep_min = curr_sweep_cfg == '0;
	wire sweep_max0 = curr_sweep_cfg[OCT_BITS+MOD_PERIOD_BITS-2:0] == '1;
	wire sweep_max1 = curr_sweep_cfg[OCT_BITS+OSC_PERIOD_BITS-2:OCT_BITS+MOD_PERIOD_BITS-1] == '1;
	wire sweep_max = sweep_max0 & (sweep_max1 | !sweep_osc);
	wire allow_sweep = curr_sweep_down ? !sweep_min : !sweep_max;
	wire do_sweep = sweep_trigger & allow_sweep;

	assign cfg_override_we = do_sweep;
	assign cfg_override_wdata = {{(16-(OCT_BITS+OSC_PERIOD_BITS-1)){1'b0}}, next_sweep_cfg};
	assign cfg_override_w_addr = sweep_index;

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

	reg signed [FSTATE_BITS-1:0] y;
	reg signed [FSTATE_BITS-1:0] v;

	// Not registers, but assigned in the case below:
	reg signed [FSTATE_BITS-1:0] a_src;
	wire a_sign = a_src[FSTATE_BITS-1];
	reg signed [SHIFTER_BITS-1:0] shifter_src;
	reg [CEIL_LOG2_NUM_MODS-1:0] nf_index;
	reg [1:0] filter_target;
	always @(*) begin
		case (state)
			FSTATE_VOL0, FSTATE_VOL1: begin
				filter_target = TARGET_V;
				a_src = v;
				// curr_saw will depend on state[0]
				//shifter_src = {~curr_saw[WAVE_BITS-1], curr_saw[WAVE_BITS-2:0], {(FEED_SHL){1'b0}}};
				shifter_src = {~curr_saw[WAVE_BITS-1], curr_saw[WAVE_BITS-2:0], 1'b1, {(FEED_SHL-1){1'b0}}}; // Center the saw to reduce risk of one sided filter saturation
				nf_index = VOL_INDEX;
			end
			FSTATE_DAMP: begin
				filter_target = TARGET_V;
				a_src = v;
				shifter_src = ~v[FSTATE_BITS-1:LEAST_SHR]; // cheaper negation
				nf_index = DAMP_INDEX;
			end
			FSTATE_CUTOFF_Y: begin
				filter_target = TARGET_Y;
				a_src = y;
				shifter_src = v[FSTATE_BITS-1:LEAST_SHR];
				nf_index = CUTOFF_INDEX;
			end
			FSTATE_CUTOFF_V: begin
				filter_target = TARGET_V;
				a_src = v;
				shifter_src = ~y[FSTATE_BITS-1:LEAST_SHR]; // cheaper negation
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

	wire [OCT_BITS:0] nf0 = mod_oct[nf_index] + (1'b1 ^ do_mod[nf_index]);
	wire [OCT_BITS-1:0] nf = nf0[OCT_BITS] ? '1 : nf0[OCT_BITS-1:0]; // saturate nf

	//wire signed [SHIFTER_BITS-1:0] b_src = shifter_src >>> nf;
	wire signed [FSTATE_BITS-1:0] b_src = shifter_src >>> nf; // use same size of a_src and b_src to avoid lint warning
	wire b_sign = b_src[FSTATE_BITS-1];
	//wire [FSTATE_BITS-1:0] next_filter_state = a_src + b_src;

	// Saturate filter output
	// ----------------------
	wire [FSTATE_BITS-1:0] filter_sum = a_src + b_src;
	wire filter_sum_sign = filter_sum[FSTATE_BITS-1];
	wire filter_max = ~a_sign & ~b_sign &  filter_sum_sign;
	wire filter_min =  a_sign &  b_sign & ~filter_sum_sign;
	wire filter_sat = filter_max | filter_min;
	wire [FSTATE_BITS-1:0] filter_sat_value = {~filter_max, {(FSTATE_BITS-1){filter_max}}};
	wire [FSTATE_BITS-1:0] next_filter_state = filter_sat ? filter_sat_value : filter_sum[FSTATE_BITS-1:0];

	// Filter state update
	// -------------------
	always @(posedge clk) begin
		if (reset) begin
			y <= 0;
			v <= 0;
		end else begin
			if (filter_target == TARGET_Y) y <= next_filter_state;
			if (filter_target == TARGET_V) v <= next_filter_state;
		end
	end

	// PWM
	// ===
	reg [STATE_BITS:0] pwm_counter;

	wire pwm_at_zero = pwm_counter == 0;
	always @(posedge clk) begin
		if (last_cycle_of_sample) pwm_counter <= {1'b0, ~y[FSTATE_BITS-1], y[FSTATE_BITS-2 -: STATE_BITS - 1]};
		else pwm_counter <= pwm_counter - pwm_at_zero;
	end

	// Output
	// ======
	//assign uo_out = saw[0];
	wire [OUT_BITS-1:0] y_out = y[FSTATE_BITS-1 -: OUT_BITS];
	assign uo_out = {~y_out[OUT_BITS-1], y_out[OUT_BITS-2:0]};

	// Debug aids
	// ==========
	wire [15:0] cfg0 = cfg[0];
	wire [15:0] cfg1 = cfg[1];
	wire [15:0] cfg2 = cfg[2];
	wire [15:0] cfg3 = cfg[3];
	wire [15:0] cfg4 = cfg[4];
	wire [15:0] cfg5 = cfg[5];
	wire [15:0] cfg6 = cfg[6];
	wire [15:0] cfg7 = cfg[7];

	wire [OCT_BITS-1:0] saw_oct0 = saw_oct[0];
	wire [OCT_BITS-1:0] saw_oct1 = saw_oct[1];

	wire [WAVE_BITS-1:0] saw0 = saw[0];
	wire [WAVE_BITS-1:0] saw1 = saw[1];
endmodule
