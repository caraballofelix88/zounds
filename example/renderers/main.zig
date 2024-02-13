const zgui = @import("zgui");

const main = @import("main.zig");

pub fn renderNode(node: main.AudioNode) void {
    _ = node;
}

pub fn renderPlot() !void {
    zgui.plot.init();

    if (zgui.plot.beginPlot("Line Plot", .{ .h = -1.0 })) {
        zgui.plot.setupAxis(.x1, .{ .label = "xaxis" });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = 5 });
        zgui.plot.setupLegend(.{ .south = true, .west = true }, .{});
        zgui.plot.setupFinish();
        zgui.plot.plotLineValues("y data", i32, .{ .v = &.{ 0, 1, 0, 1, 0, 1 } });
        zgui.plot.plotLine("xy data", f32, .{
            .xv = &.{ 0.1, 0.2, 0.5, 2.5 },
            .yv = &.{ 0.1, 0.3, 0.5, 0.9 },
        });
        zgui.plot.endPlot();
    }
    zgui.plot.deinit();
}
