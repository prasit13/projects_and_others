create_clock -name clk -period 10.0 [get_ports clk]
# let the reg-to-reg paths determine the result.
set_input_delay  -clock clk 0.0 \
    [get_ports -filter {DIRECTION == IN && NAME != "clk"}]
set_output_delay -clock clk 0.0 [get_ports -filter {DIRECTION == OUT}]