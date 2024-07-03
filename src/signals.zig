const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const osc = @import("sources/osc.zig");
const sources = @import("sources/main.zig");

const dsp = @import("dsp.zig");

pub const Context = struct {
    alloc: std.mem.Allocator,
    scratch: []f32,
    node_list: ?[]*Node = null, // why is this optional lol ////// Actually, why not just a static array?
    // TODO: what's the value of optional signals? maybe replace with static defaults across the board?
    sink: ?Signal = null, // why optional? could just be a static default val instead
    sample_rate: u32 = 44_100,
    inv_sample_rate: f32 = 1.0 / 44_100.0,
    ticks: u64 = 0,
    node_count: u16 = 0,

    tmp: [4]u8 = undefined,

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

    // Temp compatibility stuff
    pub fn nextFn(ptr: *anyopaque) ?[]u8 {
        var ctx: *Context = @ptrCast(@alignCast(ptr));

        const val = ctx.next();
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
        in: ?Context.Signal = null,
        out: ?Context.Signal = null,

        pub const ins = [_]std.meta.FieldEnum(ConcreteA){.in};
        pub const outs = [_]std.meta.FieldEnum(ConcreteA){.out};

        pub fn process(ptr: *anyopaque) void {
            const n: *Context.ConcreteA = @ptrCast(@alignCast(ptr));

            if (n.out == null) {
                // need to register node first to assign signal
                std.debug.print("Uh oh, there's no out for {s}\n", .{n.id});
                return;
            }

            const in = blk: {
                if (n.in) |in| {
                    break :blk in.get();
                }
                break :blk 1.0;
            };

            n.out.?.set(in * 5.0);
        }

        pub fn node(self: *ConcreteA) Node {
            return Node.init(self, ConcreteA);
        }
    };

    pub const ConcreteSink = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteSink",
        inputs: std.ArrayList(?Context.Signal),
        out: ?Context.Signal = null,

        pub const ins = [_]std.meta.FieldEnum(ConcreteSink){.inputs};
        pub const outs = [_]std.meta.FieldEnum(ConcreteSink){.out};

        // use ctx.alloc for now
        pub fn init(ctx: *Context) !ConcreteSink {
            const inputs = std.ArrayList(?Context.Signal).init(ctx.alloc);
            return .{
                .ctx = ctx,
                .inputs = inputs,
            };
        }

        pub fn deinit(self: *ConcreteSink) void {
            self.inputs.deinit();
        }

        pub fn process(ptr: *anyopaque) void {
            const sink: *ConcreteSink = @ptrCast(@alignCast(ptr));

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

        pub fn node(self: *ConcreteSink) Node {
            return Node.init(self, ConcreteSink);
        }
    };

    test "sink node" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var sink = try ConcreteSink.init(&ctx);
        defer sink.deinit();
        var sink_node = sink.node();

        _ = try ctx.registerNode(&sink_node);

        try testing.expect(sink.out != null);

        try sink.inputs.append(.{ .static = 1.0 });
        try sink.inputs.append(.{ .static = 3.0 });
        try sink.inputs.append(.{ .static = 8.0 });

        // confirm outlet points to same value
        try testing.expectEqual(sink_node.outs()[0].single, &sink.out);

        sink_node.process();

        try testing.expectEqual(4.0, sink_node.outs()[0].single.*.?.get());
    }

    test "ConcreteA node interface" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = ConcreteA{ .ctx = &ctx };
        var node = concrete_a.node();

        concrete_a.out = try ctx.registerNode(&node);

        try testing.expect(concrete_a.out != null);

        // confirm outlet points to same value
        try testing.expectEqual(node.outs()[0].single, &concrete_a.out);

        // test assignment
        node.port("out").single.* = .{ .ptr = .{
            .val = @as(*f32, @ptrFromInt(0xDEADBEEF + 1)),
            .src_node = &node,
        } };
    }

    // TODO: NEXT: actually high time to navigate the node graph correctly
    // get topologically sorted list of nodes
    pub fn refreshNodeList(ctx: *Context) !void {
        if (ctx.node_list) |nodes| {
            ctx.alloc.free(nodes);
        }
        var node_list = std.ArrayList(*Node).init(ctx.alloc);

        // reversing DFS for now, just to see if this works
        if (ctx.sink == null) {
            return;
        }
        var curr_node: ?*Node = ctx.sink.?.source();
        var prev_node: ?*Node = null;

        while (curr_node) |n| {
            try node_list.append(n);

            prev_node = n;

            for (n.ins()) |let| {
                switch (let) {
                    .single => |maybe_in| {
                        if (maybe_in.*) |in_signal| {
                            curr_node = in_signal.source();
                            break;
                        } else {
                            curr_node = null;
                        }
                    },
                    .list => |list| {
                        for (list.items) |maybe_sig| {
                            if (maybe_sig) |sig| {
                                // check for node presence before slapping onto node list
                                if (!std.mem.containsAtLeast(*Node, node_list.items, 1, &.{sig.source().?})) {
                                    try node_list.append(sig.source().?);
                                }
                            }
                            curr_node = null;
                        }
                    },
                }
            }
        }

        std.mem.reverse(*const Node, node_list.items);

        ctx.node_list = try node_list.toOwnedSlice();
    }

    // TODO:  Node graph traversal, sort out shape of signals and nodes
    test "context getNodeList" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();

        _ = try ctx.registerNode(&node_a);

        var concrete_b = Context.ConcreteA{ .ctx = &ctx, .id = "node_b", .in = node_a.outs()[0].single.* };
        var node_b = concrete_b.node();

        concrete_b.out = try ctx.registerNode(&node_b);

        try testing.expect(node_b.outs()[0].single.* != null);

        ctx.sink = node_b.outs()[0].single.*;

        try ctx.refreshNodeList();

        try testing.expectEqualSlices(*const Node, &.{ &node_a, &node_b }, ctx.node_list.?);
    }

    pub fn process(ctx: *Context, should_print: bool) void {
        // for node in context graph, compute new values
        if (ctx.node_list) |list| {
            for (list) |node| {
                node.process();
                if (should_print == true) {
                    const out = node.outs()[0];

                    const out_val = switch (out) {
                        .single => |val| val.*.?.get(),
                        else => unreachable, // there shouldnt be any list-shaped outputs
                    };

                    std.debug.print("processing node {s}:\noutput:\t{}\n\n", .{ node.id, out_val });
                }
            }
        }
    }

    test "process" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

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

        var sink = try Context.ConcreteSink.init(&ctx);
        defer sink.deinit();
        var sink_node = sink.node();

        try sink.inputs.append(concrete_a.out);
        try sink.inputs.append(concrete_b.out);
        try sink.inputs.append(oscillator.out);

        _ = try ctx.registerNode(&sink_node);

        ctx.sink = sink_node.port("out").single.*;

        try ctx.refreshNodeList();
        std.debug.print("node list: ", .{});
        for (ctx.node_list.?) |node| {
            std.debug.print("{s}, ", .{node.*.id});
        }
        std.debug.print("\n", .{});

        ctx.process(true);

        try testing.expectEqual(5, node_a.port("out").single.*.?.get()); // TODO: goodness gracious would you look at this nonsense
        try testing.expectEqual(5, ctx.sink.?.get());
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

        return ctx.sink.?.get();
    }

    // TODO: unregistering, i guess
    // TODO: feels jank, maybe, keep thinking about this
    // Reserves space for node output in context scratch
    pub fn registerNode(ctx: *Context, node: *Node) !Signal {
        // TODO: assert type has process function with compatible signature

        const signal: Signal = .{ .ptr = .{ .val = ctx.getListAddress(ctx.node_count), .src_node = node } };

        ctx.node_count += 1;

        node.out(0).single.* = signal;

        if (ctx.sink == null) {
            ctx.sink = signal;
        }

        try refreshNodeList(ctx);
        return signal;
    }

    test "registerNode" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();

        _ = try ctx.registerNode(&node_a);

        var concrete_b = ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.outs()[0].single.* };
        var node_b = concrete_b.node();

        concrete_b.out = try ctx.registerNode(&node_b);

        node_a.process(); // x * 5
        node_b.process(); // in * multi + 5

        try testing.expectEqual(5, ctx.scratch[0]);
        try testing.expectEqual(10, ctx.scratch[1]);
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

    pub const ConcreteB = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteB",
        in: ?Signal = null,
        multiplier: ?Signal = null,
        out: ?Signal = null,

        pub const ins = [_]std.meta.FieldEnum(ConcreteB){ .in, .multiplier };
        pub const outs = [_]std.meta.FieldEnum(ConcreteB){.out};

        pub fn process(ptr: *anyopaque) void {
            const n: *ConcreteB = @ptrCast(@alignCast(ptr));

            if (n.out == null) {
                // need to register node first to assign signal
                std.debug.print("Uh oh, there's no out for {s}\n", .{n.id});
                return;
            }

            const multi = blk: {
                if (n.multiplier) |m| {
                    break :blk m.get();
                }
                break :blk 1.0;
            };

            const in = blk: {
                if (n.in) |in| {
                    break :blk in.get();
                }
                break :blk 1.0;
            };

            n.out.?.set(in * multi + 5.0);
        }

        pub fn node(self: *ConcreteB) Node {
            return Node.init(self, ConcreteB);
        }
    };
};

