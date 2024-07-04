const std = @import("std");
const signals = @import("../signals.zig");

pub const Sink = struct {
    ctx: *signals.Context,
    id: []const u8 = "Sink",
    inputs: std.ArrayList(?signals.Signal),
    out: ?signals.Signal = null,

    pub const ins = [_]std.meta.FieldEnum(Sink){.inputs};
    pub const outs = [_]std.meta.FieldEnum(Sink){.out};

    // use ctx.alloc for now
    pub fn init(ctx: *signals.Context) !Sink {
        const inputs = std.ArrayList(?signals.Signal).init(ctx.alloc);
        return .{
            .ctx = ctx,
            .inputs = inputs,
        };
    }

    pub fn deinit(self: *Sink) void {
        self.inputs.deinit();
    }

    pub fn process(ptr: *anyopaque) void {
        const sink: *Sink = @ptrCast(@alignCast(ptr));

        if (sink.out == null) {
            std.debug.print("uh oh, fix", .{});
        }

        var result: f32 = undefined;
        var input_count: u8 = 0;

        for (sink.inputs.items) |maybe_in| {
            if (maybe_in) |in| {
                result += in.get();
                input_count += 1;
            }
        }

        result /= @floatFromInt(@max(input_count, 1));
        sink.out.?.set(result);
    }

    pub fn node(self: *Sink) signals.Node {
        return signals.Node.init(self, Sink);
    }
};
