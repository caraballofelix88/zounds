const testing = @import("std").testing;

pub const SampleFormat = enum {
    f32,
    i16,

    pub fn size(fmt: SampleFormat) u8 {
        return bitSize(fmt) / 8;
    }

    pub fn bitSize(fmt: SampleFormat) u8 {
        return switch (fmt) {
            .f32 => 32,
            .i16 => 16,
        };
    }

    pub fn fmtType(comptime fmt: SampleFormat) type {
        return switch (fmt) {
            .f32 => f32,
            .i16 => i16,
        };
    }
};

pub const FormatData = struct {
    sample_format: SampleFormat,
    channels: []const ChannelPosition,
    sample_rate: u32,
    is_interleaved: bool = true, // channel samples interleaved?

    pub fn frameSize(f: FormatData) usize {
        return f.sample_format.size() * f.channels.len;
    }

    pub fn invSampleRate(f: FormatData) f32 {
        return 1.0 / @as(f32, @floatFromInt(f.sample_rate));
    }
};

pub const ChannelPosition = enum {
    left,
    right,

    pub const mono: [1]ChannelPosition = .{.left};
    pub const stereo: [2]ChannelPosition = .{ .left, .right };

    pub fn fromChannelCount(count: usize) []const ChannelPosition {
        return switch (count) {
            1 => &mono,
            2 => &stereo,
            else => &mono,
        };
    }
};

test "ChannelPosition.fromChannelCount" {
    try testing.expectEqualSlices(ChannelPosition, &.{.left}, ChannelPosition.fromChannelCount(1));
    try testing.expectEqualSlices(ChannelPosition, &.{ .left, .right }, ChannelPosition.fromChannelCount(2));
}
