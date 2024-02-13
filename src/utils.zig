const std = @import("std");

// TODO: generate lookup table instead of doing math
// TODO: note doesn't need to be i32
pub fn pitchFromNote(note: i32) f32 {
    const f_note: f32 = @floatFromInt(note);
    const tone_exp = (f_note - 69.0) / 12.0;
    return 440 * std.math.pow(f32, 2.0, tone_exp);
}

pub fn decibelsToAmplitude(dbs: f32) f32 {
    // TK
    const power_factor = 20;
    return std.math.pow(f32, 10.0, dbs / power_factor);
}

test {
    // TODO:
}
