const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const sources = @import("sources/main.zig");
const dsp = @import("dsp/dsp.zig");

const MAX_NODE_COUNT = 64;
const SCRATCH_BYTES = 1024;
const MAX_PORT_COUNT = 8;
const CHANNEL_COUNT = 2;

pub const Error = error{ NoMoreNodeSpace, OtherError, BadProcessList, NodeGraphCycleDetected };
pub const GraphContext = struct {
    ptr: *anyopaque,
    opts: Options,
    sample_rate: u32,
    inv_sample_rate: f32,
    vtable: *const VTable,

    pub const VTable = struct {
        register: *const fn (*anyopaque, *Node) Error!void,
        connect: *const fn (*anyopaque, *Signal, Signal) Error!void,
        next: *const fn (*anyopaque) []f32, // how to push multi-channel?
        getHandleVal: *const fn (*anyopaque, usize) f32,
        setHandleVal: *const fn (*anyopaque, usize, f32) void,
        getHandleSource: *const fn (*anyopaque, usize) *Node,

        ticks: *const fn (*anyopaque) u64,
    };

    pub fn register(self: GraphContext, node: *Node) !void {
        try self.vtable.register(self.ptr, node);
    }

    pub fn connect(self: GraphContext, dest: *Signal, val: Signal) !void {
        try self.vtable.connect(self.ptr, dest, val);
    }

    pub fn next(self: GraphContext) []f32 {
        return self.vtable.next(self.ptr);
    }

    pub fn getHandleVal(self: GraphContext, idx: usize) f32 {
        return self.vtable.getHandleVal(self.ptr, idx);
    }
    pub fn setHandleVal(self: GraphContext, idx: usize, val: f32) void {
        self.vtable.setHandleVal(self.ptr, idx, val);
    }

    pub fn getHandleSource(self: GraphContext, idx: usize) *Node {
        return self.vtable.getHandleSource(self.ptr, idx);
    }

    pub fn ticks(self: GraphContext) u64 {
        return self.vtable.ticks(self.ptr);
    }
};

pub const Options = struct {
    max_node_count: u8 = MAX_NODE_COUNT,
    scratch_size: u16 = SCRATCH_BYTES,
    channel_count: u8 = 2,
};
// TODO: contexts as nodes themselves?
pub fn Graph(comptime opts: Options) type {
    return struct {
        scratch: [opts.scratch_size]f32 = std.mem.zeroes([opts.scratch_size]f32),
        node_store: [opts.max_node_count]Node = undefined,
        node_process_list: [opts.max_node_count]*Node = undefined,
        root_signal: Signal = .{ .static = 0.0 },
        format: main.FormatData,
        ticks: u64 = 0,
        node_count: u16 = 0,

        // Holds the last sample frame
        sink: [opts.channel_count]f32 = undefined,

        pub const Self = @This();

        pub fn context(self: *Self) GraphContext {
            return .{
                .ptr = self,
                .opts = opts,
                .sample_rate = self.format.sample_rate,
                .inv_sample_rate = self.format.invSampleRate(),
                .vtable = &.{
                    .register = register,
                    .connect = connect,
                    .next = next,
                    .getHandleVal = getHandleVal,
                    .getHandleSource = getHandleSource,
                    .setHandleVal = setHandleVal,
                    .ticks = ticks,
                },
            };
        }

        pub fn connect(ptr: *anyopaque, dest: *Signal, val: Signal) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            dest.* = val;

            self.buildProcessList() catch {
                return Error.BadProcessList;
            };
        }

        // Builds a list of pointers for nodes in context store, sorted topographically via Kahn's algorithm.
        // https://en.wikipedia.org/wiki/Topological_sorting
        // TODO: check for cycles
        pub fn buildProcessList(ctx: *Self) !void {
            var queue = std.fifo.LinearFifo(*Node, .{ .Static = opts.max_node_count }).init();
            var indegrees: [opts.max_node_count]u8 = .{0} ** opts.max_node_count;
            var sorted_idx: u8 = 0;

            for (0..ctx.node_count) |idx| {
                var node = getHandleSource(ctx, idx);
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

                // for each outlet, go through node store to find linked nodes
                // TODO: iterating through the full node list each time we wanna find linked outputs for sure needlessly expensive,
                // but its whatever for now. processing some kind of adjacency matrix upfront and using that maybe makes more sense
                for (n.outs()) |out| {
                    for (0..ctx.node_count) |idx| {
                        var adj_node = getHandleSource(ctx, idx);

                        for (adj_node.ins()) |in_port| {
                            const in_signals: []const Signal = switch (in_port) {
                                .single => |in_single| &.{in_single.*},
                                .list => |in_list| in_list.items,
                                else => unreachable,
                            };

                            for (in_signals) |in_item| {
                                if (std.meta.eql(out.single.*, in_item)) {
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
                return Error.NodeGraphCycleDetected;
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

        // TODO: unregistering, i guess
        // TODO: variable size outs
        // Reserves space for node and processing output in context
        pub fn register(ptr: *anyopaque, node: *Node) !void {
            // TODO: assert type has process function with compatible signature
            var ctx: *Self = @ptrCast(@alignCast(ptr));

            if (ctx.node_count >= opts.max_node_count) {
                return Error.NoMoreNodeSpace;
            }

            const store_signal: Signal = .{ .handle = .{ .idx = ctx.node_count, .ctx = ctx.context() } };
            var n = node.*;
            n.out(0).single.* = store_signal;
            ctx.node_store[ctx.node_count] = n;

            ctx.node_count += 1;

            // re-sort node processing list
            ctx.buildProcessList() catch {
                return Error.OtherError;
            };
        }

        fn getHandleVal(ptr: *anyopaque, idx: usize) f32 {
            const ctx: *Self = @ptrCast(@alignCast(ptr));
            return ctx.scratch[idx];
        }

        fn setHandleVal(ptr: *anyopaque, idx: usize, val: f32) void {
            var ctx: *Self = @ptrCast(@alignCast(ptr));
            ctx.scratch[idx] = val;
        }

        fn getHandleSource(ptr: *anyopaque, idx: usize) *Node {
            var ctx: *Self = @ptrCast(@alignCast(ptr));
            return @constCast(&ctx.node_store[idx]);
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
    handle: struct { idx: u16, ctx: GraphContext },
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
