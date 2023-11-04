import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer, ClockCycles

waveform_test = True
#compare_test = True
compare_test = False

NUM_OSCS = 2
NUM_MODS = 3
NUM_SWEEPS = 5

OCT_BITS = 4
DIVIDER_BITS = 18
OSC_PERIOD_BITS = 10
MOD_PERIOD_BITS = 6
WAVE_BITS = 2
LEAST_SHR = 3

EXTRA_BITS = LEAST_SHR + (1 << OCT_BITS) - 1
FEED_SHL = (1 << OCT_BITS) - 1
FSTATE_BITS = WAVE_BITS + EXTRA_BITS
SHIFTER_BITS = WAVE_BITS + (1 << OCT_BITS) - 1

NUM_FSTATES = 5
CFG_WORDS = 8

NUM_STATES = 32

def init1(dut):
	dut._log.info("start")
	clock = Clock(dut.clk, 2, units="us")
	cocotb.start_soon(clock.start())

	# reset
	dut._log.info("reset")
	dut.rst_n.value = 0
	dut.ui_in.value = 0
	dut.uio_in.value = 0

def init2(dut):
	dut.rst_n.value = 1

	# enable
	dut.ena.value = 1

	preserved = True
	#preserved = False
	try:
		oct_counter = dut.dut.oct_counter.value
	except AttributeError:
		preserved = False

	return preserved


@cocotb.test()
async def test_waveform(dut):
	if not waveform_test: return
	init1(dut)
	await ClockCycles(dut.clk, 10)
	preserved = init2(dut)

	#period = (512 + 56) << 3;
	period = 512;

	if preserved:
		for i in range(NUM_SWEEPS): dut.dut.cfg[i].value = 0

		#dut.dut.cfg[0].value = 256
		#dut.dut.cfg[1].value = 256
		#dut.dut.cfg[0].value = dut.dut.cfg[1].value = 256
		#dut.dut.cfg[0].value = dut.dut.cfg[1].value = 512
		#dut.dut.cfg[2+0].value = 1 << 5
		#dut.dut.cfg[2+0].value = 1 << 4
		#dut.dut.cfg[2+1].value = 3 << 5
		dut.dut.cfg[2+2].value = 2 << 5

		#dut.dut.cfg[2+0].value = 1 << 6; dut.dut.cfg[2+2].value = 0 # Full range sweep

		dut.dut.cfg[5].value = dut.dut.cfg[6].value = dut.dut.cfg[7].value = 0xffff

		#dut.dut.cfg[5].value = 0
		#dut.dut.cfg[5].value = 0x8000
		#dut.dut.cfg[5].value = 0x8080
		#dut.dut.cfg[6].value = 0xff00
		dut.dut.cfg[6].value = 0x00ff
		#dut.dut.cfg[7].value = 0xff80

		#dut.dut.cfg[7].value = 0x3fff #Inject into y instead

		#dut.dut.cfg[7].value = 0xf5ff # Square
		dut.dut.cfg[7].value = 0xf0ff # Pulse
		#dut.dut.cfg[7].value = 0xf2ff # Noise + pulse

		#dut.dut.y = -1 << 19
		await ClockCycles(dut.clk, NUM_STATES)
		with open("tb-data.txt", "w") as file:
			with open("pwm-data.txt", "w") as pwmfile:
				file.write("data = [")
				pwmfile.write("pwm_data = [")
				for i in range(2*period):
					file.write(str(0 + dut.dut.oct_counter.value) + " ")
					file.write(str(0 + dut.dut.saw_counter.counter.value) + " ")
					file.write(str(0 + dut.dut.saw[0].value) + " ")
					file.write(str(0 + dut.dut.y.value) + " ")
					file.write(str(0 + dut.dut.v.value) + " ")
					file.write(str(0 + dut.dut.uo_out.value) + " ")
					file.write(str(0 + dut.dut.cfg[0].value) + " ")
					file.write(str(0 + dut.dut.cfg[1].value) + " ")
					file.write(";")

					for j in range(NUM_STATES):
						pwmfile.write(str(0 + dut.uio_out[6].value) + " ")
						await ClockCycles(dut.clk, 1)

				file.write("]")
				pwmfile.write("]")
	else:
		ClockCycles(dut.clk, 2*period*NUM_STATES)


