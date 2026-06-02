"""
test.py — cocotb testbench for tt_um_synth (3-Voice PWM Synthesizer)

Run with:  cd test && make -B
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import math

# =============================================================================
# Constants
# =============================================================================
CLK_FREQ_HZ = 50_000_000

def note_freq_divisor(note_hz: float) -> int:
    """Return the 16-bit frequency divisor for a given note in Hz."""
    divisor = round(CLK_FREQ_HZ / (note_hz * 2))
    return max(1, min(divisor, 0xFFFF))

# =============================================================================
# Low-level hardware helpers
# =============================================================================
def build_ui_in(data_serial=0, data_valid=0, voice_sel=0, param_sel=0, load=0):
    """Pack individual fields into the 8-bit ui_in bus."""
    return (
        (data_serial & 0x1)       |
        ((data_valid  & 0x1) << 1) |
        ((voice_sel   & 0x3) << 2) |
        ((param_sel   & 0x3) << 4) |
        ((load        & 0x1) << 6)
    )

async def send_cfg_byte(dut, voice: int, param: int, data: int):
    """Shift 8 bits (LSB first) into the config shift register, then load."""
    for bit_idx in range(8):
        bit = (data >> bit_idx) & 1
        dut.ui_in.value = build_ui_in(
            data_serial=bit, data_valid=1,
            voice_sel=voice, param_sel=param, load=0
        )
        await RisingEdge(dut.clk)

    # Deassert data_valid
    dut.ui_in.value = build_ui_in(voice_sel=voice, param_sel=param)
    await RisingEdge(dut.clk)

    # Pulse load
    dut.ui_in.value = build_ui_in(voice_sel=voice, param_sel=param, load=1)
    await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    await RisingEdge(dut.clk)

async def config_voice(dut, voice: int, freq: int, vol: int, enable: bool):
    """Configure a voice: freq (16-bit), volume (0-15), enable."""
    await send_cfg_byte(dut, voice, param=0, data=freq & 0xFF)          # freq low
    await send_cfg_byte(dut, voice, param=1, data=(freq >> 8) & 0xFF)   # freq high
    await send_cfg_byte(dut, voice, param=2,
                        data=(0x80 if enable else 0x00) | (vol & 0x0F)) # ena+vol

async def count_pwm_pulses(dut, num_clocks: int) -> int:
    """Count how many clocks audio_pwm (uo_out[0]) is high over num_clocks cycles."""
    count = 0
    for _ in range(num_clocks):
        await RisingEdge(dut.clk)
        if dut.uo_out.value.to_unsigned() & 0x01:
            count += 1
    return count

# =============================================================================
# Test: silence at reset
# =============================================================================
@cocotb.test()
async def test_silence_at_reset(dut):
    """No voices enabled → audio_pwm must stay 0."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    pulses = await count_pwm_pulses(dut, 300)
    dut._log.info(f"Silence test: {pulses}/300 clocks high (expect 0)")
    assert pulses == 0, f"Expected 0 PWM pulses at reset, got {pulses}"

# =============================================================================
# Test: single oscillator produces PWM output
# =============================================================================
@cocotb.test()
async def test_single_oscillator(dut):
    """Voice 0 at freq=10 (fast test pitch) should produce active PWM."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)

    # Enable voice 0: freq=10 (half-period), vol=15 (max), enabled
    await config_voice(dut, voice=0, freq=10, vol=15, enable=True)
    await ClockCycles(dut.clk, 5)   # let oscillator start

    pulses = await count_pwm_pulses(dut, 500)
    dut._log.info(f"Single osc: {pulses}/500 clocks high")

    assert pulses  > 50,  f"PWM stuck low? Only {pulses} high pulses"
    assert pulses < 500,  f"PWM stuck high? {pulses} high pulses out of 500"

# =============================================================================
# Test: disabling a voice silences it
# =============================================================================
@cocotb.test()
async def test_disable_silences(dut):
    """Enable then disable voice 0 — PWM must go quiet."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)

    await config_voice(dut, voice=0, freq=10, vol=15, enable=True)
    await ClockCycles(dut.clk, 5)
    pulses_on = await count_pwm_pulses(dut, 200)

    await config_voice(dut, voice=0, freq=10, vol=15, enable=False)
    await ClockCycles(dut.clk, 5)
    pulses_off = await count_pwm_pulses(dut, 200)

    dut._log.info(f"Enabled: {pulses_on}/200 | Disabled: {pulses_off}/200")
    assert pulses_on  > 10, "Voice should produce output when enabled"
    assert pulses_off == 0, f"Voice should be silent after disable, got {pulses_off}"

# =============================================================================
# Test: A major chord (three-voice polyphony)
# =============================================================================
@cocotb.test()
async def test_chord(dut):
    """
    Configure A4 + C#5 + E5 (A major chord) and verify mixed output.
    Uses short test-frequency divisors to keep simulation fast.
    """
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)

    # Use small divisors so we see many cycles in short sim time
    await config_voice(dut, voice=0, freq=11, vol=8, enable=True)  # root
    await config_voice(dut, voice=1, freq=13, vol=8, enable=True)  # third
    await config_voice(dut, voice=2, freq=17, vol=8, enable=True)  # fifth
    await ClockCycles(dut.clk, 5)

    pulses = await count_pwm_pulses(dut, 1000)
    dut._log.info(f"A major chord: {pulses}/1000 clocks high")

    # Three voices × vol 8 max sum = 24; duty ≈ 24/64 ≈ 37.5% max when all high
    # Expect pulses in a reasonable range indicating mixing is working
    assert pulses  > 50,   f"Chord too quiet: {pulses}/1000 clocks"
    assert pulses < 1000,  f"Chord stuck high: {pulses}/1000 clocks"

# =============================================================================
# Test: noise channel
# =============================================================================
@cocotb.test()
async def test_noise_channel(dut):
    """Voice 3 (LFSR noise) should produce output that is neither all-0 nor all-1."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)

    await config_voice(dut, voice=3, freq=4, vol=15, enable=True)
    await ClockCycles(dut.clk, 5)

    pulses = await count_pwm_pulses(dut, 800)
    dut._log.info(f"Noise channel: {pulses}/800 clocks high")

    assert pulses  > 10,  f"Noise stuck low: {pulses}/800"
    assert pulses < 790,  f"Noise stuck high: {pulses}/800"

# =============================================================================
# Test: ready bit is always high
# =============================================================================
@cocotb.test()
async def test_ready_always_high(dut):
    """uo_out[1] (ready) must remain 1 throughout operation."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)

    await config_voice(dut, voice=0, freq=20, vol=10, enable=True)

    for cycle in range(200):
        await RisingEdge(dut.clk)
        ready = (dut.uo_out.value.to_unsigned() >> 1) & 1
        assert ready == 1, f"Ready went low at cycle {cycle}!"

    dut._log.info("ready bit stayed high for 200 cycles: PASS")
