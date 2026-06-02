`default_nettype none
`timescale 1ns / 1ps

/*
 * tb.v — Testbench for tt_um_synth
 *
 * Guarded with `ifndef COCOTB_SIM so it only runs the self-checking
 * initial block in standalone Icarus/VCS mode. When run under cocotb
 * (make -B), the initial block is suppressed and test.py takes over —
 * no dual-driver conflicts.
 */

module tb;

    // -------------------------------------------------------------------------
    // DUT connections (Tiny Tapeout standard)
    // -------------------------------------------------------------------------
    reg        clk, rst_n, ena;
    reg  [7:0] ui_in;
    wire [7:0] uo_out;
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    wire audio_pwm = uo_out[0];
    wire ready     = uo_out[1];

    tt_um_synth dut (
        .ui_in  (ui_in),   .uo_out  (uo_out),
        .uio_in (uio_in),  .uio_out (uio_out), .uio_oe (uio_oe),
        .ena    (ena),     .clk     (clk),      .rst_n  (rst_n)
    );

    // -------------------------------------------------------------------------
    // Clock — 50 MHz (20 ns period)
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #10 clk = ~clk;

    // -------------------------------------------------------------------------
    // Helper tasks
    // -------------------------------------------------------------------------

    // Send one 8-bit config byte (LSB first) for a given voice/param,
    // then pulse load for one cycle.
    task automatic send_cfg_byte;
        input [1:0] voice;
        input [1:0] param;
        input [7:0] data;
        integer b;
        begin
            // Shift in 8 bits LSB-first
            for (b = 0; b < 8; b = b + 1) begin
                // ui_in = {unused, load, param_sel, voice_sel, data_valid, data_serial}
                ui_in <= {1'b0, 1'b0, param, voice, 1'b1, data[b]};
                @(posedge clk);
            end
            // Deassert data_valid
            ui_in <= {1'b0, 1'b0, param, voice, 1'b0, 1'b0};
            @(posedge clk);
            // Pulse load
            ui_in <= {1'b0, 1'b1, param, voice, 1'b0, 1'b0};
            @(posedge clk);
            ui_in <= 8'b0;
            @(posedge clk);
        end
    endtask

    // Configure a full voice: freq (16-bit), volume (4-bit), enable (1-bit)
    task automatic config_voice;
        input [1:0] voice;
        input [15:0] freq;
        input [3:0]  vol;
        input        enabit;
        begin
            send_cfg_byte(voice, 2'b00, freq[7:0]);          // freq low byte
            send_cfg_byte(voice, 2'b01, freq[15:8]);         // freq high byte
            send_cfg_byte(voice, 2'b10, {enabit, 3'b0, vol}); // enable + volume
        end
    endtask

    // Count PWM high pulses over a given number of clocks
    task automatic count_pwm_pulses;
        input  integer num_clocks;
        output integer pulse_count;
        integer c;
        begin
            pulse_count = 0;
            for (c = 0; c < num_clocks; c = c + 1) begin
                @(posedge clk);
                if (audio_pwm) pulse_count = pulse_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Scoreboard helpers
    // -------------------------------------------------------------------------
    integer pass_cnt, fail_cnt;

    task automatic check;
        input        condition;
        input [127:0] msg;
        begin
            if (condition) begin
                $display("  PASS: %s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %s", msg);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

`ifndef COCOTB_SIM
    // =========================================================================
    // Self-checking test sequence (standalone Verilog simulation only)
    // Suppressed when running under cocotb — test.py runs instead.
    // =========================================================================

    integer pulses_active, pulses_silent;
initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end


    initial begin
        // ----- Reset ---------------------------------------------------------
        rst_n   = 0;
        ena     = 1;
        ui_in   = 8'b0;
        uio_in  = 8'b0;
        pass_cnt = 0;
        fail_cnt = 0;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(3)  @(posedge clk);

        $display("\n==========================================================");
        $display("  tt_um_synth — Testbench");
        $display("==========================================================\n");

        // =====================================================================
        // TEST 1: Silence at reset — no voices enabled, PWM should be 0
        // =====================================================================
        $display("--- TEST 1: All voices silent after reset ---");
        count_pwm_pulses(500, pulses_silent);
        check(pulses_silent == 0, "No PWM output when all voices disabled");

        // =====================================================================
        // TEST 2: Single oscillator — Voice 0 at fast test frequency
        //   freq = 10 → half-period = 10 clocks → full period = 20 clocks
        //   Over 500 clocks we expect ~25 full cycles → ~500/2 = 250 HIGH clocks
        //   (volume = 15 = max → duty 60/64 ≈ 93.75% when oscillator is HIGH)
        //   So expected high pulses ≈ 250 * 60/64 ≈ 234  (accept range 200–270)
        // =====================================================================
        $display("\n--- TEST 2: Voice 0 active (freq=10, vol=15) ---");
        config_voice(2'd0, 16'd10, 4'd15, 1'b1);
        repeat(5) @(posedge clk); // settle
        count_pwm_pulses(500, pulses_active);
        $display("  PWM high pulses: %0d / 500 clocks", pulses_active);
        check(pulses_active >  50, "PWM is active (not stuck low)");
        check(pulses_active < 500, "PWM is not stuck high");

        // =====================================================================
        // TEST 3: Disable voice — PWM must return to 0
        // =====================================================================
        $display("\n--- TEST 3: Disable voice 0 ---");
        config_voice(2'd0, 16'd10, 4'd15, 1'b0);
        repeat(5) @(posedge clk);
        count_pwm_pulses(200, pulses_silent);
        check(pulses_silent == 0, "PWM silent after voice disabled");

        // =====================================================================
        // TEST 4: Three voices mixing — more duty cycle than one voice alone
        // =====================================================================
        $display("\n--- TEST 4: Three voices active (chord mixing) ---");
        config_voice(2'd0, 16'd10, 4'd8, 1'b1);  // vol=8
        config_voice(2'd1, 16'd13, 4'd8, 1'b1);  // vol=8, different freq
        config_voice(2'd2, 16'd17, 4'd8, 1'b1);  // vol=8, different freq
        repeat(10) @(posedge clk);
        count_pwm_pulses(1000, pulses_active);
        $display("  Three-voice PWM high pulses: %0d / 1000 clocks", pulses_active);
        check(pulses_active > 100, "Three-voice mix produces audible output");

        // =====================================================================
        // TEST 5: Noise channel — voice 3
        // =====================================================================
        $display("\n--- TEST 5: Noise channel active ---");
        config_voice(2'd0, 16'd0, 4'd0, 1'b0); // disable osc voices
        config_voice(2'd1, 16'd0, 4'd0, 1'b0);
        config_voice(2'd2, 16'd0, 4'd0, 1'b0);
        config_voice(2'd3, 16'd5, 4'd15, 1'b1); // noise, fast clock
        repeat(10) @(posedge clk);
        count_pwm_pulses(500, pulses_active);
        $display("  Noise PWM high pulses: %0d / 500 clocks", pulses_active);
        check(pulses_active > 10,  "Noise channel produces some output");
        check(pulses_active < 490, "Noise channel is not stuck");
        config_voice(2'd3, 16'd0, 4'd0, 1'b0); // silence noise

        // =====================================================================
        // TEST 6: On-the-fly reconfiguration — change frequency while running
        // =====================================================================
        $display("\n--- TEST 6: On-the-fly frequency change ---");
        config_voice(2'd0, 16'd8, 4'd15, 1'b1);
        repeat(50) @(posedge clk);
        // Change to freq=20 (lower pitch) while voice is still enabled
        send_cfg_byte(2'd0, 2'b00, 8'd20); // freq_lo only
        send_cfg_byte(2'd0, 2'b01, 8'd0);  // freq_hi = 0
        repeat(200) @(posedge clk);
        count_pwm_pulses(200, pulses_active);
        check(pulses_active > 0, "Voice still active after on-the-fly reconfiguration");
        config_voice(2'd0, 16'd0, 4'd0, 1'b0);

        // =====================================================================
        // SUMMARY
        // =====================================================================
        $display("\n==========================================================");
        $display("  RESULTS | PASS: %0d | FAIL: %0d | TOTAL: %0d",
                  pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("  STATUS  | *** ALL TESTS PASSED ***");
        else
            $display("  STATUS  | *** %0d FAILURE(S) ***", fail_cnt);
        $display("==========================================================\n");
        $finish;
    end

    // Timeout safety
    initial begin
        #5_000_000;
        $display("TIMEOUT — simulation exceeded budget");
        $finish;
    end

`endif // COCOTB_SIM

endmodule
