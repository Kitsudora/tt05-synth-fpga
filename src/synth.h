#pragma once
#include <cstdint>
#include <algorithm>
#include <string.h>

struct CounterModel {
	int PERIOD_BITS; // Used to decode the period
	int LOG2_STEP;
	bool DOUBLE_STEP;

	int float_period;
	int counter;

	int get_oct() { return float_period >> (PERIOD_BITS - 1); }
	int get_period() { return float_period & ((1 << (PERIOD_BITS - 1)) - 1) | (1 << (PERIOD_BITS - 1)); }

	CounterModel() {};
	void init(int period_bits, int log2_step, bool double_step) { PERIOD_BITS = period_bits; LOG2_STEP = log2_step; DOUBLE_STEP = double_step; }
	void reset() { float_period = counter = 0; }

	bool update() {	
		int period0, period1;
		int period = get_period();
		if (DOUBLE_STEP) { period0 = period; period1 = period << 1; }
		else { period0 = 0; period1 = period; }

		bool trigger = (counter & (-1 << LOG2_STEP)) == 0;
		int delta_counter = (trigger ? period1 : period0) - (1 << LOG2_STEP);
		counter += delta_counter;
		return trigger;
	}

	// Use if the update should be gated
	bool update(int oct_enables) { return ((oct_enables >> get_oct()) & 1) ? update() : false; }

	void set_float_period_norm(int64_t fp, int OCT_BITS) {
		fp >>= (32 - (PERIOD_BITS - 1));
		float_period = std::min(std::max(fp, 0l), (1l << (OCT_BITS + PERIOD_BITS - 1)) - 1);
	}
};

struct VoiceModel {
	enum { NUM_OSCS = 2, NUM_MODS = 3 };
	enum { NUM_SWEEPS = NUM_OSCS + NUM_MODS };
	enum { CUTOFF_INDEX = 0, DAMP_INDEX = 1, VOL_INDEX = 2};

	enum { NUM_STATES = 8 };
	enum { FSTATE_VOL0 = 0, FSTATE_VOL1, FSTATE_DAMP, FSTATE_CUTOFF_Y, FSTATE_CUTOFF_V, NUM_FSTATES };

	int OCT_BITS, WAVE_BITS, LEAST_SHR, OUTPUT_BITS, LOG2_SWEEP_UPDATE_PERIOD;

	int oct_counter;
	int oct_enables;

	CounterModel oscs[NUM_OSCS];
	CounterModel mods[NUM_MODS];
	CounterModel sweeps[NUM_SWEEPS];

	int saw[NUM_OSCS];
	bool mod_trigger[NUM_MODS];
	bool sweep_up[NUM_SWEEPS];

	int y, v;

	int out;
	int state;
	int shifter_src;
	int nf;

	VoiceModel() {}
	void init(int OCT_BITS, int OSC_PERIOD_BITS, int MOD_PERIOD_BITS, int SWEEP_PERIOD_BITS, int WAVE_BITS, int LEAST_SHR, int OUTPUT_BITS, int LOG2_SWEEP_UPDATE_PERIOD, int SWEEP_LOG2_STEP) {
		this->OCT_BITS = OCT_BITS;
		this->WAVE_BITS = WAVE_BITS;
		this->LEAST_SHR = LEAST_SHR;
		this->OUTPUT_BITS = OUTPUT_BITS;
		this->LOG2_SWEEP_UPDATE_PERIOD = LOG2_SWEEP_UPDATE_PERIOD;

		for (int i = 0; i < NUM_OSCS; i++) oscs[i].init(OSC_PERIOD_BITS, WAVE_BITS, false);
		for (int i = 0; i < NUM_MODS; i++) mods[i].init(MOD_PERIOD_BITS, MOD_PERIOD_BITS, true); // Take step that is no larger than twice the smallest period
		for (int i = 0; i < NUM_SWEEPS; i++) sweeps[i].init(SWEEP_PERIOD_BITS, SWEEP_LOG2_STEP, false);
	}
	void reset() {
		oct_counter = oct_enables = 0;
		for (int i = 0; i < NUM_OSCS; i++) oscs[i].reset();
		for (int i = 0; i < NUM_MODS; i++) mods[i].reset();
		for (int i = 0; i < NUM_SWEEPS; i++) sweeps[i].reset();

		memset(&saw, 0, sizeof(saw));
		memset(&mod_trigger, 0, sizeof(mod_trigger));
		memset(&sweep_up, 0, sizeof(sweep_up));

		y = v = 0;

		out = state = shifter_src = nf = -1; // Don't check until after the first update.
	}

	int saturate(int x, int BITS) { return std::max(std::min(x, (1 << (BITS - 1)) - 1), -(1 << (BITS - 1))); }
	//int saturate(int x, int BITS) { return std::max(std::min(x, (1 << (BITS - 1)) - 1), 1 - (1 << (BITS - 1))); }

	int update(int state); // call with state going from 0 to NUM_STATES-1 for each sample.
};
