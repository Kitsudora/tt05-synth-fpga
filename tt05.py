# Test code for writing synth registers.
# Note that microPython is quite slow at writing the registers,
# which will cause audible and unpleasant artifacts when trying
# to update more than one register at the same time.
# Please see https://github.com/toivoh/tt05-synth-rp2040
# for an alternate firmware for sending commands much quicker
# to the synth, more developed code for forming the commands,
# and a demo tune.

from machine import Pin
from ttboard.mode import RPMode

tt.mode = RPMode.ASIC_RP_CONTROL
tt.shuttle.tt_um_toivoh_synth.enable()
tt.reset_project(True)
#tt.clock_project_PWM(50e6) # doesn't set 50 MHz
set_clock_hz(50_000_000)
tt.uio0.mode = Pin.OUT
tt.uio1.mode = Pin.OUT
tt.uio2.mode = Pin.OUT
tt.uio3.mode = Pin.OUT
tt.uio7.mode = Pin.OUT
#tt.mode = RPMode.ASIC_RP_CONTROL
tt.reset_project(False)


from time import sleep

# Set a single 8 bit register.
def set_reg8(addr, value):
	addr &= 15
	tt.input_byte = value
	tt.bidir_byte = addr
	tt.bidir_byte = addr | 128 # strobe
	#sleep(0.001)
	tt.bidir_byte = addr

# Set two consecutive 8 bit registers.
def set_reg16(addr, value):
	set_reg8(addr,    value & 255)
	set_reg8(addr+1, (value >> 8) & 255)

# Set oscillator period for one or more oscillators, mask decides which to set.
def play(note, oct, detune=2, mask=3):
	note += 12*(oct + 9)
	oct, note = note // 12, note % 12
	p = int(512 * 2**((11 - note)/12))
	oct = 15 - oct
	f = (oct << 9) | (p & 511)
	if mask & 1: set_reg16(0, f) # period1
	if mask & 2: set_reg16(2, f+detune) # period1
	return oct, p, f

# Set filter parameters.
#
# cutoff, vol, and resonance can be floating point, and are multiplied by 32.
# cutoff is a period, lower value means higher cutoff.
# resonance and vol are adjusted relative to cutoff.
def patch(cutoff, vol=0, resonance=0):
	cutoff = round(32*cutoff)
	vol = round(32*(vol-2))
	resonance = round(32*resonance)

	resonance += cutoff
	vol_p = cutoff-vol

	# Avoid saturation: back off from minimum period
	m = min(0, min(cutoff, min(resonance, vol_p)))
	cutoff = min(cutoff - m, 0x1ff)
	resonance = min(resonance - m, 0x1ff)
	vol_p = min(vol_p - m, 0x1ff)

	set_reg16(4, cutoff) # cutoff period
	set_reg16(6, resonance) # damp period
	set_reg16(8, vol_p) # vol period

# Set waveform for each oscillator
def waveform(wf1, wf2=None):
	if wf2 is None: wf2 = wf1
	wf1 &= 3
	wf2 &= 3
	out = wf1 | (wf2 << 2) | 192
	set_reg8(15, out) # cfg

# Set sweep rate for a register.
# addr specifies the register to set the sweep rate for, not the sweep rate register.
def sweep(addr, sign, rate):
	assert 0 <= sign <= 1
	rate = round(8*rate)
	assert 0 <= rate <= 127
	assert addr&1 == 0
	assert 0 <= addr <= 8
	addr = (addr >> 1) + 10
	set_reg8(addr, (sign << 7) | rate)

# Turn off sweep for a given register.
# addr specifies the register to set the sweep rate for, not the sweep rate register.
def sweep_off(addr):
	assert addr&1 == 0
	assert 0 <= addr <= 8
	addr = (addr >> 1) + 10
	set_reg8(addr, 255)



for i in range(0,10,2): sweep_off(i)
set_reg16(0, 3 << 9) # period1
set_reg16(2, (3 << 9) + 2) # period2
#set_reg16(4, 0) # cutoff period
#set_reg16(6, 0) # damp period
#set_reg16(8, 0) # vol period
patch(0)
waveform(3)


d = 0.6
for i in range(4):
	play(0, 4); sleep(d)
	play(3, 4); sleep(d)
	play(7, 4); sleep(d)
play(0, 4); sleep(d)
