const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const osc = @import("sources/osc.zig");
const sources = @import("sources/main.zig");

pub const Context = struct {
    alloc: std.mem.Allocator,
    scratch: []f32,
    node_list: ?[]*const Context.Node = null,
    sink: ?Context.Signal(f32) = null,
    sample_rate: u32 = 44_100,
    ticks: u64 = 0,
    node_count: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) !Context {
        return .{
            .alloc = allocator,
            .scratch = try allocator.alloc(f32, 1024),
        };
    }

    pub fn deinit(ctx: Context) void {
        ctx.alloc.free(ctx.scratch);
        if (ctx.node_list) |list| {
            ctx.alloc.free(list);
        }
    }

    pub const Node = struct {
        ptr: *anyopaque,
        id: []const u8 = "x",
        processFn: *const fn (*anyopaque) void,
        inlet: *?Context.Signal(f32),
        outlet: *?Context.Signal(f32),
        //inlets: *const fn (*anyopaque) void,
        //outlets: *const fn (*anyopaque) void,

        pub fn process(n: Context.Node) void {
            n.processFn(n.ptr);
        }

        // pub fn inlets(n: Context.Node) void {
        //     n.inlets(n.ptr);
        // }
        //
        // pub fn outlets(n: Context.Node) void {
        //     n.outlets(n.ptr);
        // }
    };

    pub fn Signal(comptime T: type) type {
        return struct {
            val: *T,
            src_node: *const Context.Node, // any kind of node?
        };
    }

    pub const ConcreteA = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteA",
        in: ?Context.Signal(f32) = null,
        out: ?Context.Signal(f32) = null,

        pub fn process(ptr: *anyopaque) void {
            const n: *Context.ConcreteA = @ptrCast(@alignCast(ptr));

            if (n.out == null) {
                // need to register node first to assign signal
                std.debug.print("Uh oh, there's no out for {s}\n", .{n.id});
                return;
            }

            if (n.in) |in| {
                n.out.?.val.* = in.val.* * 5.0;
            } else {
                n.out.?.val.* = 5.0;
            }
        }

        // TODO: NEXT: comptime inlets and outlets
        pub fn inlets(ptr: *anyopaque) void {
            return getInlets(ConcreteA, ptr);
        }

        pub fn outlets(ptr: *anyopaque) void {
            // TK
            _ = ptr;
            return;
        }

        pub fn node(self: *ConcreteA) Context.Node {
            return .{ .processFn = ConcreteA.process, .ptr = self, .inlet = &self.in, .outlet = &self.out, .id = self.id };
        }
    };

    fn getInlets(comptime T: anytype, ptr: *anyopaque) void {
        const node: *T = @ptrCast(@alignCast(ptr));
        _ = node;
        const fields = @typeInfo(T).Struct.fields;

        inline for (fields) |f| {
            if (std.mem.startsWith(u8, f.name, "in")) {
                std.debug.print("field: {}\n", .{f});
            }
        }
    }

    test "getInlets" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        const concrete_a = ConcreteA{ .ctx = &ctx };
        _ = concrete_a;
        //getInlets(ConcreteA, &concrete_a);
    }

    test "ConcreteA node interface" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = ConcreteA{ .ctx = &ctx };

        const node = concrete_a.node();
        const another_node = concrete_a.node();

        try testing.expectEqual(node, another_node);

        concrete_a.out = ctx.registerNode(&node);

        std.debug.print("concrete_a.out: {?}\n", .{concrete_a.out});

        try testing.expect(concrete_a.out != null);

        // confirm outlet points to same value
        try testing.expectEqual(node.outlet.*, concrete_a.out);
    }

    // TODO: get topologically sorted list of nodes
    pub fn refreshNodeList(ctx: *Context) !void {
        if (ctx.node_list) |nodes| {
            ctx.alloc.free(nodes);
        }
        var node_list = std.ArrayList(*const Context.Node).init(ctx.alloc);

        // reversing DFS for now, just to see if this works
        var curr_node: ?*const Context.Node = ctx.sink.?.src_node;
        var prev_node: ?*const Context.Node = null;

        while (curr_node) |n| {
            try node_list.append(n);

            prev_node = n;

            if (n.inlet.*) |in_signal| {
                curr_node = in_signal.src_node;
            } else {
                curr_node = null;
            }
        }

        std.mem.reverse(*const Context.Node, node_list.items);

        ctx.node_list = try node_list.toOwnedSlice();
    }

    // TODO: NEXT: Node graph traversal, sort out shape of signals and nodes
    test "context getNodeList" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var node_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        const node_a_node = node_a.node();
        node_a.out = ctx.registerNode(&node_a_node);

        var node_b = Context.ConcreteA{ .ctx = &ctx, .id = "node_b", .in = node_a.out };
        const node_b_node = node_b.node();
        node_b.out = ctx.registerNode(&node_b_node);

        try testing.expect(node_b.out != null);

        ctx.sink = node_b.out;

        try ctx.refreshNodeList();

        try testing.expectEqualSlices(*const Context.Node, &.{ &node_a_node, &node_b_node }, ctx.node_list.?);
    }

    pub fn process(ctx: *Context) void {
        // for node in context graph, compute new values
        if (ctx.node_list) |list| {
            for (list) |node| {
                node.process();
            }
        }
    }

    test "process" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var node_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        const node_a_node = node_a.node();
        node_a.out = ctx.registerNode(&node_a_node);

        var node_b = Context.ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.out };
        const node_b_node = node_b.node();
        node_b.out = ctx.registerNode(&node_b_node);

        ctx.sink = node_b.out;

        try ctx.refreshNodeList();

        ctx.process();

        try testing.expectEqual(5, node_a.out.?.val.*);
        try testing.expectEqual(10, ctx.sink.?.val.*);
    }

    test "process_bench" {
        // about 1ms for 44_100 iterations through braindead graph, doesn't bode well.

        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var node_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        const node_a_node = node_a.node();
        node_a.out = ctx.registerNode(&node_a_node);

        var node_b = Context.ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.out };
        const node_b_node = node_b.node();
        node_b.out = ctx.registerNode(&node_b_node);

        ctx.sink = node_b.out;

        try ctx.refreshNodeList();

        ctx.process();

        try testing.expectEqual(5, node_a.out.?.val.*);
        try testing.expectEqual(10, ctx.sink.?.val.*);

        for (0..44_100) |_| {
            ctx.process();
        }
    }

    pub fn next(ctx: *Context) !f32 {

        // process all nodes
        ctx.process();

        // tick counter
        ctx.ticks += 1;
    }

    // TODO: unregistering, i guess
    // TODO: feels jank, maybe, keep thinking about this
    // Reserves space for node output in context scratch
    pub fn registerNode(ctx: *Context, node: *const Context.Node) Context.Signal(f32) {
        // TODO: assert type has process function with compatible signature

        const signal: Context.Signal(f32) = .{ .val = ctx.getListAddress(ctx.node_count), .src_node = node };

        ctx.node_count += 1;

        // node.out = signal;
        return signal;
    }

    test "registerNode" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();
        var node: ConcreteA = .{ .ctx = &ctx, .id = "test node" };
        const node_node = node.node();

        node.out = ctx.registerNode(&node_node);

        var node_b: ConcreteA = .{ .ctx = &ctx, .id = "second test node", .in = node.out };

        const node_b_node = node_b.node();
        node_b.out = ctx.registerNode(&node_b_node);

        node.node().process();
        node_b.node().process();

        try testing.expectEqual(25, ctx.scratch[1]);
    }

    fn getListAddress(ctx: Context, idx: usize) *f32 {
        return @constCast(&(ctx.scratch[idx]));
    }

    test "getListAddress" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        ctx.scratch[0] = 1;
        ctx.scratch[1] = 2;
        ctx.scratch[2] = 3;

        const two_ptr = ctx.getListAddress(1);

        two_ptr.* = 5;

        try testing.expectEqual(5, ctx.scratch[1]);
    }

    // TODO: NEXT: How do we build an interface for node structs?
    // needs to allow for
    // - abstract process()
    // - comptime calculated(?) inlet and outlet tracking
    // pub fn inlets(node: anytype) void {
    //     _ = node;
    // }

    pub const ConcreteB = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteB",
        in: ?Context.Signal(f32) = null,
        out: ?Context.Signal(f32) = null,
        _node: ?Context.Node = null,

        pub fn process(ptr: *anyopaque) void {
            const n: *Context.ConcreteB = @ptrCast(@alignCast(ptr));

            if (n.out == null) {
                // need to register node first to assign signal
                std.debug.print("Uh oh, there's no out for {s}\n", .{n.id});
                return;
            }

            if (n.in) |in| {
                n.out.?.val.* = in.val.* + 5.0;
            } else {
                n.out.?.val.* = 3.0;
            }
        }

        pub fn node(self: *ConcreteB) Context.Node {
            return .{ .processFn = ConcreteB.process, .ptr = self, .inlet = &self.in, .outlet = &self.out, .id = self.id };
        }
    };
};

