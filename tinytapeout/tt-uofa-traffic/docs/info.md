## How it works

A WiFi-assisted traffic-light controller peripheral. A loop-detector input
and a WiFi-side congestion count (delivered over an authenticated ESP32 SPI
link on the ui pins) decide when to raise a supplemental green-request pulse
for an external signal controller. Control/status/threshold registers sit on
the TinyQV register bus behind the SPI bridge on the uio pins
(uio[4]=CS, uio[5]=SCK, uio[6]=MOSI, uio[3]=MISO; 7-bit command = RW +
6-bit address, then 32 data bits, MSB first, SPI mode 0).

## How to test

Run the cocotb test in `test/` (`make -B`): SPI write/readback round-trip on
the control register and threshold reset-value check. The repo's Verilog
benches additionally cover congestion timing and the request pulse. On
silicon: pulse the loop input (ui[0]) and watch the request output (uo[0]).

## External hardware

Optional ESP32 (WiFi count source) and a 555/controller consuming the
request pulse; none required for register tests.
