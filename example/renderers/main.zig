const std = @import("std");
const zgui = @import("zgui");

const main = @import("main.zig");

pub fn renderNode(node: main.AudioNode) void {
    _ = node;
}

pub fn renderPlot(buf: *std.RingBuffer) !void {
    zgui.plot.init();

    const size = buf.data.len; // 2 seconds of samples
    const slice = buf.sliceLast(size);

    const first: []f32 = @alignCast(std.mem.bytesAsSlice(f32, slice.first));
    const second: []f32 = @alignCast(std.mem.bytesAsSlice(f32, slice.second));

    if (zgui.plot.beginPlot("Line Plot", .{ .h = -1.0 })) {
        zgui.plot.setupAxis(.x1, .{ .label = "xaxis" });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = @floatFromInt(size / 4) });
        zgui.plot.setupAxisLimits(.y1, .{ .min = -1.0, .max = 1.0 });
        zgui.plot.setupLegend(.{ .south = true, .west = true }, .{});
        zgui.plot.setupFinish();

        zgui.plot.plotLineValues("y data", f32, .{
            .v = @constCast(second),
            .xstart = @floatFromInt(first.len),
        });
        zgui.plot.plotLineValues("y data", f32, .{
            .v = @constCast(first),
        });
        zgui.plot.endPlot();
    }
    zgui.plot.deinit();
}
