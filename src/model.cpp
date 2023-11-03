#include <vector>
#include <string>
#include <iostream>
#include <fstream>

#include "synth.h"

const int OCT_BITS = 4;
const int OSC_PERIOD_BITS = 10;
const int MOD_PERIOD_BITS = 6;
const int SWEEP_PERIOD_BITS = 10;
const int WAVE_BITS = 2;
const int LEAST_SHR = 3;
const int OUTPUT_BITS = 8;

const int LOG2_SWEEP_UPDATE_PERIOD = 0; // 3;
const int SWEEP_LOG2_STEP = 4; // <= SWEEP_PERIOD_BITS - 1


typedef std::pair<std::string, int> Pair;
typedef std::vector<Pair> PairVector;

void sample(PairVector &v, const std::string &name, int x) {
	v.push_back(Pair(name, x));
}

void sample_counter(PairVector &v, const std::string &name, CounterModel &c) {
	sample(v, name + ".float_period", c.float_period);
	sample(v, name + "counter", c.counter);
}

void sample_voice(PairVector &v, VoiceModel &voice) {
	int i;
	sample(v, "out", voice.out);
	sample(v, "state", voice.state);
	sample(v, "oct_counter", voice.oct_counter);
	sample(v, "oct_enables", voice.oct_enables);
	for (int i = 0; i < voice.NUM_OSCS; i++) {
		std::string n = "osc" + std::to_string(i);
		sample_counter(v, n, voice.oscs[i]);
		sample(v, n + ".saw", voice.saw[i]);
	}
	for (int i = 0; i < voice.NUM_MODS; i++) sample_counter(v, "mod" + std::to_string(i), voice.mods[i]);
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

void run_model() {
	VoiceModel voice;
	voice.init(OCT_BITS, OSC_PERIOD_BITS, MOD_PERIOD_BITS, SWEEP_PERIOD_BITS, WAVE_BITS, LEAST_SHR, OUTPUT_BITS, LOG2_SWEEP_UPDATE_PERIOD, SWEEP_LOG2_STEP);
	voice.reset();

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
	for (int i = 0; i < 10; i++) {
		for (int state = 0; state < voice.NUM_STATES; state++) {
			voice.update(state);
			voice.state = state == voice.NUM_STATES - 1 ? 0 : state + 1;

			v0 = v;
			v.clear();
			sample_voice(v, voice);
			output_change_line(fout, v, v0);
		}
	}

	fout.close();
}

int main(int argc, char *argv[]) {
	run_model();
	return 0;
}
