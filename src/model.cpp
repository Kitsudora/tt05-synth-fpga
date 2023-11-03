#include <vector>
#include <string>
#include <iostream>
#include <fstream>
#include <stdlib.h>

#include "hwmodel.h"

const int OCT_BITS = 4;
const int OSC_PERIOD_BITS = 10;
const int MOD_PERIOD_BITS = 6;
const int SWEEP_PERIOD_BITS = 4;
const int WAVE_BITS = 2;
const int LEAST_SHR = 3;
const int OUTPUT_BITS = 8;

const int LOG2_SWEEP_UPDATE_PERIOD = 2;
const int SWEEP_LOG2_STEP = 0; // <= SWEEP_PERIOD_BITS - 1

const int CFG_WORDS = 8;

const int DIVIDER_BITS = 16;

const int num_cfgs_to_try = 100;
const int num_samples_per_cfg = 100;


typedef std::pair<std::string, int> Pair;
typedef std::vector<Pair> PairVector;

void sample(PairVector &v, const std::string &name, int x) {
	v.push_back(Pair(name, x));
}

void sample_counter(PairVector &v, const std::string &name, CounterModel &c) {
	sample(v, name + ".float_period", c.float_period);
	sample(v, name + ".counter", c.counter);
}

void sample_voice(PairVector &v, VoiceModel &voice) {
	int i;
	sample(v, "out", voice.out);
	sample(v, "state", voice.state);
	sample(v, "oct_counter", voice.oct_counter & ((1 << (DIVIDER_BITS))-1));     // Hack: supress higher bits of oct_counter
	sample(v, "oct_enables", voice.oct_enables & ((1 << (DIVIDER_BITS + 1))-1)); // and oct_enables; they hopefully shouldn't make a difference...
	for (int i = 0; i < voice.NUM_OSCS; i++) {
		std::string n = "osc" + std::to_string(i);
		sample_counter(v, n, voice.oscs[i]);
		sample(v, n + ".saw", voice.saw[i]);
	}
	for (int i = 0; i < voice.NUM_MODS; i++) sample_counter(v, "mod" + std::to_string(i), voice.mods[i]);
	for (int i = 0; i < voice.NUM_SWEEPS; i++) sample_counter(v, "sweep" + std::to_string(i), voice.sweeps[i]);
	sample(v, "shifter_src", voice.shifter_src);
	sample(v, "nf", voice.nf);
	sample(v, "y", voice.y);
	sample(v, "v", voice.v);
}

void output_name_line(std::ofstream &fout, const PairVector &v) {
	for (int i = 0; i < v.size(); i++) {
		fout << v[i].first;
		if (i + 1 < v.size()) fout << " ";
	}
	fout << "\n";
}

void output_change_line(std::ofstream &fout, const PairVector &v, const PairVector &v0, bool all=false) {
	fout << "c";
	for (int i = 0; i < v.size(); i++) {
		if (all || v[i].second != v0[i].second) {
			fout << " ";
			fout << i << ":" << v[i].second;
		}
	}
	fout << "\n";
}

void output_cfg_line(std::ofstream &fout, const uint16_t cfg[]) {
	fout << "p";
	for (int i = 0; i < CFG_WORDS; i++) fout << " " << cfg[i];
	fout << "\n";
}

void rand_cfg(uint16_t cfg[]) {
	for (int i = 0; i < CFG_WORDS; i++) cfg[i] = rand() & 0xffff;

	if (rand() % 11 == 0) {
		// Max frequency for cutoff and damp to damp the filter state once in a while
		cfg[VoiceModel::CUTOFF_INDEX] = cfg[VoiceModel::DAMP_INDEX] = 0;
	} else {
		// A chance to set max/min period so that the sweeps have a chance to check saturation
		if (rand() % 3 == 0) cfg[rand() % VoiceModel::NUM_SWEEPS] = (rand()&1) ? -1 : 0;
	}

	for (int i = 0; i < VoiceModel::NUM_OSCS; i++) cfg[i] &= ((1 << (OCT_BITS + OSC_PERIOD_BITS - 1)) - 1);
	for (int i = 0; i < VoiceModel::NUM_MODS; i++) cfg[VoiceModel::NUM_OSCS + i] &= rand() & ((1 << (OCT_BITS + MOD_PERIOD_BITS - 1)) - 1);
}

void set_cfg(VoiceModel &voice, const uint16_t cfg[]) {
	for (int i = 0; i < voice.NUM_OSCS; i++) voice.oscs[i].float_period = cfg[i] & ((1 << (OCT_BITS + OSC_PERIOD_BITS - 1)) - 1);
	for (int i = 0; i < voice.NUM_MODS; i++) voice.mods[i].float_period = cfg[voice.NUM_OSCS + i] & ((1 << (OCT_BITS + MOD_PERIOD_BITS - 1)) - 1);
	uint8_t *cfg8 = (uint8_t *)cfg;
	for (int i = 0; i < voice.NUM_SWEEPS; i++) {
		int c = cfg8[2*(voice.NUM_OSCS + voice.NUM_MODS) + i];
		voice.sweeps[i].float_period = c & ((1 << (OCT_BITS + SWEEP_PERIOD_BITS - 1)) - 1);
		voice.sweep_down[i] = (c>>7) != 0;
	}
}

void run_model() {
	VoiceModel voice;
	voice.init(OCT_BITS, OSC_PERIOD_BITS, MOD_PERIOD_BITS, SWEEP_PERIOD_BITS, WAVE_BITS, LEAST_SHR, OUTPUT_BITS, LOG2_SWEEP_UPDATE_PERIOD, SWEEP_LOG2_STEP);
	voice.reset();

	uint16_t cfg[CFG_WORDS];
	memset(cfg, 0, sizeof(cfg));
	set_cfg(voice, cfg);

	voice.update(voice.NUM_FSTATES);
	voice.state = 0;

	PairVector v;
	v.clear();
	sample_voice(v, voice);

	std::ofstream fout;
	fout.open("model.data");
	if (!fout) {
		std::cerr << "Failed to open output file";
		return;
	}

	output_name_line(fout, v);
	output_change_line(fout, v, v, true);

	PairVector v0;

	for (int j = 0; j < num_cfgs_to_try; j++) {
		bool randomize = true;
		for (int i = 0; i < num_samples_per_cfg; i++) {
			for (int state = 0; state < voice.NUM_STATES; state++) {
				bool rand_active = randomize && state == voice.NUM_FSTATES;
				if (rand_active) {
					rand_cfg(cfg);
					output_cfg_line(fout, cfg);
				}

				voice.update(state);
				voice.state = state == voice.NUM_STATES - 1 ? 0 : state + 1;

				v0 = v;
				v.clear();
				sample_voice(v, voice);
				output_change_line(fout, v, v0);

				if (rand_active) {
					set_cfg(voice, cfg);
					randomize = false;
				}
			}
		}
	}

	fout.close();
}

int main(int argc, char *argv[]) {
	srand(18561165);
	run_model();
	return 0;
}
