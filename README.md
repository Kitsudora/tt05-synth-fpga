# Nexys A7 Adaptation for tt05-synth

This project adds an adaptation layer to
[toivoh/tt05-synth](https://github.com/toivoh/tt05-synth), making it
compatible with the Nexys A7 FPGA board.

## Overview

The original tt05-synth design targets a different FPGA platform. This
adaptation modifies pin mappings, clocking, and some board-specific
interfaces to allow the project to build and run on the Nexys A7.

## Current Status

-   Basic functionality verified on Nexys A7
-   The design does not meet the original 50 MHz timing target; it
    operates correctly only at lower frequencies
-   The project is still under development and not yet complete

## Notes

-   This adaptation focuses on functional verification rather than full
    timing closure.
-   Further optimization and constraint tuning are required to reach
    higher clock speeds.

------------------------------------------------------------------------

Author: Kitsudora\
Platform: Digilent Nexys A7\
Base Project: [toivoh/tt05-synth](https://github.com/toivoh/tt05-synth)
