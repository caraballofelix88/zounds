const std = @import("std");
const zgui = @import("zgui");
const zounds = @import("zounds");

const main = @import("../main.zig");

// TODO: (improvement) consider https://en.wikipedia.org/wiki/Ramer%E2%80%93Douglas%E2%80%93Peucker_algorithm
pub fn renderPlot(buf: *std.RingBuffer) !void {
    zgui.plot.init();

    const size = buf.data.len; // 2 seconds of samples
    const slice = buf.sliceLast(size);

    const first: []f32 = @alignCast(std.mem.bytesAsSlice(f32, slice.first));
    const second: []f32 = @alignCast(std.mem.bytesAsSlice(f32, slice.second));

    if (zgui.plot.beginPlot("Line Plot", .{ .h = -1.0 })) {
        zgui.plot.setupAxis(.x1, .{ .label = "xaxis" });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = @floatFromInt(buf.data.len / 4), .cond = .once });
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

pub fn renderNodeGraph(nodes: []main.NodeCtx) !void {
    if (zgui.begin("Audio Nodes", .{ .flags = .{} })) {
        const w = 150.0;
        const h = 150.0;

        if (zgui.beginChild("Canvas", .{ .w = 800.0, .h = 800.0 })) {
            const o = zgui.getCursorScreenPos();
            zgui.text("Screen Origin: {}, {}", .{ o[0], o[1] });
            for (nodes) |node| {
                zgui.setCursorPos(.{ node.x, node.y });
                if (zgui.invisibleButton("rect", .{
                    .w = w,
                    .h = h,
                })) {
                    if (zgui.isMouseDoubleClicked(zgui.MouseButton.left)) {
                        std.debug.print("double clicked {s}\n", .{node.label});
                    }
                    std.debug.print("clicked invisible button for {s}\n", .{node.label});
                }

                try drawRect(.{ node.x, node.y }, .{ w, h }, .{ .label = node.label });
            }
            zgui.endChild();
        }
        zgui.end();
    }
}

pub fn renderSequence(s: *zounds.sources.SequenceSource) !void {
    _ = s;
    if (zgui.begin("sequence node", .{})) {
        zgui.text("Text here", .{});
        zgui.end();
    }
}

const Vec2 = [2]f32;

const DrawRectArgs = struct { label: [:0]const u8 };

pub fn drawRect(coords: Vec2, w_h: Vec2, args: DrawRectArgs) !void {
    const screen_origin: Vec2 = zgui.getCursorScreenPos();

    // copypasted this without really knowing what for
    var canvas_size: Vec2 = zgui.getContentRegionAvail();

    if (canvas_size[0] < 50.0) {
        canvas_size[0] = 50.0;
    }
    if (canvas_size[1] < 50.0) {
        canvas_size[1] = 50.0;
    }

    const draw_list = zgui.getWindowDrawList();

    const top_left = .{ screen_origin[0] + coords[0], screen_origin[1] + coords[1] };

    const bottom_right = .{
        top_left[0] + w_h[0],
        top_left[1] + w_h[1],
    };

    draw_list.addRectFilled(.{
        .col = 0xFF00FF00,
        .pmin = top_left,
        .pmax = bottom_right,
    });

    draw_list.addText(top_left, 64, "{s}", .{args.label});
}
