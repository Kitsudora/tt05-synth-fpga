![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg)

tt05-synth -- Analog inspired monosynth
=======================================
tt05-synth is a small analog inspired monosynth implementation in silicon to be taped out as part of tapeout TT05 at https://tinytapeout.com.

The synth has
- Two oscillators
    - individually selectable waveforms: saw/square/25% pulse/noise
- A second order lowpass filter
    - adjustable input volume, cutoff frequency, and resonance,
    - choice to feed in each oscillator to create a first or second order roll off,
    - saturation when overdriven -- a high input volume can create massive overdrive
- Programmable sweep rate for
    - the two oscillator frequencies,
    - the input volume, cutoff frequency, and resonance
- Pseudologarithmic scale for all controls using a simple floating point representation

The output is generated using Pulse Width Modulation, with dithering to add additional resolution for lower frequencies.
There is also an 8 bit output for the sample, but the PWM output should be easier to use.

The synth is intended to be clocked at 50 MHz and generate one sample every 32 cycles, or at `sample_rate = 1.5625 MHz`. Only 6 cycles are actually needed to generate a new sample, but using 32 cycles provides increased PWM resolution. The maximum oscillator frequency is `sample_rate/512`, or 3052 Hz if clocked at 50 MHz.

Signal flow
-----------

    oscillator 1 \
                  adder -> volume -> filter -> output
    oscillator 2 /

Pins
----
The top module has IO 24 pins:
- `ui_in[7:0] = w_data`: write data (input)
- `uio_in[3:0] = w_addr`: write address (input)
- `uio_in[6] = pwm` (output)
- `uio_in[7] = w_strobe`: write strobe (input)
- `uo_out[7:0] = sample`: 8 bit sample

There is also a clock and a synchronous reset.

**Caution!: Be sure that you know what you are doing when trying to connect an audio device to the `pwm` (or `sample`) signals!
Do not apply more than 1 V between the terminals of an audio plug that is connected to an audio input, or it might take damage!
Use an appropriate resistive divider to reduce the output voltage. Do not draw more than absolutely maximum 4 mA from the TT05 outputs to avoid damaging them!**

Controlling the sound
---------------------
The synth has an address space of 16 bytes for control registers, which control the generated sound.

### Writing to the control registers
To write a byte to a control register:
- Keep `w_strobe` low normally
- Apply the desired address and data to `w_addr`, `w_data`
- Pulse `w_strobe` high for at least 10 clock cycles
- Keep `w_addr`, `w_data` stable during the same time
- `w_addr`, `w_data` should be sampled 2-10 cycles after the rising edge of `w_strobe`

### Memory map
Most control registers consume 16 bits of address space each.
The memory map is laid out as follows: (one 16 bit word per line)

    offset |  high byte |     low byte |
    -------|------------|--------------|
     0     |        osc1_period        |
     2     |        osc2_period        |
     4     |      cutoff_period        |
     6     |        damp_period        |
     8     |         vol_period        |
    10     | osc2_sweep |   osc1_sweep |
    12     | damp_sweep | cutoff_sweep |
    14     |        cfg |    vol_sweep |

### Control registers
All control registers except `cfg` are expressed in terms of periods, which in turn control frequencies.
The periods are expessed in a simple floating point format with 4 bit exponent and 9, 5, or 3 bit mantissa for the oscillator periods,
cutoff/damp/volume periods, and sweep periods respectively. The sweep periods also have a sign bit.

The floating point format means that increasing the exponent for a period by one step lowers the frequency by one octave.
The exception is that for all periods, an exponent of 15 turns results in a frequency of 0, which can be used to turn off an oscillator, sweep, etc.

At reset, the control registers are initialized to all ones, resulting in an output at zero volume and frequency.

#### Oscillators
The oscillator frequency is given by

    osc_freq = sample_rate / (2^osc_period[12:9] * (512 + osc_period[8:0]))

for a maximum oscillator frequency of 3052 Hz, where `osc_period` is `osc1_period` or `osc2_period`.
An decrement of one to `osc_period` corresponds to a frequency increase of 1.69 to 3.38 cents, depending on the mantissa `osc_period[8:0]`.
Detuning the two oscillators by up to 10 cents can add a nice depth and fatness to the sound.
Detuning by approximately an octave, a fifth, or a fourth can also provide interesting effects.

#### Cutoff, volume, and damping
The cutoff frequency is approximately given by

    cutoff_freq =  sample_rate * 4 / (2 * pi * 2^(cutoff_period[8:5]) * (32 + cutoff_period[4:0]))

for a maximum cutoff frequency of 31085 Hz.
As `cutoff_freq` increases above `osc_freq`, the output signal gains in harmonics.
As it decreases below, the whole signal starts to be damped out.

The filter's resonance and input volume are determined by the relation between cutoff frequency on the one hand, and the damping/volume frequencies on the other. The damping and volume frequencies are calculated in the same way as `cutoff_freq`, but using the corresponding periods.

The volume gain used to feed the two oscillators into the filter is given by

    vol_gain = vol_freq / cutoff_freq

The resonance of the filter is approximately given by

    Q = cutoff_freq / damp_freq

A too high `vol_gain` or, too high `Q`, or both, will saturate the filter. This can be a desirable effect in some case,
but drastically alters the effect of detuning the oscillators.
A neutral starting point can be

    vol_gain = 1/4
    Q = 1

which provides some margin before saturating the filter.

#### Frequency sweeping
The sweep frequency is given by

    sweep_freq = sample_rate / (4 * 2^sweep_period[6:3] * (8 + sweep_period[2:0]))

where `sweep_period = osc1_sweep, osc2_sweep, cutoff_sweep,... ` etc.
With a rate of `sweep_freq`, the corresponding period register will be increased/decreased by one, depending on `sweep_period[7]`:
0 to increase the period and 1 to decrease it.

Sweeping can be used to sweep the oscillator and cutoff frequencies as well as the resonance and input volume.
By updating the sweep frequencies at certain times, envelopes can be realized.

#### Waveform
The waveform for oscillator 1 is controlled by `cfg[1:0]`, and for oscillator 2 by `cfg[3:2]`:
- 0: pulse wave (25% duty cycle)
- 1: square wave
- 2: noise
- 3: 2 bit sawtooth wave

#### Filter fall-off
Each oscillator can be fed into the filter in one of two ways, depending on `cfg[6]` / `cfg[6]` for oscillator 1 / 2:
- 0: First order fall-off
- 1: Second order fall-off