@cocotb.test()
async def test_write_cfg(dut):
	if not waveform_test: return
	dut.uio_in.value = 0
	dut.ui_in.value = 0
	init1(dut)
	await ClockCycles(dut.clk, 10)
	preserved = init2(dut)
	if not preserved: return

	cfg = [0xa55a]*NUM_SWEEPS + [0xffff]*(CFG_WORDS - NUM_SWEEPS)
	for (i, c) in enumerate(cfg): dut.dut.cfg[i].value = c
	await ClockCycles(dut.clk, 1)
	for (i, c) in enumerate(cfg): assert int(dut.dut.cfg[i].value) == c

	j = 0
	i0 = 0
	while True:
		#print("j =", j)
		await ClockCycles(dut.clk, 16)

		i0 = 2*(j - NUM_SWEEPS)
		for (i, c) in enumerate(cfg): assert i < i0 or int(dut.dut.cfg[i].value) == c

		if j >= CFG_WORDS: break

		# Write low byte
		dut.ui_in.value = 0xa5 # data
		cfg[j] = (cfg[j] & 0xff00) | 0xa5
		dut.uio_in.value = 128 | 2*j # strobe | address
		await ClockCycles(dut.clk, 1)
		dut.uio_in.value = 2*j # turn off strobe
		await ClockCycles(dut.clk, 9)

		i0 = 2*(j - NUM_SWEEPS) + 1
		for (i, c) in enumerate(cfg):
			#print("i:", i, ", c:", c)
			assert i < i0 or int(dut.dut.cfg[i].value) == c

		# Write high byte
		dut.ui_in.value = 0x5a # data
		cfg[j] = (cfg[j] & 0xff) | 0x5a00
		dut.uio_in.value = 128 | 2*j + 1 # strobe | address
		await ClockCycles(dut.clk, 1)
		dut.uio_in.value = 2*j + 1 # turn off strobe
		await ClockCycles(dut.clk, 9)

		j += 1


def sample0(v, value, nbits=64):
	if value >= 1 << (nbits-1): value -= 1 << nbits
	v.append(value)

def sample(v, x, nbits=64, keep=True):
	if keep:
		sample0(v, int(x.value), nbits)
	else:
		v.append(-1)

def sample_voice(v, voice):
	state = int(voice.state.value)
	prev_state = state - 1
	full_prev_state = 0 <= prev_state < NUM_FSTATES
	full_state = 0 <= state < NUM_FSTATES

	sample(v, voice.uo_out)
	sample(v, voice.misc_cfg)
	sample(v, voice.state)
	sample(v, voice.oct_counter)
	sample(v, voice.oct_enables)
	for i in range(NUM_OSCS):
		sample(v, voice.cfg[i])
		sample(v, voice.saw_counter_state[i])
		sample(v, voice.saw[i])
	for i in range(NUM_MODS):
		sample(v, voice.cfg[i + NUM_OSCS])
		sample(v, voice.mod_counter_state[i])
	for i in range(NUM_SWEEPS):
		sample0(v, voice.cfg8[i + 2*(NUM_OSCS + NUM_MODS)].value & 127) # exclude the sign bit
		sample(v, voice.sweep_counter_state[i])
	sample(v, voice.shifter_src, SHIFTER_BITS, full_state)
	sample(v, voice.nf, 64, full_state)
	sample(v, voice.y, FSTATE_BITS)
	sample(v, voice.v, FSTATE_BITS)

@cocotb.test()
async def test_compare(dut):
	if not compare_test: return
	init1(dut)
	await ClockCycles(dut.clk, 10)
	preserved = init2(dut)
	if not preserved: return

	for i in range(CFG_WORDS): dut.dut.cfg[i].value = 0
	dut.dut.cfg[7].value = 0xff00 # Don't test misc_cfg here

	states = dict()

	try:
		with open("model.data") as f:
			names = f.readline().rstrip().split(" ")
			rev_names = {name: i for (i, name) in enumerate(names)}

			ignore = set()
			#ignore.add(rev_names["out"])
			oct_enables_index = rev_names["oct_enables"]
			ignore.add(oct_enables_index)

			delay = set()
			delay.add(rev_names["oct_enables"])
			delay.add(rev_names["shifter_src"])
			delay.add(rev_names["nf"])

			await ClockCycles(dut.clk, 1)
			line_number = 1
			num_fails = 0
			last_v = None
			while True:
				line_number += 1
				if line_number % 10000 == 0: dut._log.info("line " + str(line_number))

				line = f.readline().rstrip()
				if line == "": break
				items = line.split(" ")
				if line[0] == "c":
					for item in items[1:]:
						key, value = item.split(":")
						states[int(key)] = int(value)

					vv = []
					sample_voice(vv, dut.dut)
					v = vv.copy()
					if last_v != None:
						for i in delay: v[i] = last_v[i]
					else:
						for i in delay: v[i] = -1
					last_v = vv


					match = True
					assert len(v) == len(states)
					for (i, value) in enumerate(v):
						if not i in ignore and value != states[i]: match = False

					if not match:
						num_fails += 1
						print()
						print("Mismatch on line", line_number)
						for (i, value) in enumerate(v):
							print(value == states[i], "\t", i, "\t", names[i], ":\tc: ", states[i], ",\tv:", value, sep="")

					assert num_fails < 3

					if oct_enables_index in ignore: ignore.remove(oct_enables_index)
					await ClockCycles(dut.clk, 1)
				elif line[0] == "p":
					# Update configuration
					for (i, cfgval) in enumerate(items[1:]):
						dut.dut.cfg[i].value = int(cfgval)
				else:
					assert False

			assert num_fails == 0
	except FileNotFoundError:
		println("model.data not found!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
