const fmt = @import("audio_format.zig");

pub const AudioBuffer = @This();

format: fmt.FormatData,
buf: []const u8,

pub fn sampleCount(b: AudioBuffer) usize {
    return b.buf.len / b.format.sample_format.size();
}

pub fn frameCount(b: AudioBuffer) usize {
    return b.buf.len / b.format.frameSize();
}

pub fn trackLength(b: AudioBuffer) usize { // in seconds
    return b.sampleCount() / b.format.sample_rate;
}
