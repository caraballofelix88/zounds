const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const signals = @import("../signals.zig");
const main = @import("../main.zig");

const VoiceOpts = struct {
    ctx: *const signals.GraphContext,
    pitch: f32 = 50.0,
    amp: f32 = 1.0,
    trigger: *f32,
    format: main.FormatData,
    id: []const u8,
};

const ChildGraphOpts: signals.Options = .{ .scratch_size = 16, .channel_count = 2, .max_node_count = 8 };
pub const AdditiveVoice = struct {
    // osc_1: dsp.Oscillator = undefined,
    // osc_2: dsp.Oscillator = undefined,
    // osc_3: dsp.Oscillator = undefined,
    // osc_4: dsp.Oscillator = undefined,

    id: []const u8 = "additive",

    // sink: dsp.Sink(4) = undefined,

    // adsr: dsp.ADSR = undefined,

    child_graph: *signals.Graph(ChildGraphOpts) = undefined,

    ctx: *const signals.GraphContext = undefined,

    arena: std.heap.ArenaAllocator = undefined,

    // pitch: signals.Signal = .{ .static = 440.0 },
    // trigger: signals.Signal = .{ .static = 0.0 },

    out: signals.Signal = .{ .static = 0.0 },

    pub const ins = .{};
    pub const outs = .{.out};

    pub fn init(opts: VoiceOpts, allocator: std.mem.Allocator) !AdditiveVoice {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const alloc = arena.allocator();

        const child_graph = try alloc.create(signals.Graph(ChildGraphOpts));
        child_graph.* = .{ .format = opts.format };

        const child_ctx = child_graph.context();

        std.log.debug("incoming pitch arg from opts:\t{}\n", .{opts.pitch});

        const osc_1 = try alloc.create(dsp.Oscillator);
        osc_1.* = .{
            .id = "voice_1",
            .amp = .{ .static = opts.amp * 1.0 },
            .pitch = .{ .static = opts.pitch },
            .ctx = child_ctx,
        };
        const osc_1_hdl = try child_ctx.register(osc_1);
        const osc_1_node = child_ctx.getNode(osc_1_hdl).?;

        const osc_2 = try alloc.create(dsp.Oscillator);
        osc_2.* = .{
            .id = "voice_2",
            .amp = .{ .static = opts.amp * 0.8 },
            .pitch = .{ .static = opts.pitch * 3.0 },
            .ctx = child_ctx,
        };
        const osc_2_hdl = try child_ctx.register(osc_2);
        const osc_2_node = child_ctx.getNode(osc_2_hdl).?;

        const osc_3 = try alloc.create(dsp.Oscillator);
        osc_3.* = .{
            .id = "voice_3",

            .amp = .{ .static = opts.amp * 0.78 },
            .pitch = .{ .static = opts.pitch * 5.0 },
            .ctx = child_ctx,
        };
        const osc_3_hdl = try child_ctx.register(osc_3);
        const osc_3_node = child_ctx.getNode(osc_3_hdl).?;

        const osc_4 = try alloc.create(dsp.Oscillator);
        osc_4.* = .{
            .id = "voice_4",

            .amp = .{ .static = opts.amp * 0.76 },
            .pitch = .{ .static = opts.pitch * 7.0 },
            .ctx = child_ctx,
        };
        const osc_4_hdl = try child_ctx.register(osc_4);
        const osc_4_node = child_ctx.getNode(osc_4_hdl).?;

        const sink = try alloc.create(dsp.Sink(4));
        sink.* = .{
            .ctx = child_ctx,
        };
        const sink_hdl = try child_ctx.register(sink);
        const sink_node = child_ctx.getNode(sink_hdl).?;

        const adsr = try alloc.create(dsp.ADSR);
        adsr.* = .{ .ctx = child_ctx, .trigger = .{ .ptr = opts.trigger } };
        const adsr_hdl = try child_ctx.register(adsr);
        const adsr_node = child_ctx.getNode(adsr_hdl).?;

        // plug in oscs to sink
        try child_ctx.connect(sink_node.port("in_1").field_ptr, osc_1_node.port("out").field_ptr);
        try child_ctx.connect(sink_node.port("in_2").field_ptr, osc_2_node.port("out").field_ptr);
        try child_ctx.connect(sink_node.port("in_3").field_ptr, osc_3_node.port("out").field_ptr);
        try child_ctx.connect(sink_node.port("in_4").field_ptr, osc_4_node.port("out").field_ptr);

        // plug adsr to sink
        try child_ctx.connect(sink_node.port("amp").field_ptr, adsr_node.port("out").field_ptr);

        // plug graph root to sink output
        child_graph.root_signal = sink_node.port("out").field_ptr.*;

        return .{
            .id = opts.id,
            .arena = arena,
            .ctx = opts.ctx,
            .child_graph = child_graph,
        };
    }

    pub fn deinit(self: *AdditiveVoice) void {
        self.arena.alloc().destroy();
    }

    pub fn process(ptr: *anyopaque) void {
        var v: *AdditiveVoice = @ptrCast(@alignCast(ptr));

        const next = v.child_graph.context().next()[0];

        // std.log.debug("processing voice {s}:\t{}\n", .{ v.id, next });

        v.out.set(next);
    }
};
