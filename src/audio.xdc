create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 1} [get_ports { clk }];

set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { clk }];
set_property -dict { PACKAGE_PIN C12   IOSTANDARD LVCMOS33 } [get_ports { rst_n }];

set_property -dict { PACKAGE_PIN A11   IOSTANDARD LVCMOS33 } [get_ports { aud_pwm_o }];
set_property -dict { PACKAGE_PIN D12   IOSTANDARD LVCMOS33 } [get_ports { aud_sd_o }];