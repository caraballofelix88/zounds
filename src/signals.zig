const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const sources = @import("sources/main.zig");
const dsp = @import("dsp/dsp.zig");

const MAX_NODE_COUNT = 64;
const SCRATCH_BYTES = 1024;
const NODE_PORTLET_COUNT = 8;
const CHANNEL_COUNT = 1;

// TODO: Thought: better to enforce memory limits in static arrays?
// Would it instead make more sense to reserve a huge chunk of memory upfront and allocate to it with a FixedBufferAllocator?
// Feels like the same thing with more work
// Allows for more flexible allocation in the future

pub const Context = struct {
    // alloc: std.mem.Allocator,
    scratch: [SCRATCH_BYTES]f32 = std.mem.zeroes([SCRATCH_BYTES]f32),
    node_store: [MAX_NODE_COUNT]Node = undefined,
    node_process_list: [MAX_NODE_COUNT]*Node = undefined,
    sink: Signal = .{ .static = 0.0 },
    sample_rate: u32 = 44_100,
    inv_sample_rate: f32 = 1.0 / 44_100.0,
    ticks: u64 = 0,
    node_count: u16 = 0,

    // TODO: just one channel's worth of output
    // Context should be aware of output format (channel count)
    tmp: [4 * CHANNEL_COUNT]u8 = undefined,

    // Temp compatibility stuff
    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        var ctx: *Context = @ptrCast(@alignCast(ptr));

        const val = std.math.clamp(ctx.next(), -1.0, 1.0);
        ctx.tmp = std.mem.toBytes(val);

        return &ctx.tmp;
    }

    pub fn hasNextFn(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    pub fn source(ptr: *Context) sources.AudioSource {
        return .{ .ptr = ptr, .nextFn = nextFn, .hasNextFn = hasNextFn };
    }

    pub const ConcreteA = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteA",
        in: Signal = .{ .static = 1.0 },
        out: Signal = .{ .static = 0.0 },

        pub const ins = [_]std.meta.FieldEnum(ConcreteA){.in};
        pub const outs = [_]std.meta.FieldEnum(ConcreteA){.out};

        pub fn process(ptr: *anyopaque) void {
            const n: *Context.ConcreteA = @ptrCast(@alignCast(ptr));

            n.out.set(n.in.get() * 5.0);
        }

        pub fn node(self: *ConcreteA) Node {
            return Node.init(self, ConcreteA);
        }
    };

    pub const ConcreteSink = struct {
        ctx: *Context,
        alloc: std.mem.Allocator,
        id: []const u8 = "ConcreteSink",
        inputs: std.ArrayList(Signal),
        out: Signal = .{ .static = 0.0 },

        pub const ins = [_]std.meta.FieldEnum(ConcreteSink){.inputs};
        pub const outs = [_]std.meta.FieldEnum(ConcreteSink){.out};

        pub fn init(ctx: *Context, alloc: std.mem.Allocator) !ConcreteSink {
            const inputs = std.ArrayList(Signal).init(alloc);
            return .{
                .ctx = ctx,
                .alloc = alloc,
                .inputs = inputs,
            };
        }

        pub fn deinit(self: *ConcreteSink) void {
            self.inputs.deinit();
        }

        pub fn process(ptr: *anyopaque) void {
            const sink: *ConcreteSink = @ptrCast(@alignCast(ptr));

            var result: f32 = undefined;
            var input_count: u8 = 0;

            for (sink.inputs.items) |in| {
                result += in.get();
                input_count += 1;
            }

            result /= @floatFromInt(@max(input_count, 1));
            sink.out.set(result);
        }

        pub fn node(self: *ConcreteSink) Node {
            return Node.init(self, ConcreteSink);
        }
    };

    test "sink node" {
        var ctx = Context{};

        var sink = try ConcreteSink.init(&ctx, testing.allocator);
        defer sink.deinit();
        var sink_node = sink.node();

        _ = try ctx.registerNode(&sink_node);

        try sink.inputs.append(.{ .static = 1.0 });
        try sink.inputs.append(.{ .static = 3.0 });
        try sink.inputs.append(.{ .static = 8.0 });

        // confirm outlet points to same value
        try testing.expectEqual(sink_node.out(0).single, &sink.out);

        sink_node.process();

        try testing.expectEqual(4.0, sink_node.out(0).single.*.get());
    }

    test "ConcreteA node interface" {
        var ctx = Context{};

        var concrete_a = ConcreteA{ .ctx = &ctx };
        var node = concrete_a.node();

        concrete_a.out = try ctx.registerNode(&node);

        // confirm outlet points to same value
        try testing.expectEqual(node.outs()[0].single, &concrete_a.out);

        // test assignment
        node.port("out").single.* = .{ .ptr = .{
            .val = @as(*f32, @ptrFromInt(0xDEADBEEF + 1)),
            .src_node = &node,
        } };
    }

    // TODO: check for cycles
    //
    // Builds a list of pointers for nodes in context store, sorted topographically via Kahn's algorithm.
    // https://en.wikipedia.org/wiki/Topological_sorting
    //
    // Pointer list is built in ctx.node_process_list
    pub fn buildProcessList(ctx: *Context) !void {
        var queue = std.fifo.LinearFifo(*Node, .{ .Static = MAX_NODE_COUNT }).init();
        var indegrees: [MAX_NODE_COUNT]u8 = .{0} ** MAX_NODE_COUNT;
        var sorted_idx: u8 = 0;

        // std.debug.print("Rebuilding processing list...\n", .{});

        for (0..ctx.node_count) |idx| {
            var node = ctx.getHandleSource(idx);
            for (node.ins()) |inlet| {
                switch (inlet) {
                    .single => |single| {
                        if (single.* == .handle) {
                            indegrees[idx] += 1;
                        }
                    },
                    .list => |list| {
                        for (list.items) |i| {
                            if (i == .handle) {
                                indegrees[idx] += 1;
                            }
                        }
                    },
                    else => {},
                }
            }

            if (indegrees[idx] == 0) {
                try queue.writeItem(node);
            }
        }

        while (queue.readItem()) |n| {
            ctx.node_process_list[sorted_idx] = n;
            sorted_idx += 1;

            // std.debug.print("Adding node {s} to {} place:\n", .{ n.id, sorted_idx });

            // for each outlet, go through node store to find linked nodes
            // TODO: iterating through the full node list each time we wanna find linked outputs for sure needlessly expensive,
            // but its whatever for now. processing some kind of adjacency matrix upfront and using that maybe makes more sense
            for (n.outs()) |out| {
                for (0..ctx.node_count) |idx| {
                    var adj_node = ctx.getHandleSource(idx);

                    for (adj_node.ins()) |in_port| {
                        const in_signals: []const Signal = switch (in_port) {
                            .single => |in_single| &.{in_single.*},
                            .list => |in_list| in_list.items,
                            else => unreachable,
                        };

                        for (in_signals) |in_item| {
                            if (std.meta.eql(out.single.*, in_item)) {
                                // std.debug.print("Connection: {s} -> {s}\n", .{ n.id, adj_node.id });

                                indegrees[idx] -= 1;
                                if (indegrees[idx] == 0) {
                                    try queue.writeItem(adj_node);
                                }
                            }
                        }
                    }
                }
            }
        }

        if (sorted_idx < ctx.node_count) {
            std.debug.print("uh oh, somethings up. Likely cycle found.\n", .{});
        }
    }

    test "nodeDepSort" {
        // TODO: TK
    }

    pub fn printNodeList(ctx: *Context) void {
        std.debug.print("node list:\t", .{});
        for (0..ctx.node_count) |idx| {
            const n = ctx.node_process_list[idx];
            std.debug.print("{s}, ", .{n.id});
        }
        std.debug.print("\n", .{});
    }

    pub fn process(ctx: *Context, should_print: bool) void {
        // for node in context graph, compute new values
        for (0..ctx.node_count) |idx| {
            var node = ctx.node_process_list[idx];
            node.process();
            if (should_print == true) {
                const out = node.out(0);

                const out_val = switch (out) {
                    .single => |val| val.*.get(),
                    else => unreachable, // there shouldnt be any list-shaped outputs
                };

                std.debug.print("processing node {s}:\noutput:\t{}\n\n", .{ node.id, out_val });
            }
        }
    }

    test "process" {
        var ctx = Context{};

        var concrete_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();
        _ = try ctx.registerNode(&node_a);

        node_a.process();

        var concrete_b = Context.ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.port("out").single.* };
        var node_b = concrete_b.node();
        _ = try ctx.registerNode(&node_b);

        node_b.process();

        var oscillator = dsp.Oscillator{ .ctx = &ctx, .pitch = node_b.port("out").single.*, .amp = node_a.port("out").single.* };
        var osc_node = oscillator.node();
        _ = try ctx.registerNode(&osc_node);

        var sink = try Context.ConcreteSink.init(&ctx, testing.allocator);
        defer sink.deinit();
        var sink_node = sink.node();

        try sink.inputs.append(concrete_a.out);
        try sink.inputs.append(concrete_b.out);
        try sink.inputs.append(oscillator.out);

        _ = try ctx.registerNode(&sink_node);

        ctx.sink = sink_node.port("out").single.*;

        ctx.process(true);

        try testing.expectEqual(5, node_a.port("out").single.*.get()); // TODO: goodness gracious would you look at this nonsense
        try testing.expectEqual(5, ctx.sink.get());
        //
        // lil mini benchmark
        for (0..44_100) |_| {
            ctx.process(false);
            ctx.ticks += 1;
        }
    }

    pub fn next(ctx: *Context) f32 {

        // process all nodes
        ctx.process(false);

        // tick counter
        ctx.ticks += 1;

        return ctx.sink.get();
    }

    // TODO: unregistering, i guess
    // Reserves space for node and processing output in context
    pub fn registerNode(ctx: *Context, node: *Node) !Signal {
        // TODO: assert type has process function with compatible signature

        const store_signal: Signal = .{ .handle = .{ .idx = ctx.node_count, .ctx = ctx } };
        var n = node.*;
        n.out(0).single.* = store_signal;
        ctx.node_store[ctx.node_count] = n;

        ctx.node_count += 1;

        // re-sort node processing list
        try ctx.buildProcessList();

        return store_signal;
    }

    test "registerNode" {
        var ctx = Context{};

        var concrete_a = ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();

        _ = try ctx.registerNode(&node_a);

        var concrete_b = ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.out(0).single.* };
        var node_b = concrete_b.node();

        _ = try ctx.registerNode(&node_b);

        try testing.expectEqual(ctx.node_store[0], node_a);
        try testing.expectEqual(ctx.node_store[1], node_b);
    }

    fn getListAddress(ctx: *Context, idx: usize) *f32 {
        return &(ctx.scratch[idx]);
    }

    test "getListAddress" {
        var ctx = Context{};

        ctx.scratch[0] = 1;
        ctx.scratch[1] = 2;
        ctx.scratch[2] = 3;

        const two_ptr = ctx.getListAddress(1);

        two_ptr.* = 5;

        try testing.expectEqual(5, ctx.scratch[1]);
    }

    fn getHandleVal(ctx: *Context, idx: usize) f32 {
        return ctx.getListAddress(idx).*;
    }

    fn setHandleVal(ctx: *Context, idx: usize, val: f32) void {
        ctx.scratch[idx] = val;
    }

    fn getHandleSource(ctx: *Context, idx: usize) *Node {
        return @constCast(&ctx.node_store[idx]);
    }

    test "getHandleSource" {
        var ctx = Context{};

        var concrete_a = ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();

        _ = try ctx.registerNode(&node_a);

        var concrete_b = ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.outs()[0].single.* };
        var node_b = concrete_b.node();

        _ = try ctx.registerNode(&node_b);

        try testing.expectEqual(ctx.getHandleSource(0).*, node_a);
        try testing.expectEqual(ctx.getHandleSource(1).*, node_b);

        try testing.expectEqual(ctx.getHandleSource(1), &ctx.node_store[1]);
    }

    pub const ConcreteB = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteB",
        in: Signal = .{ .static = 1.0 },
        multiplier: Signal = .{ .static = 1.0 },
        out: Signal = .{ .static = 0.0 },

        pub const ins = [_]std.meta.FieldEnum(ConcreteB){ .in, .multiplier };
        pub const outs = [_]std.meta.FieldEnum(ConcreteB){.out};

        pub fn process(ptr: *anyopaque) void {
            const n: *ConcreteB = @ptrCast(@alignCast(ptr));

            n.out.set(n.in.get() * n.multiplier.get() + 5.0);
        }

        pub fn node(self: *ConcreteB) Node {
            return Node.init(self, ConcreteB);
        }
    };
};

