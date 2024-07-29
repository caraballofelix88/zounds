const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const dsp = @import("dsp/dsp.zig");

const MAX_NODE_COUNT = 64;
const SCRATCH_SIZE = 1024;
const MAX_PORT_COUNT = 8;
const CHANNEL_COUNT = 2;

// TODO: handles prolly just need const pointers to an extant context, not a new object every time
pub const HandleTag = enum { node, signal };
pub const Handle = struct {
    tag: HandleTag,
    idx: u16,
    node_idx: ?u16 = null, // bookkeeping for signal source nodes
    ctx: GraphContext,
    gen: u8 = 0,

    pub inline fn valid(hdl: Handle) bool {
        // this switch could live inside the context as some get_gen() func, prolly
        const gen_slice = switch (hdl.tag) {
            .node => hdl.ctx.node_gen(),
            .signal => hdl.ctx.signal_gen(),
        };

        return gen_slice[hdl.idx] <= hdl.gen;
    }
};

pub const Error = error{ NoMoreNodeSpace, OtherError, BadProcessList, NodeGraphCycleDetected };
pub const GraphContext = struct {
    ptr: *anyopaque,
    opts: Options,
    sample_rate: u32,
    inv_sample_rate: f32,
    vtable: *const VTable,

    pub const VTable = struct {
        register: *const fn (*anyopaque, Node) Error!*Node,
        deregister: *const fn (*anyopaque, Handle) Error!void,
        connect: *const fn (*anyopaque, Portlet(Signal), Portlet(Signal)) Error!void,
        next: *const fn (*anyopaque) []f32, // how to push multi-channel?
        getHandleVal: *const fn (*anyopaque, usize, u8) f32,
        setHandleVal: *const fn (*anyopaque, usize, f32) void,
        getHandleSource: *const fn (*anyopaque, usize) *Node,

        getSignal: *const fn (*anyopaque, Handle) f32,
        getSignalSource: *const fn (*anyopaque, Handle) ?*Node,
        setSignal: *const fn (*anyopaque, Handle, f32) void,
        getNode: *const fn (*anyopaque, Handle) ?*Node,

        ticks: *const fn (*anyopaque) u64,
        node_gen: *const fn (*anyopaque) []u8,
        signal_gen: *const fn (*anyopaque) []u8,
    };

    pub fn register(self: GraphContext, node_ptr: anytype) !*Node {
        const T = @typeInfo(@TypeOf(node_ptr));

        std.debug.assert(T == .Pointer);

        // TODO: assert type has process function with compatible signature
        const ChildType = T.Pointer.child;

        const node = Node.init(node_ptr, ChildType);

        return try self.vtable.register(self.ptr, node);
    }

    pub fn deregister(self: GraphContext, hdl: Handle) !void {
        try self.vtable.deregister(self.ptr, hdl);
    }

    pub fn connect(self: GraphContext, dest: Portlet(Signal), val: Portlet(Signal)) !void {
        try self.vtable.connect(self.ptr, dest, val);
    }

    pub fn next(self: GraphContext) []f32 {
        return self.vtable.next(self.ptr);
    }

    pub fn getHandleVal(self: GraphContext, idx: usize, gen: u8) f32 {
        return self.vtable.getHandleVal(self.ptr, idx, gen);
    }
    pub fn setHandleVal(self: GraphContext, idx: usize, val: f32) void {
        self.vtable.setHandleVal(self.ptr, idx, val);
    }

    pub fn getHandleSource(self: GraphContext, idx: usize) *Node {
        return self.vtable.getHandleSource(self.ptr, idx);
    }

    pub inline fn ticks(self: GraphContext) u64 {
        return self.vtable.ticks(self.ptr);
    }

    pub inline fn node_gen(self: GraphContext) []u8 {
        return self.vtable.node_gen(self.ptr);
    }

    pub inline fn signal_gen(self: GraphContext) []u8 {
        return self.vtable.signal_gen(self.ptr);
    }
};

