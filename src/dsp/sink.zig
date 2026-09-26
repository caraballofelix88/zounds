const std = @import("std");
const z = @import("../root.zig");

pub fn Sink(num_ins: u8) type {
    _ = num_ins; // autofix

    return struct {
        ctx: *const z.GraphContext,
        id: []const u8 = "Sink",
        // TODO: dynamic struct fields, based on num_ins
        in_1: z.Signal = .{ .static = 0.0 },
        in_2: z.Signal = .{ .static = 0.0 },
        in_3: z.Signal = .{ .static = 0.0 },
        in_4: z.Signal = .{ .static = 0.0 },
        amp: z.Signal = .{ .static = 1.0 },
        out: z.Signal = .{ .static = 0.0 },

        const Self = @This();

        pub const ins = [_]std.meta.FieldEnum(Self){ .in_1, .in_2, .in_3, .in_4, .amp };
        pub const outs = [_]std.meta.FieldEnum(Self){.out};

        pub fn process(ptr: *anyopaque) void {
            const sink: *Self = @ptrCast(@alignCast(ptr));

            var result: f32 = undefined;
            var input_count: u8 = 0;

            inline for (&.{
                sink.in_1,
                sink.in_2,
                sink.in_3,
                sink.in_4,
            }) |in| {
                result += in.get();
                input_count += 1;
            }

            result /= @floatFromInt(@max(input_count, 1));
            result *= sink.amp.get();
            sink.out.set(result);
        }
    };
}
