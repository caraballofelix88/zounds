const std = @import("std");
const signals = @import("../signals.zig");

pub const Sink = struct {
    ctx: *signals.Context,
    alloc: std.mem.Allocator,
    id: []const u8 = "Sink",
    inputs: std.ArrayList(signals.Signal),
    out: signals.Signal = .{ .static = 0.0 },

    pub const ins = [_]std.meta.FieldEnum(Sink){.inputs};
    pub const outs = [_]std.meta.FieldEnum(Sink){.out};

    // use ctx.alloc for now
    pub fn init(ctx: *signals.Context, alloc: std.mem.Allocator) !Sink {
        const inputs = std.ArrayList(signals.Signal).init(alloc);
        return .{
            .ctx = ctx,
            .alloc = alloc,
            .inputs = inputs,
        };
    }

    pub fn deinit(self: *Sink) void {
        self.inputs.deinit();
    }

    pub fn process(ptr: *anyopaque) void {
        const sink: *Sink = @ptrCast(@alignCast(ptr));

        var result: f32 = undefined;
        var input_count: u8 = 0;

        for (sink.inputs.items) |in| {
            result += in.get();
            input_count += 1;
        }

        result /= @floatFromInt(@max(input_count, 1));
        sink.out.set(result);
    }

    pub fn node(self: *Sink) signals.Node {
        return signals.Node.init(self, Sink);
    }
};