test "new context" {
    const ctx = try Context.init(testing.allocator_instance.allocator());
    defer ctx.deinit();
}

pub fn Let(T: type) type {
    return union(enum) {
        single: *T,
        list: *std.ArrayList(T),

        const Self = @This();

        pub fn get(s: Self, idx: ?usize) *T {
            const n = idx orelse 0;
            return switch (s) {
                .single => |val| val,
                .list => |list| &list.items[n],
            };
        }
    };
}

pub const Node = struct {
    id: []const u8 = "x",
    num_inlets: u8 = undefined,
    num_outlets: u8 = undefined,
    inlets: [8]Portlet = undefined,
    outlets: [8]Portlet = undefined,
    ptr: *anyopaque,
    processFn: *const fn (*anyopaque) void,
    portletFn: *const fn (*anyopaque, []const u8) Portlet,

    const Portlet = Let(?Signal);

    pub fn init(ptr: *anyopaque, T: type) Node {
        const concrete: *T = @ptrCast(@alignCast(ptr));
        const P = Ports(T, ?Signal);
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

        std.mem.copyForwards(Portlet, node.inlets[0..], p_ins[0..]);
        std.mem.copyForwards(Portlet, node.outlets[0..], p_outs[0..]);

        return node;
    }

    pub fn process(n: Node) void {
        n.processFn(n.ptr);
    }

    pub fn ins(n: *Node) []Portlet {
        return n.inlets[0..n.num_inlets];
    }

    pub fn in(n: Node, idx: usize) Portlet {
        // assert idx no greater than inlet count
        return n.inlets[idx];
    }

    pub fn out(n: Node, idx: usize) Portlet {
        // assert idx no greater than inlet count
        return n.outlets[idx];
    }

    pub fn outs(n: *Node) []Portlet {
        return n.outlets[0..n.num_outlets];
    }

    pub fn port(n: Node, field_name: []const u8) Portlet {
        return n.portletFn(n.ptr, field_name);
    }
};

