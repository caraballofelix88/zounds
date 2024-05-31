const std = @import("std");
const testing = std.testing;

// TODO: generate lookup table instead of doing math?
// TODO: pitchFromStringNote, using []u8 -> midi note table
pub fn pitchFromNote(note: u8) f32 {
    const f_note: f32 = @floatFromInt(note);
    const tone_exp = (f_note - 69.0) / 12.0;
    return 440 * std.math.pow(f32, 2.0, tone_exp);
}

test "pitchFromNote" {
    try testing.expectEqual(440.0, pitchFromNote(60));
}

pub fn decibelsToAmplitude(dbs: f32) f32 {
    const power_factor = 20;
    return std.math.pow(f32, 10.0, dbs / power_factor);
}

test "decibelsToAmplitude" {
    // TK
}
