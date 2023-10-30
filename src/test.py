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

	period = (512 + 56) << 3;

	preserved = False#True
	try:
		oct_counter = dut.dut.oct_counter.value
	except AttributeError:
		preserved = False

	if preserved:
		with open("tb-data.txt", "w") as file:
			file.write("data = [")
			for i in range(2*period):
				file.write(str(0 + dut.dut.oct_counter.value) + " ")
				file.write(str(0 + dut.dut.saw_counter.counter.value) + " ")
				file.write(str(0 + dut.dut.saw.value) + " ")
				file.write(str(0 + dut.dut.y.value) + " ")
				file.write(str(0 + dut.dut.v.value) + " ")
				file.write(str(0 + dut.dut.uo_out.value) + " ")
				file.write(";")
				await ClockCycles(dut.clk, 4)
			file.write("]")
	else:
		ClockCycles(dut.clk, 2*period*4)