//TODO: distinguish between ptrs and node-derived signals
pub const Signal = union(enum) {
    ptr: struct { val: *f32, src_node: *Node },
    static: f32,

    pub fn get(s: Signal) f32 {
        return switch (s) {
            .ptr => |ptr_s| ptr_s.val.*,
            .static => |val| val,
        };
    }

    pub fn set(s: Signal, v: f32) void {
        switch (s) {
            .ptr => |ptr_s| {
                ptr_s.val.* = v;
            },
            .static => {
                return;
            },
        }
    }

    pub fn source(s: Signal) ?*Node {
        return switch (s) {
            .ptr => |ptr_s| ptr_s.src_node,
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

    // Placeholder
    //const S = ?Context.Signal(f32);

    return struct {
        t: *T,

        const Self = @This();
        const FE = std.meta.FieldEnum(T);
        pub const L = Let(S);

        pub fn ins(ptr: *anyopaque) [T.ins.len]L {
            var t: *T = @ptrCast(@alignCast(ptr));
            var buf: [T.ins.len]L = undefined;

            inline for (T.ins, 0..) |port, idx| {
                const field_ptr = &@field(t, @tagName(port));
                buf[idx] = switch (std.meta.FieldType(T, port)) {
                    S => .{ .single = field_ptr },
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

    // TODO: workshop
    // var ins_buf: [8]P.L = undefined;
    // try testing.expectEqualSlices(*const []const u8, &.{ &node.in_one, &node.in_two, &node.in_three }, P.ins(&node, &ins_buf));
    //
    try testing.expectEqual(@TypeOf(P.getPtr(&node, .out_back)), *[]const u8);
    try testing.expectEqual(@TypeOf(P.getPtr(&node, .steak_house)), *f32);

    const in_two = P.get(&node, "in_two");
    in_two.single.* = P.getOut(&node, 0).*;

    try testing.expectEqual(P.getPtr(&node, .in_two).*, P.getPtr(&node, .out_back).*);
}
