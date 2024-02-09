const std = @import("std");
const main = @import("../main.zig");

// should know channel count and sampleFmt
pub const BufferIterator = struct {
    head: usize = 0,
    buffer: []const u8,
    sample_fmt: main.SampleFormat = main.SampleFormat.f32,
    channel_count: u8 = 1,

    const Self = @This();

    pub fn init(buf: []const u8, sampleFmt: main.SampleFormat) Self {
        _ = sampleFmt;
        return .{ .buffer = buf };
    }

    // returns frame as bytes
    pub fn next(self: *Self) ?[]u8 {
        if (!self.hasNext()) {
            return null;
        }

        const slice = self.buffer[self.head..(self.head + self.frameSize())];
        self.head += self.frameSize();

        if (self.head >= self.buffer.len) {
            self.head = 0; // theoretically loops the buffer
            std.debug.print("BufferIterator: Looping buffer\n", .{});
        }

        return @constCast(slice);
    }

    fn frameSize(self: Self) usize {
        return self.channel_count * self.sample_fmt.size();
    }

    pub fn hasNext(self: Self) bool {
        return (self.head + self.frameSize()) < self.buffer.len;
    }
};

test "bufferIterator" {
    // TK
}
