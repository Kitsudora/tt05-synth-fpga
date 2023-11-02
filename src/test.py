import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer, ClockCycles

waveform_test = True
compare_test = True

@cocotb.test()
async def test_waveform(dut):
	if not waveform_test: return
	dut._log.info("start")
	clock = Clock(dut.clk, 2, units="us")
	cocotb.start_soon(clock.start())

	# reset
	dut._log.info("reset")
	dut.rst_n.value = 0
	dut.ui_in.value = 0
	dut.uio_in.value = 0
	await ClockCycles(dut.clk, 10)
	dut.rst_n.value = 1

	# enable
	dut.ena.value = 1

	#period = (512 + 56) << 3;
	period = 512;

	preserved = True
	#preserved = False
	try:
		oct_counter = dut.dut.oct_counter.value
	except AttributeError:
		preserved = False

	if preserved:
		#dut.dut.cfg[0].value = 256;
		#dut.dut.cfg[1].value = 256;
		dut.dut.cfg[0].value = dut.dut.cfg[1].value = 512;
		#dut.dut.cfg[2+0].value = 1 << 5;
		dut.dut.cfg[2+0].value = 1 << 4;
		dut.dut.cfg[2+1].value = 3 << 5;
		dut.dut.cfg[2+2].value = 2 << 5;
		#dut.dut.y = -1 << 19;
		await ClockCycles(dut.clk, 8)
		with open("tb-data.txt", "w") as file:
			file.write("data = [")
			for i in range(2*period):
				file.write(str(0 + dut.dut.oct_counter.value) + " ")
				file.write(str(0 + dut.dut.saw_counter.counter.value) + " ")
				file.write(str(0 + dut.dut.saw[0].value) + " ")
				file.write(str(0 + dut.dut.y.value) + " ")
				file.write(str(0 + dut.dut.v.value) + " ")
				file.write(str(0 + dut.dut.uo_out.value) + " ")
				file.write(";")
				await ClockCycles(dut.clk, 8)
			file.write("]")
	else:
		ClockCycles(dut.clk, 2*period*8)

NUM_OSCS = 2
NUM_MODS = 3

def sample(v, x): v.append(int(x))

def sample_voice(v, voice):
	sample(v, voice.y_out.value)
	for i in range(NUM_OSCS):
		sample(v, voice.cfg[i].value)
		sample(v, voice.saw_counter_state[i].value)
	for i in range(NUM_MODS):
		sample(v, voice.cfg[i + NUM_OSCS].value)
		sample(v, voice.mod_counter_state[i].value)

@cocotb.test()
async def test_compare(dut):
	if not waveform_test: return
	dut._log.info("start")
	clock = Clock(dut.clk, 2, units="us")
	cocotb.start_soon(clock.start())

	# reset
	dut._log.info("reset")
	dut.rst_n.value = 0
	dut.ui_in.value = 0
	dut.uio_in.value = 0
	await ClockCycles(dut.clk, 10)
	dut.rst_n.value = 1

	# enable
	dut.ena.value = 1

	preserved = True
	#preserved = False
	try:
		oct_counter = dut.dut.oct_counter.value
	except AttributeError:
		preserved = False

	if not preserved: return

	states = dict()

	try:
		with open("model.data") as f:
			names = f.readline().split(" ")
			rev_names = {name: i for (i, name) in enumerate(names)}

			ignore = set()
			ignore.add(rev_names["out"])

			await ClockCycles(dut.clk, 1)
			line_number = 0
			while True:
				line_number += 1
				line = f.readline()
				if line == "": break
				items = line.split(" ")
				if line[0] == "c":
					for item in items[1:]:
						key, value = item.split(":")
						states[int(key)] = int(value)

					v = []
					sample_voice(v, dut.dut)

					match = True
					for (i, value) in enumerate(v):
						if not i in ignore and value != states[i]: match = False

					if not match:
						print()
						print("Mismatch on line", line_number)
						for (i, value) in enumerate(v):
							print(value == states[i], "\t", names[i], ":\t", states[i], ",\t", value)

					assert match

					await ClockCycles(dut.clk, 1)
	except FileNotFoundError:
		println("model.data not found!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
