## How it works

This project implements a **3-voice PWM audio synthesizer** with an LFSR noise channel. It generates musical tones by mixing square-wave oscillators and outputs a single PWM signal that can be filtered with a simple RC circuit to drive a speaker.

Each oscillator counts down from a 16-bit divisor and toggles its output, producing a square wave at the target frequency. All voices are summed and compared against a PWM counter to produce the final output. A fourth channel generates broadband noise using a 16-bit Galois LFSR.

To balance simplicity with expressiveness, the accelerator features a compact signal chain:
* **External Interface:** All voice parameters (frequency, volume, enable) are loaded over an 8-bit serial shift register. The output is a single PWM pin on `uo_out[0]`.
* **Frequency Control:** Each voice has a 16-bit frequency divisor register. The oscillator toggles every `freq` clock cycles, giving `freq = CLK_HZ / (note_hz × 2)`. At 50 MHz, middle A (440 Hz) maps to divisor `56818` (`0xDDD2`).
* **Volume & Mixing:** Each voice has a 4-bit volume (0–15). The mixer sums active amplitudes (max = 60) and compares against a free-running 6-bit PWM counter, producing a natural linear mix at ~781 kHz carrier (inaudible).
* **Noise Channel:** Voice 3 drives a 16-bit Galois LFSR clocked by its own frequency divisor. A low divisor gives broadband white noise; a higher divisor gives a pitched noise effect.
* **Latency:** Zero — the PWM output updates every clock cycle with no pipeline delay.

## How to test

Because Tiny Tapeout has a limited pin count, voice parameters are loaded serially using an 8-bit shift register interface.

**1. Configuration Phase:**
Configure each voice by sending three 8-bit parameter bytes in sequence.
* Shift 8 bits LSB-first into **`ui_in[0]`** (`data_serial`), setting **`ui_in[1]`** (`data_valid`) high for each bit.
* Select the target voice using **`ui_in[3:2]`** (`voice_sel`): **00**–**10** = oscillators 0–2, **11** = noise channel.
* Select the parameter using **`ui_in[5:4]`** (`param_sel`): **00** = freq low byte, **01** = freq high byte, **10** = `{ena, 3'b0, vol[3:0]}`.
* Pulse **`ui_in[6]`** (`load`) high for one cycle to latch the shifted byte into the chosen register.

**2. Output Phase:**
* Connect **`uo_out[0]`** (`audio_pwm`) through a **10 kΩ resistor + 100 nF capacitor** to a speaker or 3.5 mm jack.
* **`uo_out[1]`** (`ready`) is always high — the synthesizer accepts new configuration at any time without interrupting playback.
* To play a chord, configure multiple voices and enable them simultaneously.

**Frequency reference (50 MHz clock):**

| Note | Frequency | Divisor (hex) | Divisor (decimal) |
|------|-----------|---------------|-------------------|
| A4   | 440 Hz    | `0xDDD2`      | 56818             |
| C5   | 523 Hz    | `0xBAE2`      | 47778             |
| C#5  | 554 Hz    | `0xB0B4`      | 45236             |
| E5   | 659 Hz    | `0x9420`      | 37920             |
| G5   | 784 Hz    | `0x7C90`      | 31888             |
| A5   | 880 Hz    | `0x6EF9`      | 28409             |

## External hardware

No specialized hardware is required for basic operation. To hear the audio output, wire a passive RC low-pass filter between the ASIC output and a speaker:

* **`uo_out[0]`** → 10 kΩ resistor → 100 nF capacitor → speaker / 3.5 mm jack (ground)

This single-pole filter has a −3 dB corner of ~160 Hz, removing the 781 kHz PWM carrier while passing all audible note content. A small amplifier (such as an LM386 or PAM8403) is recommended for driving a speaker at audible volume from the 1.8 V Tiny Tapeout output.

For interactive demos or sequenced playback, connecting to a microcontroller (such as a Raspberry Pi Pico or Arduino) is recommended to bit-bang the serial configuration interface and step through note sequences in real time.