test "new context" {
    const ctx = try Context.init(testing.allocator_instance.allocator());
    defer ctx.deinit();
}

// TODO: rename to something else?
pub const AudioContext = struct {
    sample_rate: u32,
    ticks: u64 = 0, // count of samples played

    sink: ?Signal(f32) = undefined,
    buf: [4]u8 = undefined,

    pub fn next(ctx: *AudioContext) f32 {
        ctx.ticks += 1;

        var result: f32 = undefined;
        if (ctx.sink) |signal| {
            result = signal.get();
        } else {
            result = 0.0;
        }

        ctx.buf = @bitCast(result);

        return result;
    }

    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        var ctx: *AudioContext = @ptrCast(@alignCast(ptr));

        // tick ctx
        _ = ctx.next();

        return ctx.buf[0..];
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(ptr: *AudioContext) sources.AudioSource {
        return .{ .ptr = ptr, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }
};

const wave = osc.Wavetable(1024, .sine);

// TODO: rename
pub const TestWavetableOscNode = struct {
    ctx: *const AudioContext,
    wavetable: []const f32 = &wave,
    pitch: Signal(f32) = .{ .static = 20.0 },
    amp: Signal(f32) = .{ .static = 1.0 },
    buf: [4]u8 = undefined,
    phase: f32 = 0,

    pub fn nextFn(ptr: *anyopaque) f32 {
        var n: *TestWavetableOscNode = @ptrCast(@alignCast(ptr));
        const len: f32 = @floatFromInt(n.wavetable.len);

        const lowInd: usize = @intFromFloat(@floor(n.phase));
        const highInd: usize = @intFromFloat(@mod(@ceil(n.phase), len));

        const fractional_distance: f32 = @rem(n.phase, 1);

        const result: f32 = std.math.lerp(n.wavetable[lowInd], n.wavetable[highInd], fractional_distance) * n.amp.get();

        // n.phase += @as(f32, @floatFromInt(n.wavetable.len)) * n.pitch.get() / @as(f32, @floatFromInt(n.ctx.sample_rate));
        n.phase = @as(f32, @floatFromInt(n.wavetable.len)) * n.pitch.get() * @as(f32, @floatFromInt(@mod(n.ctx.ticks, n.ctx.sample_rate))) / @as(f32, @floatFromInt(n.ctx.sample_rate));

        while (n.phase >= len) {
            n.phase -= len;
        }
        // store latest result
        n.buf = @bitCast(result);

        return result;
    }

    pub fn node(n: *TestWavetableOscNode) Node(f32) {
        return .{ .ptr = n, .nextFn = nextFn };
    }
};

const TestNode = struct {
    current: f32 = 0.0,
    ctx: ?*const AudioContext = null,

    pub fn nextFn(ptr: *anyopaque) f32 {
        var tn: *TestNode = @ptrCast(@alignCast(ptr));

        tn.current += 1.0;
        return @mod(tn.current, 10.0);
    }

    pub fn node(n: *TestNode) Node(f32) {
        return .{ .ptr = n, .nextFn = nextFn };
    }
};

// represents a generic processing step for audio, produces a Signal
pub fn Node(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        nextFn: *const fn (ptr: *anyopaque) T,

        const Self = @This();

        pub fn next(self: Self) T {
            return self.nextFn(self.ptr);
        }

        pub fn signal(n: Self) Signal(T) {
            return .{ .node = n };
        }
    };
}

