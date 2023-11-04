#include <iostream>
#include "hwmodel.h"

int VoiceModel::update(int state) {
	const int EXTRA_BITS = LEAST_SHR + (1 << OCT_BITS) - 1;
	const int FEED_SHL = (1 << OCT_BITS) - 1;
	const int FSTATE_BITS = WAVE_BITS + EXTRA_BITS;
	const int SHIFTER_BITS = WAVE_BITS + (1 << OCT_BITS) - 1;

	const int OCT_ENABLE_MASK = (1 << ((1 << OCT_BITS) - 1)) - 1; // To make highest octave number never trigger

	oct_enables = (((oct_counter + 1) & ~oct_counter) << 1) + 1;

	const int i = state;
	this->state = state;

	// Filter update
	// -------------
	if (state < NUM_FSTATES) {
		int nfs[NUM_MODS];
		for (int j = 0; j < NUM_MODS; j++) {
			nfs[j] = mods[j].get_oct() + 1 - mod_trigger[j];
			if (nfs[j] >= (1 << OCT_BITS)) nfs[j] = (1 << OCT_BITS) - 1;
		}

		int saw_index = state & 1; // Assuming two oscillators
		int saw_signed = saw[saw_index] - (1 << (WAVE_BITS - 1));


		// Waveforms:
		// TODO: fix pulse/square/noise
		int wave;
		int saw_msb = (saw_signed >> (WAVE_BITS - 2)) & 3;

		int wave_sel = (misc_cfg >> (2*saw_index)) & 3;

		if (wave_sel == WF_PULSE) wave = (-1 + 4*(saw_msb == 3)) << (WAVE_BITS - 2);
		else if (wave_sel == WF_SQUARE || wave_sel == WF_NOISE) wave = (-1 + (saw_msb & 2)) << (WAVE_BITS - 1);
		else wave = (saw_signed << 1) + 1;

		//std::cout << "wave_sel = " << wave_sel << std::endl;
		//std::cout << "wave = " << wave << std::endl;


		int saw_signed_shifted = wave << (FEED_SHL - 1);

		switch (state) {
			//case FSTATE_VOL0: case FSTATE_VOL1: v = saturate(v + (saw_signed_shifted >> nfs[VOL_INDEX]), FSTATE_BITS); break;
			//case FSTATE_DAMP: v = saturate(v + ~(v >> (LEAST_SHR + nfs[DAMP_INDEX])), FSTATE_BITS); break;
			//case FSTATE_CUTOFF_Y: y = saturate(y + (v >> (LEAST_SHR + nfs[CUTOFF_INDEX])), FSTATE_BITS); break;
			//case FSTATE_CUTOFF_V: v = saturate(v + ~(y >> (LEAST_SHR + nfs[CUTOFF_INDEX])), FSTATE_BITS); break;
			case FSTATE_VOL0: case FSTATE_VOL1: {
				if (misc_cfg & (1 << (8 - NUM_OSCS + saw_index)))
					v = saturate(v + ((shifter_src = saw_signed_shifted) >> (nf = nfs[VOL_INDEX])), FSTATE_BITS); 
				else
					y = saturate(y + ((shifter_src = saw_signed_shifted) >> (nf = nfs[VOL_INDEX])), FSTATE_BITS); 
			} break;
			case FSTATE_DAMP:                   v = saturate(v + ((shifter_src = ~(v >> LEAST_SHR)) >> (nf = nfs[DAMP_INDEX])), FSTATE_BITS); break;
			case FSTATE_CUTOFF_Y:               y = saturate(y + ((shifter_src = (v >> LEAST_SHR)) >> (nf = nfs[CUTOFF_INDEX])), FSTATE_BITS); break;
			case FSTATE_CUTOFF_V:               v = saturate(v + ((shifter_src = ~(y >> LEAST_SHR)) >> (nf = nfs[CUTOFF_INDEX])), FSTATE_BITS); break;
			default: shifter_src = nf = -1; break;
		}
	}
	else { shifter_src = nf = -1; }

	// Oscillator updates
	// ------------------
	if (i < NUM_OSCS) {
		saw[i] += oscs[i].update(oct_enables & OCT_ENABLE_MASK);
		saw[i] &= (1 << WAVE_BITS) - 1;
		// TODO: hard sync?
	}

	// Mod updates
	// -----------
	if (i < NUM_MODS) {
		mod_trigger[i] = mods[i].update();
	}

	// Sweep updates
	// -------------
	if (i < NUM_SWEEPS) {
		if (sweeps[i].update((oct_enables >> LOG2_SWEEP_UPDATE_PERIOD) & OCT_ENABLE_MASK)) {
			int delta = sweep_down[i] ? -1 : 1;
			CounterModel &c = i < NUM_OSCS ? oscs[i] : mods[i - NUM_OSCS];
			c.float_period = std::min(std::max(c.float_period + delta, 0), (1 << (OCT_BITS + c.PERIOD_BITS - 1)) - 1);
		}
	}

	if (state == NUM_STATES - 1) oct_counter += 1;

	out = ((y + (1 << (FSTATE_BITS - 1))) >> (FSTATE_BITS - OUTPUT_BITS)) & ((1 << OUTPUT_BITS) - 1);
	//out = saw[0] << (OUTPUT_BITS - WAVE_BITS) & ((1 << OUTPUT_BITS) - 1); // TODO: change back to regular output!
	return out;
}