// TODO: unsatisfied with this dynamically sized outlet list stuff.
// Figure out alternative before it permeates through too much of the workings
//
//
pub fn Portlet(T: type) type {
    return union(enum) {
        single: *T,
        maybe: *?T,
        list: *std.ArrayList(T),

        const Self = @This();

        pub fn get(s: Self, idx: ?usize) *T {
            const n = idx orelse 0;
            return switch (s) {
                .single => |val| val,
                .maybe => |maybe_val| maybe_val.?,
                .list => |list| &list.items[n],
            };
        }
    };
}

pub const Node = struct {
    id: []const u8 = "x",
    num_inlets: u8 = undefined,
    num_outlets: u8 = undefined,
    inlets: [NODE_PORTLET_COUNT]NodePortlet = undefined,
    outlets: [NODE_PORTLET_COUNT]NodePortlet = undefined,
    ptr: *anyopaque,
    processFn: *const fn (*anyopaque) void,
    portletFn: *const fn (*anyopaque, []const u8) NodePortlet,

    const NodePortlet = Portlet(Signal);

    pub fn init(ptr: *anyopaque, T: type) Node {
        const concrete: *T = @ptrCast(@alignCast(ptr));
        const P = Ports(T, Signal);
        var node: Node = .{
            .ptr = ptr,
            .id = concrete.id,
            .processFn = &T.process,
            .portletFn = &P.get,
        };

        const p_ins = P.ins(ptr);
        const p_outs = P.outs(ptr);

        node.num_inlets = p_ins.len;
        node.num_outlets = p_outs.len;

        std.mem.copyForwards(NodePortlet, node.inlets[0..], p_ins[0..]);
        std.mem.copyForwards(NodePortlet, node.outlets[0..], p_outs[0..]);

        return node;
    }

    pub fn process(n: Node) void {
        n.processFn(n.ptr);
    }

    pub fn ins(n: *Node) []NodePortlet {
        return n.inlets[0..n.num_inlets];
    }

    pub fn in(n: Node, idx: usize) NodePortlet {
        // TODO: assert idx no greater than inlet count
        return n.inlets[idx];
    }

    pub fn out(n: Node, idx: usize) NodePortlet {
        // TODO: assert idx no greater than inlet count
        return n.outlets[idx];
    }

    pub fn outs(n: *Node) []NodePortlet {
        return n.outlets[0..n.num_outlets];
    }

    pub fn port(n: Node, field_name: []const u8) NodePortlet {
        return n.portletFn(n.ptr, field_name);
    }
};