const SignalValueTags = enum {
    static,
    node,
    ptr,
};

// Value provider for audio nodes
pub fn Signal(comptime T: type) type {
    return union(SignalValueTags) {
        static: T,
        node: Node(T),
        ptr: *const T,

        const Self = @This();

        pub fn get(s: Self) T {
            return switch (s) {
                .static => |val| val,
                .node => |n| n.next(),
                .ptr => |ptr| ptr.*,
            };
        }
    };
}

test "Node" {
    var test_node = TestNode{};
    var node = test_node.node();

    try testing.expectEqual(1.0, node.next());
    try testing.expectEqual(2.0, node.next());
}

test "Signal" {
    const static_signal: Signal(f32) = .{ .static = 2.0 };
    try testing.expectEqual(2.0, static_signal.get());
    try testing.expectEqual(2.0, static_signal.get());

    var test_node = TestNode{};
    var node = test_node.node();
    var src_signal: Signal(f32) = node.signal();

    try testing.expectEqual(1.0, src_signal.get());
    try testing.expectEqual(2.0, src_signal.get());
    try testing.expectEqual(3.0, src_signal.get());
    try testing.expectEqual(4.0, src_signal.get());

    var val: f32 = 1.0;
    const ptr_signal: Signal(f32) = .{ .ptr = &val };

    try testing.expectEqual(1.0, ptr_signal.get());

    val = 5.0;
    try testing.expectEqual(5.0, ptr_signal.get());
}

test "Signal w/ context" {
    var context = AudioContext{
        .sample_rate = 44_100,
        .ticks = 0,
        .sink = null,
    };
    var node = TestNode{ .ctx = &context };

    var n = node.node();

    const src_signal: Signal(f32) = n.signal();

    context.sink = src_signal;

    try testing.expectEqual(1.0, context.next());
    try testing.expectEqual(2.0, context.next());
    try testing.expectEqual(3.0, context.next());
    try testing.expectEqual(4.0, context.next());
}
