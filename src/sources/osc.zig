//TODO: try building iterators to send to audio render func?
// is there a way to make them stateful?
//
//
const std = @import("std");

// TODO: refactor out the amplitude idea, should live elsewhere
const MAX_AMP: f32 = 1.0;
pub fn SineIterator(comptime amplitude: f32, comptime pitch: f32, comptime sampleRate: f32) type {
    return struct {
        sampleRate: f32 = sampleRate,
        pitch: f32 = pitch,
        amplitude: f32 = amplitude,
        theta: f32 = 0,

        const Self = @This();

        pub fn next(self: *Self) f32 {
            const result: f32 = std.math.sin(self.theta);

            self.theta += std.math.tau * self.pitch / sampleRate;

            if (self.theta > std.math.tau) {
                self.theta -= std.math.tau;
            }

            return result;
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

            std.debug.print("Square wave state: signal: {}, count: {}\n", .{ self.result, self.count });

            return self.result * MAX_AMP / 8;
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

            return self.direction * (self.count / halfStep) * (MAX_AMP / 8);
        }
    };
}
