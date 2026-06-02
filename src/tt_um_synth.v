`default_nettype none
`timescale 1ns / 1ps

/*
 * tt_um_synth.v — 3-Voice PWM Synthesizer + Noise Channel
 * Tiny Tapeout standard interface (50 MHz clock)
 *
 * Three square-wave oscillators + one LFSR noise channel.
 * Voices are mixed and output as a single PWM signal.
 * Connect uo_out[0] through a simple RC filter (10 kΩ + 100 nF) to a speaker.
 *
 * ─── Pin Mapping ────────────────────────────────────────────────────────────
 *   ui_in[0]    data_serial  — config shift register input (LSB first)
 *   ui_in[1]    data_valid   — clock-enable for shift register
 *   ui_in[3:2]  voice_sel    — voice to configure: 0-2 = oscillators, 3 = noise
 *   ui_in[5:4]  param_sel    — 00=freq_lo  01=freq_hi  10=vol+ena
 *   ui_in[6]    load         — latch shifted byte into selected register
 *   ui_in[7]    (unused)
 *   uo_out[0]   audio_pwm    — PWM audio output
 *   uo_out[1]   ready        — always 1 (accepts config at any time)
 *   uo_out[7:2] tied 0
 *   uio_*       unused
 *
 * ─── Configuration Protocol ─────────────────────────────────────────────────
 *   Step 1: Shift 8 bits LSB-first:
 *           set data_serial = bit[i], data_valid = 1, hold voice_sel/param_sel stable
 *           clock once per bit (8 cycles total)
 *   Step 2: Set voice_sel and param_sel, pulse load = 1 for one clock.
 *
 *   param_sel encoding:
 *     2'b00  →  freq[7:0]               (low byte of frequency divisor)
 *     2'b01  →  freq[15:8]              (high byte of frequency divisor)
 *     2'b10  →  {ena, 3'b0, vol[3:0]}   (bit 7 = enable, bits 3:0 = volume)
 *
 * ─── Frequency Formula ──────────────────────────────────────────────────────
 *   freq = 50_000_000 / (note_hz * 2)
 *
 *   Musical note examples (50 MHz):
 *     A4  =  440 Hz  →  freq = 56818  (0xDDD2)
 *     C5  =  523 Hz  →  freq = 47778  (0xBAE2)
 *     E5  =  659 Hz  →  freq = 37920  (0x9420)
 *     G5  =  784 Hz  →  freq = 31888  (0x7C90)
 *     A5  =  880 Hz  →  freq = 28409  (0x6EF9)
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module tt_um_synth (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // =========================================================================
    // Input aliases
    // =========================================================================
    wire        data_serial = ui_in[0];
    wire        data_valid  = ui_in[1];
    wire [1:0]  voice_sel   = ui_in[3:2];
    wire [1:0]  param_sel   = ui_in[5:4];
    wire        load        = ui_in[6];

    // Bidirectionals unused — drive outputs low, set all pins as inputs
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // =========================================================================
    // Config shift register — 8 bits, LSB first
    // =========================================================================
    reg [7:0] cfg_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cfg_shift <= 8'b0;
        else if (data_valid)
            cfg_shift <= {data_serial, cfg_shift[7:1]};
    end

    // =========================================================================
    // Voice register file — 4 voices (0-2 = oscillators, 3 = noise)
    //   v_freq[v][15:0]  half-period in clock cycles
    //   v_vol [v][ 3:0]  volume (0 = silent, 15 = loudest)
    //   v_ena [v]        voice enable
    // =========================================================================
    reg [15:0] v_freq [0:3];
    reg  [3:0] v_vol  [0:3];
    reg        v_ena  [0:3];

    integer n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (n = 0; n < 4; n = n + 1) begin
                v_freq[n] <= 16'd0;
                v_vol[n]  <= 4'd0;
                v_ena[n]  <= 1'b0;
            end
        end else if (load) begin
            case (param_sel)
                2'b00: v_freq[voice_sel][7:0]  <= cfg_shift;
                2'b01: v_freq[voice_sel][15:8] <= cfg_shift;
                2'b10: begin
                    v_ena[voice_sel] <= cfg_shift[7];
                    v_vol[voice_sel] <= cfg_shift[3:0];
                end
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Oscillators — 3 square-wave generators
    //   Count down from v_freq[i], toggle output, reload.
    //   freq=0 or ena=0 → output held low, counter frozen.
    // =========================================================================
    reg [15:0] osc_cnt [0:2];
    reg        osc_out [0:2];

    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : OSC
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    osc_cnt[i] <= 16'd0;
                    osc_out[i] <= 1'b0;
                end else if (!v_ena[i] || v_freq[i] == 16'd0) begin
                    osc_cnt[i] <= 16'd0;
                    osc_out[i] <= 1'b0;
                end else if (osc_cnt[i] == 16'd0) begin
                    osc_cnt[i] <= v_freq[i] - 1'd1;
                    osc_out[i] <= ~osc_out[i];
                end else begin
                    osc_cnt[i] <= osc_cnt[i] - 1'd1;
                end
            end
        end
    endgenerate

    // =========================================================================
    // Noise channel — 16-bit Galois LFSR (maximal-length polynomial x^16+x^15+x^13+x^4+1)
    //   Clocked by voice 3's frequency divisor.
    //   Produces broadband noise; set v_freq[3] to control noise bandwidth.
    // =========================================================================
    reg [15:0] lfsr;
    reg [15:0] noise_cnt;
    reg        noise_out;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr      <= 16'hACE1;   // non-zero seed
            noise_cnt <= 16'd0;
            noise_out <= 1'b0;
        end else if (!v_ena[3] || v_freq[3] == 16'd0) begin
            noise_cnt <= 16'd0;
        end else if (noise_cnt == 16'd0) begin
            noise_cnt <= v_freq[3] - 1'd1;
            lfsr      <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);
            noise_out <= lfsr[0];
        end else begin
            noise_cnt <= noise_cnt - 1'd1;
        end
    end

    // =========================================================================
    // Mixer — sum active voice amplitudes, compare against PWM counter
    //
    //   Each active voice contributes vol[3:0] (0-15) to the sum.
    //   Max sum = 4 voices × 15 = 60 (fits in 6 bits).
    //   6-bit PWM counter runs 0→63 and wraps.
    //   PWM freq = 50 MHz / 64 ≈ 781 kHz  (well above audible range).
    //
    //   audio_pwm duty cycle = sum / 64, giving natural linear volume mixing.
    // =========================================================================
    reg [5:0] pwm_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pwm_cnt <= 6'd0;
        else        pwm_cnt <= pwm_cnt + 1'd1;
    end

    wire [3:0] amp0 = (osc_out[0] & v_ena[0]) ? v_vol[0] : 4'd0;
    wire [3:0] amp1 = (osc_out[1] & v_ena[1]) ? v_vol[1] : 4'd0;
    wire [3:0] amp2 = (osc_out[2] & v_ena[2]) ? v_vol[2] : 4'd0;
    wire [3:0] amp3 = (noise_out  & v_ena[3]) ? v_vol[3] : 4'd0;

    // Two-stage tree addition — keeps fan-in low for timing
    wire [4:0] mix_ab  = {1'b0, amp0} + {1'b0, amp1};  // max 30
    wire [4:0] mix_cd  = {1'b0, amp2} + {1'b0, amp3};  // max 30
    wire [5:0] mix_sum = {1'b0, mix_ab} + {1'b0, mix_cd}; // max 60

    wire audio_pwm = (mix_sum > pwm_cnt);

    // =========================================================================
    // Output
    // =========================================================================
    assign uo_out[0]   = audio_pwm;
    assign uo_out[1]   = 1'b1;    // always ready
    assign uo_out[7:2] = 6'b0;

endmodule
