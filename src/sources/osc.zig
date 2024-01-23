//TODO: try building iterators to send to audio render func?
// is there a way to make them stateful?

const std = @import("std");

pub fn SineIterator(comptime amplitude: f32, comptime pitch: f32, comptime sampleRate: f32) type {
    return struct {
        sampleRate: f32 = sampleRate,
        pitch: f32 = pitch,
        amplitude: f32 = amplitude,
        phase: f32 = 0,

        const Self = @This();

        pub fn next(self: *Self) f32 {
            const result: f32 = std.math.sin(self.phase);

            self.phase += std.math.tau * self.pitch / self.sampleRate;

            if (self.phase > std.math.tau) {
                self.phase -= std.math.tau;
            }

            return result * self.amplitude;
        }
    };
}

pub fn SquareIterator(comptime amplitude: f32, comptime pitch: f32, comptime sampleRate: f32) type {
    return struct {
        sampleRate: f32 = sampleRate,
        pitch: f32 = pitch,
        amplitude: f32 = amplitude,
        count: f32 = 0,
        result: f32 = 1,

        const Self = @This();

        pub fn next(self: *Self) f32 {
            self.count += 1;
            if (self.count >= sampleRate / (pitch * 2)) {
                self.count = 0.0;
                self.result = self.result * -1;
            }

            return self.result * self.amplitude;
        }
    };
}

pub fn TriangleIterator(comptime amplitude: f32, comptime pitch: f32, comptime sampleRate: f32) type {
    return struct {
        sampleRate: f32 = sampleRate,
        pitch: f32 = pitch,
        amplitude: f32 = amplitude,
        count: f32 = 0,
        direction: f32 = 1,

        const Self = @This();

        const halfStep = sampleRate / (pitch * 2);

        pub fn next(self: *Self) f32 {
            self.count += 1;
            if (self.count >= halfStep) {
                self.count = 0.0;
                self.direction = self.direction * -1;
            }

            std.debug.print("Triangle wave state: signal: {}, count: {}\n", .{ self.direction, self.count });

            return self.direction * (self.count / halfStep) * amplitude;
        }
    };
}
