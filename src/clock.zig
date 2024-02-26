const std = @import("std");

// TODO: rename to something else?
// TODO: better way to do beat arithmetic
pub const NoteDuration = enum {
    whole,
    half,
    quarter,
    eighth,
    sixteenth,

    pub fn beatFraction(duration: NoteDuration) f32 {
        return switch (duration) {
            .whole => 1.0,
            .half => 0.5,
            .quarter => 0.25,
            .eighth => 0.125,
            .sixteenth => 0.0625,
        }; // assumes 4/4
    }

    // TODO: might wanna round this and send back an int
    pub fn sampleInterval(duration: NoteDuration, sample_rate: u32, bpm: u32) f32 {
        const samples_per_min = 60 * sample_rate;
        const samples_per_beat: f32 = @floatFromInt(samples_per_min / bpm);
        return duration.beatFraction() * samples_per_beat * 4;
    }

    pub fn plus(a: NoteDuration, b: NoteDuration) f32 {
        return a.beatFraction() + b.beatFraction();
    }

    pub fn minus(a: NoteDuration, b: NoteDuration) !f32 {
        std.debug.assert(a.beatFraction() > b.beatFraction());
        return a.beatFraction() - b.beatFraction();
    }
};

pub const Note = struct {
    pitch: u8, // MIDI note
    duration: NoteDuration,
};
