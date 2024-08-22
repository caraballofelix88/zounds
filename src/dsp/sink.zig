const std = @import("std");
const signals = @import("../signals.zig");

pub fn Sink(num_ins: u8) type {
    _ = num_ins; // autofix

    return struct {
        ctx: *const signals.GraphContext,
        id: []const u8 = "Sink",
        // TODO: dynamic struct fields, based on num_ins
        in_1: signals.Signal = .{ .static = 0.0 },
        in_2: signals.Signal = .{ .static = 0.0 },
        in_3: signals.Signal = .{ .static = 0.0 },
        amp: signals.Signal = .{ .static = 1.0 },
        out: signals.Signal = .{ .static = 0.0 },

        const Self = @This();

        pub const ins = [_]std.meta.FieldEnum(Self){ .in_1, .in_2, .in_3, .amp };
        pub const outs = [_]std.meta.FieldEnum(Self){.out};

        pub fn process(ptr: *anyopaque) void {
            const sink: *Self = @ptrCast(@alignCast(ptr));

            var result: f32 = undefined;
            var input_count: u8 = 0;

            inline for (&.{ sink.in_1, sink.in_2, sink.in_3 }) |in| {
                result += in.get();
                input_count += 1;
            }

            result /= @floatFromInt(@max(input_count, 1));
            result *= sink.amp.get();
            sink.out.set(result);
        }
    };
}
