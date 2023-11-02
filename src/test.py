import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer, ClockCycles


@cocotb.test()
async def test(dut):
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
