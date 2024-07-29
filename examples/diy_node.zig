const std = @import("std");
const zounds = @import("zounds");

const Signal = zounds.signals.Signal;
const Node = zounds.signals.Node;

const Wobble = struct {
    ctx: zounds.signals.GraphContext,
    id: []const u8 = "wobb",
    base_pitch: Signal = .{ .static = 440.0 },
    frequency: Signal = .{ .static = 10.0 },

    amp: Signal = .{ .static = 10.0 },
    out: Signal = .{ .static = 0.0 },
    phase: f32 = 0,

    pub const ins = .{ .base_pitch, .frequency, .amp };
    pub const outs = .{.out};

    pub fn process(ptr: *anyopaque) void {
        var w: *Wobble = @ptrCast(@alignCast(ptr));

        const result = w.base_pitch.get() + w.amp.get() * std.math.sin(w.phase);

        w.phase += std.math.tau * w.frequency.get() * w.ctx.inv_sample_rate;

        while (w.phase >= std.math.tau) {
            w.phase -= std.math.tau;
        }

        w.out.set(result);
    }

    pub fn node(ptr: *Wobble) Node {
        return Node.init(ptr, Wobble);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const config = zounds.ContextConfig{
        .frames_per_packet = 1,
        .desired_format = .{
            .sample_format = .f32,
            .sample_rate = 44_100,
            .channels = zounds.ChannelPosition.fromChannelCount(2),
            .is_interleaved = true,
        },
    };

    var signal_graph = zounds.signals.Graph(.{ .channel_count = 2 }){ .format = config.desired_format };
    var graph_ctx = signal_graph.context();

    var wobb = Wobble{
        .ctx = graph_ctx,
        .amp = .{ .static = 50.0 },
        .frequency = .{ .static = 0.2 },
        .base_pitch = .{ .static = zounds.utils.pitchFromNote(60) },
    };
    var wobb_node = graph_ctx.register(&wobb);

    var osc = zounds.dsp.Oscillator{ .ctx = graph_ctx };
    var osc_node = graph_ctx.register(&osc);

    graph_ctx.connect(osc_node.port("pitch"), wobb_node.port("out"));

    signal_graph.root_signal = osc_node.port("out").*;

    var player_ctx = try zounds.Context.init(.coreaudio, alloc, config);

    const device: zounds.Device = .{
        .sample_rate = 44_100,
        .channels = zounds.ChannelPosition.fromChannelCount(2),
        .id = "fake_device",
        .name = "Fake Device",
        .formats = &.{},
    };

    const options: zounds.StreamOptions = .{
        .write_ref = &graph_ctx,
        .format = config.desired_format,
    };

    var player = try player_ctx.createPlayer(device, &writeFn, options);
    defer player.deinit();

    player.play();

    std.time.sleep(std.time.ns_per_s * 5);
}

pub fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    var graph: *zounds.signals.GraphContext = @ptrCast(@alignCast(write_ref));

    const sample_buf: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);

    for (0..num_frames) |frame_idx| {
        const curr_frame = graph.opts.channel_count * frame_idx;
        @memcpy(sample_buf[curr_frame .. curr_frame + graph.opts.channel_count], graph.next());
    }
}