pub const Signal = union(enum) {
    ptr: *f32,
    handle: struct { idx: u16, ctx: *Context },
    static: f32,

    pub fn get(s: Signal) f32 {
        return switch (s) {
            .ptr => |ptr| ptr.*,
            .handle => |handle| handle.ctx.getHandleVal(handle.idx),
            .static => |val| val,
        };
    }

    pub fn set(s: Signal, v: f32) void {
        switch (s) {
            .ptr => |ptr| {
                ptr.* = v;
            },
            .handle => |handle| {
                handle.ctx.setHandleVal(handle.idx, v);
            },
            .static => {
                return;
            },
        }
    }

    pub fn source(s: Signal) ?*Node {
        return switch (s) {
            .ptr => null,
            .handle => |handle| handle.ctx.getHandleSource(handle.idx),
            .static => null,
        };
    }
};

// https://zigbin.io/9222cb
// shoutouts to Francis on the forums

pub fn Ports(comptime T: anytype, comptime S: anytype) type {
    // Serves as an interface to a concrete class's input and output.
    // Upstream types must designate which fields are input and output data through
    // FieldEnum arrays.

    // S type designates the expected type for inputs and outputs. For now, all inputs and outputs are expected to
    // be the same type, because I can't quite figure out how to make lists of heterogeneous pointers work ergonomically at runtime.
    // eg. how do we provide Signal types that don't care what their Child type is?
    // idea: Signals as union types, like before

    return struct {
        t: *T,

        const Self = @This();
        const FE = std.meta.FieldEnum(T);
        pub const L = Portlet(S);

        pub fn ins(ptr: *anyopaque) [T.ins.len]L {
            var t: *T = @ptrCast(@alignCast(ptr));
            var buf: [T.ins.len]L = undefined;

            inline for (T.ins, 0..) |port, idx| {
                const field_ptr = &@field(t, @tagName(port));
                buf[idx] = switch (std.meta.FieldType(T, port)) {
                    S => .{ .single = field_ptr },
                    ?S => .{ .maybe = field_ptr },
                    std.ArrayList(S) => .{ .list = field_ptr },
                    else => unreachable,
                };
            }

            return buf;
        }

        pub fn outs(ptr: *anyopaque) [T.outs.len]L {
            var t: *T = @ptrCast(@alignCast(ptr));
            var buf: [T.outs.len]L = undefined;

            inline for (T.outs, 0..) |port, idx| {
                const field_ptr = &@field(t, @tagName(port));
                buf[idx] = switch (std.meta.FieldType(T, port)) {
                    S => .{ .single = field_ptr },
                    ?S => .{ .maybe = field_ptr },

                    std.ArrayList(S) => .{ .list = field_ptr },
                    else => unreachable,
                };
            }

            return buf;
        }

        pub fn get(ptr: *anyopaque, field_str: []const u8) L {
            const t: *T = @ptrCast(@alignCast(ptr));

            inline for (T.ins) |in| {
                if (std.mem.eql(u8, @tagName(in), field_str)) {
                    const field_ptr = &@field(t, @tagName(in));

                    return switch (std.meta.FieldType(T, in)) {
                        S => .{ .single = field_ptr },
                        ?S => .{ .maybe = field_ptr },
                        std.ArrayList(S) => .{ .list = field_ptr },
                        else => unreachable,
                    };
                }
            }

            inline for (T.outs) |out| {
                if (std.mem.eql(u8, @tagName(out), field_str)) {
                    const field_ptr = &@field(t, @tagName(out));

                    return switch (std.meta.FieldType(T, out)) {
                        S => .{ .single = field_ptr },
                        ?S => .{ .maybe = field_ptr },
                        std.ArrayList(S) => .{ .list = field_ptr },
                        else => unreachable,
                    };
                }
            }

            unreachable;
        }

        pub fn getIn(ptr: *anyopaque, comptime idx: usize) *std.meta.FieldType(T, T.ins[idx]) {
            const t: *T = @ptrCast(@alignCast(ptr));

            return &@field(t, @tagName(T.ins[idx]));
        }

        pub fn getOut(ptr: *anyopaque, comptime idx: usize) *std.meta.FieldType(T, T.outs[idx]) {
            const t: *T = @ptrCast(@alignCast(ptr));

            return &@field(t, @tagName(T.outs[idx]));
        }

        pub fn getPtr(ptr: *anyopaque, comptime fe: FE) *std.meta.FieldType(T, fe) {
            const t: *T = @ptrCast(@alignCast(ptr));
            return &@field(t, @tagName(fe));
        }
    };
}

test "Ports" {
    const PortNode = struct {
        in_one: []const u8 = "1",
        in_two: []const u8 = "2",
        in_three: []const u8 = "3",
        drive_in: []const u8 = "no",
        out_back: []const u8 = "yes",
        steak_house: f32 = 9999.0,

        pub const ins = [_]std.meta.FieldEnum(@This()){ .in_one, .in_two, .in_three };
        pub const outs = [_]std.meta.FieldEnum(@This()){.out_back};
    };
    var node = PortNode{};

    const P = Ports(PortNode, []const u8);

    // TODO: this could use more tests

    // getPtr
    try testing.expectEqual(@TypeOf(P.getPtr(&node, .out_back)), *[]const u8);
    try testing.expectEqual(&node.out_back, P.getPtr(&node, .out_back));
    try testing.expectEqual(@TypeOf(P.getPtr(&node, .steak_house)), *f32);
    try testing.expectEqual(&node.steak_house, P.getPtr(&node, .steak_house));
}