pub const Options = struct {
    max_node_count: u8 = MAX_NODE_COUNT,
    scratch_size: u16 = SCRATCH_SIZE,
    channel_count: u8 = 2,
};
// TODO: contexts as nodes themselves?
pub fn Graph(comptime opts: Options) type {
    return struct {
        scratch: [opts.scratch_size]f32 = std.mem.zeroes([opts.scratch_size]f32),
        scratch_gen: [opts.scratch_size]u8 = std.mem.zeroes([opts.scratch_size]u8),
        scratch_free_list: std.fifo.LinearFifo(u16, .{ .Static = opts.scratch_size }) = std.fifo.LinearFifo(u16, .{ .Static = opts.scratch_size }).init(),
        node_store: [opts.max_node_count]Node = undefined,
        node_gen: [opts.max_node_count]u8 = std.mem.zeroes([opts.max_node_count]u8),
        node_free_list: std.fifo.LinearFifo(u16, .{ .Static = opts.max_node_count }) = std.fifo.LinearFifo(u16, .{ .Static = opts.max_node_count }).init(),
        node_process_list: [opts.max_node_count]*Node = undefined,
        root_signal: Signal = .{ .static = 0.0 },
        format: main.FormatData,
        ticks: u64 = 0,
        node_count: u16 = 0,

        // Holds the last sample frame
        sink: [opts.channel_count]f32 = undefined,

        pub const Self = @This();

        pub fn node_gen(ptr: *anyopaque) []u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));

            return self.node_gen[0..];
        }

        pub fn signal_gen(ptr: *anyopaque) []u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));

            return self.scratch_gen[0..];
        }

        pub fn context(self: *Self) GraphContext {
            return .{
                .ptr = self,
                .opts = opts,
                .sample_rate = self.format.sample_rate,
                .inv_sample_rate = self.format.invSampleRate(),
                .vtable = &.{
                    .register = register,
                    .deregister = deregister,
                    .connect = connect,
                    .next = next,
                    .getHandleVal = getHandleVal,
                    .getHandleSource = getHandleSource,
                    .setHandleVal = setHandleVal,
                    .getSignal = getSignal,
                    .getSignalSource = getSignalSource,
                    .setSignal = setSignal,
                    .getNode = getNode,
                    .ticks = ticks,
                    .node_gen = node_gen,
                    .signal_gen = signal_gen,
                },
            };
        }

        // TODO: fix repeated connects to dynamic length ports
        pub fn connect(ptr: *anyopaque, dest: Portlet(Signal), val: Portlet(Signal)) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            // assign portlet to portlet
            switch (dest) {
                .single => |d| {
                    switch (val) {
                        .single => |v| {
                            d.* = v.*;
                        },
                        else => unreachable,
                    }
                },
                .list => |d| {
                    switch (val) {
                        .single => |v| {
                            d.append(v.*) catch {
                                return Error.OtherError;
                            };
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }

            self.buildProcessList() catch {
                return Error.BadProcessList;
            };
        }

        pub const AdjMatrix = [opts.max_node_count][opts.max_node_count]bool;

        fn getAdjMatrix(nodes: []Node) AdjMatrix {
            var adj: AdjMatrix = undefined;

            for (nodes, 0..) |*node, idx| {
                for (node.ins()) |inlet| {
                    switch (inlet) {
                        .single => |single| {
                            if (single.* == .handle) {
                                const src_node_idx = single.handle.node_idx.?;
                                adj[idx][src_node_idx] = true;
                            }
                        },
                        .list => |list| {
                            for (list.items) |i| {
                                if (i == .handle) {
                                    const src_node_idx = i.handle.node_idx.?;
                                    adj[idx][src_node_idx] = true;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }

            return adj;
        }

        fn indegree(matrix: AdjMatrix, idx: usize) u8 {
            var result: u8 = 0;
            for (0..matrix.len) |i| {
                if (matrix[idx][i]) {
                    result += 1;
                }
            }
            return result;
        }

        fn outdegree(matrix: AdjMatrix, idx: usize) u8 {
            var result: u8 = 0;
            for (0..matrix.len) |i| {
                if (matrix[i][idx]) {
                    result += 1;
                }
            }
            return result;
        }

        fn printList(matrix: AdjMatrix, n: u8) void {
            std.debug.print("List:\n\n", .{});

            for (matrix[0..n]) |row| {
                std.debug.print("{any}\n", .{row[0..n]});
            }
            std.debug.print("\n", .{});
        }

        // Builds a list of pointers for nodes in context store, sorted topographically via Kahn's algorithm.
        // https://en.wikipedia.org/wiki/Topological_sorting
        // TODO: omit unconnected nodes from processing?
        pub fn buildProcessList(ctx: *Self) !void {
            const NodeWithIndex = struct { node: *Node, idx: u8 };
            var queue = std.fifo.LinearFifo(NodeWithIndex, .{ .Static = opts.max_node_count }).init();
            var adj_matrix: AdjMatrix = getAdjMatrix(ctx.node_store[0..]);
            var processed_nodes: u8 = 0;

            for (0..ctx.node_count) |idx| {
                if (indegree(adj_matrix, idx) == 0) {
                    try queue.writeItem(.{ .node = &ctx.node_store[idx], .idx = @intCast(idx) });
                }
            }

            while (queue.readItem()) |item| {
                ctx.node_process_list[processed_nodes] = item.node;
                processed_nodes += 1;

                // remove processed node from list
                for (0..adj_matrix.len) |idx| {
                    if (adj_matrix[idx][item.idx]) {
                        adj_matrix[idx][item.idx] = false;
                        if (indegree(adj_matrix, idx) == 0) {
                            try queue.writeItem(.{ .node = &ctx.node_store[idx], .idx = @intCast(idx) });
                        }
                    }
                }
            }

            if (processed_nodes < ctx.node_count) {
                std.debug.print("uh oh, somethings up. Likely cycle found.\n", .{});
                std.debug.print("node count: {}\tprocessed nodes:{}\n", .{ ctx.node_count, processed_nodes });
                return Error.BadProcessList;
            }
        }

        pub fn printNodeList(ctx: *Self) void {
            std.debug.print("node list:\t", .{});
            for (0..ctx.node_count) |idx| {
                const n = ctx.node_process_list[idx];
                std.debug.print("{s}, ", .{n.id});
            }
            std.debug.print("\n", .{});
        }

        pub fn process(ptr: *anyopaque, should_print: bool) void {
            const ctx: *Self = @ptrCast(@alignCast(ptr));
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

        pub fn next(ptr: *anyopaque) []f32 {
            var ctx: *Self = @ptrCast(@alignCast(ptr));

            // process all nodes
            process(ptr, false);

            // tick counter
            ctx.ticks += 1;

            // for now, take single output val and dupe to every channel
            const val = std.math.clamp(ctx.root_signal.get(), -1.0, 1.0);
            for (0..opts.channel_count) |ch_idx| {
                ctx.sink[ch_idx] = val;
            }

            return ctx.sink[0..];
        }

        pub fn ticks(ptr: *anyopaque) u64 {
            const self: *Self = @ptrCast(@alignCast(ptr));

            return self.ticks;
        }

        // TODO: variable size outs
        // Reserves space for node and processing output in context
        pub fn register(ptr: *anyopaque, node: Node) !*Node {
            var ctx: *Self = @ptrCast(@alignCast(ptr));

            if (ctx.node_count >= opts.max_node_count) {
                return Error.NoMoreNodeSpace;
            }

            // kinda don't like this reassignment, its kind of opaque
            for (node.outs()) |out| {
                const next_signal_spot = ctx.scratch_free_list.readItem() orelse ctx.node_count;

                const store_signal: Signal = .{ .handle = .{
                    .node_idx = @intCast(ctx.node_count),
                    .idx = next_signal_spot,
                    .ctx = ctx.context(),
                    .tag = .signal,
                    .gen = ctx.scratch_gen[next_signal_spot],
                } };

                out.single.* = store_signal;
            }

            ctx.node_store[ctx.node_count] = node;

            // re-sort node processing list
            ctx.buildProcessList() catch {
                return Error.BadProcessList;
            };

            const next_node_spot = ctx.node_free_list.readItem() orelse ctx.node_count;
            const node_handle = .{ .ctx = ctx.context(), .idx = next_node_spot, .gen = ctx.node_gen[next_node_spot], .tag = .node };
            _ = node_handle; // autofix

            ctx.node_count += 1;
            return &ctx.node_store[next_node_spot];
        }

        pub fn deregister(ptr: *anyopaque, hdl: Handle) !void {
            var ctx: *Self = @ptrCast(@alignCast(ptr));

            if (ctx.node_count == 0 or ctx.node_count <= hdl.idx or hdl.tag != .node) {
                return;
            }

            if (getNode(ctx, hdl)) |node| {
                for (node.outs()) |out| {
                    // increment gen on all signals for node
                    switch (out.get(0).*) {
                        .handle => |out_hdl| {
                            ctx.scratch_gen[out_hdl.idx] += 1;
                            ctx.scratch_free_list.writeItem(out_hdl.idx) catch {
                                return Error.OtherError;
                            };
                        },
                        else => {},
                    }
                }
            }

            ctx.node_gen[hdl.idx] += 1;
            ctx.node_free_list.writeItem(hdl.idx) catch {
                return Error.OtherError;
            };

            ctx.buildProcessList() catch {
                return error.BadProcessList;
            };
        }

        fn getHandleVal(ptr: *anyopaque, idx: usize, gen: u8) f32 {
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            if (ctx.scratch_gen[idx] == gen) {
                return ctx.scratch[idx];
            }

            return 0.0;
        }

        fn setHandleVal(ptr: *anyopaque, idx: usize, val: f32) void {
            var ctx: *Self = @ptrCast(@alignCast(ptr));
            ctx.scratch[idx] = val;
        }

        fn getHandleSource(ptr: *anyopaque, idx: usize) *Node {
            var ctx: *Self = @ptrCast(@alignCast(ptr));
            return @constCast(&ctx.node_store[idx]);
        }

        fn getSignal(ptr: *anyopaque, hdl: Handle) f32 {
            if (hdl.tag != .signal or !hdl.valid()) {
                return 0.0;
            }
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            return ctx.scratch[hdl.idx];
        }

        fn getSignalSource(ptr: *anyopaque, hdl: Handle) ?*Node {
            if (hdl.tag != .signal or !hdl.valid()) {
                return null;
            }

            const ctx: *Self = @ptrCast(@alignCast(ptr));

            return &ctx.node_store[hdl.node_idx.?];
        }

        pub fn setSignal(ptr: *anyopaque, hdl: Handle, val: f32) void {
            if (hdl.tag != .signal or !hdl.valid()) {
                return;
            }

            const ctx: *Self = @ptrCast(@alignCast(ptr));

            ctx.scratch[hdl.idx] = val;
        }

        fn getNode(ptr: *anyopaque, hdl: Handle) ?*Node {
            if (hdl.tag != .node or !hdl.valid()) {
                std.debug.print("null node: {}\n\n", .{hdl});
                return null;
            }

            const ctx: *Self = @ptrCast(@alignCast(ptr));

            return &ctx.node_store[hdl.idx];
        }
    };
}

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
                // .maybe => |maybe_val| maybe_val,
                .list => |list| &list.items[n],
                else => unreachable, // TODO: sort out or remove "maybe" branch
            };
        }
    };
}

pub const Node = struct {
    id: []const u8 = "x",
    num_inlets: u8 = undefined,
    num_outlets: u8 = undefined,
    inlets: [MAX_PORT_COUNT]NodePortlet = undefined,
    outlets: [MAX_PORT_COUNT]NodePortlet = undefined,
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

    pub fn ins(n: Node) []const NodePortlet {
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

    pub fn outs(n: Node) []const NodePortlet {
        return n.outlets[0..n.num_outlets];
    }

    pub fn port(n: Node, field_name: []const u8) NodePortlet {
        return n.portletFn(n.ptr, field_name);
    }

    pub fn handle(n: Node, ctx: GraphContext) Handle {
        _ = n; // autofix
        _ = ctx; // autofix
    }
};

pub const SignalDirection = enum { in, out };
pub fn TestSignal(comptime dir: SignalDirection, comptime ValueType: type) type {
    // opportunity to enforce unidirectional data flow, here

    return struct {
        const Self = @This();

        pub fn get(s: Self) ValueType {
            _ = s; // autofix
        }

        pub fn set(s: Self, v: ValueType) void {
            _ = s; // autofix
            _ = v; // autofix
            if (dir != .out) {
                return;
            }
        }
    };
}

//
// Signal ideas
// direction: in, out
// type_tag: type enum, dictates shape of value
// SignalValue(T): dictates source of signal, effectively the stuff below
//
pub const Signal = union(enum) {
    ptr: *f32,
    handle: struct { idx: u16, ctx: GraphContext, gen: u8 = 0, tag: HandleTag = .signal, node_idx: ?u8 = null },
    static: f32,

    pub fn get(s: Signal) f32 {
        return switch (s) {
            .ptr => |ptr| ptr.*,
            .handle => |handle| handle.ctx.getHandleVal(handle.idx, handle.gen),
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
    //
    // ^ TODO: We might be able to adjust this in the future by checking structs for fields that are of type Signal, instead of providing explicit
    // field enum lists.

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
