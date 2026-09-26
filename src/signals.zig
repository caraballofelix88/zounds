const std = @import("std");
const testing = std.testing;

const fmt = @import("audio_format.zig");

const adj = @import("adjmatrix.zig");

const GenArray = @import("genarray.zig").GenArray;

const signal = @import("core/signal.zig");
const Signal = signal.Signal;
const SignalHandle = Signal.Handle;

const log = std.log.scoped(.signals);

const MAX_NODE_COUNT = 64;
const SCRATCH_SIZE = 1024;
const MAX_PORT_COUNT = 8;
const CHANNEL_COUNT = 2;
const PORT_ID_NAME_SIZE = 64;

pub const HandleTag = enum(u8) { node, signal };
pub const Handle = extern struct {
    idx: u16,
    tag: HandleTag,
    gen: u8,
};

pub const Error = error{ NoMoreNodeSpace, OtherError, BadProcessList, NodeGraphCycleDetected, SerializationError };
pub const GraphContext = struct {
    ptr: *anyopaque,
    opts: Options,
    sample_rate: u32,
    inv_sample_rate: f32,
    vtable: *const VTable,

    pub const VTable = struct {
        register: *const fn (*anyopaque, Node) Error!Handle,
        deregister: *const fn (*anyopaque, Handle) Error!void,
        connect: *const fn (*anyopaque, *Signal, *Signal) Error!void,
        next: *const fn (*anyopaque) []f32, // TODO: how to push multi-channel?

        getSignal: *const fn (*anyopaque, Handle) f32,
        setSignal: *const fn (*anyopaque, Handle, f32) void,

        getNode: *const fn (*anyopaque, Handle) ?*Node,
        getSignalSourceHandle: *const fn (*anyopaque, Handle) ?Handle,

        root: *const fn (*anyopaque) *Signal,
        ticks: *const fn (*anyopaque) u64,
        // node_list: *const fn (*anyopaque) []Node,
        // signal_list: *const fn (*anyopaque) []f32,
    };

    pub fn register(self: *const GraphContext, node_ptr: anytype) !Handle {
        const T = @typeInfo(@TypeOf(node_ptr));
        // std.debug.assert(T == .Pointer);

        // TODO: assert type has process function with compatible signature
        const ChildType = T.pointer.child;

        const node = Node.init(node_ptr, ChildType);

        return try self.vtable.register(self.ptr, node);
    }

    pub fn deregister(self: *const GraphContext, hdl: Handle) !void {
        try self.vtable.deregister(self.ptr, hdl);
    }

    pub fn connect(self: *const GraphContext, dest: *Signal, val: *Signal) !void {
        try self.vtable.connect(self.ptr, dest, val);
    }

    pub fn next(self: *const GraphContext) []f32 {
        return self.vtable.next(self.ptr);
    }

    pub inline fn getSignal(self: *const GraphContext, hdl: Handle) f32 {
        return self.vtable.getSignal(self.ptr, hdl);
    }

    pub inline fn setSignal(self: *const GraphContext, hdl: Handle, val: f32) void {
        self.vtable.setSignal(self.ptr, hdl, val);
    }

    pub inline fn getSignalSourceHandle(self: *const GraphContext, hdl: Handle) ?Handle {
        return self.vtable.getSignalSourceHandle(self.ptr, hdl);
    }

    pub inline fn getNode(self: *const GraphContext, hdl: Handle) ?*Node {
        return self.vtable.getNode(self.ptr, hdl);
    }

    pub inline fn getNodeHandle(self: *const GraphContext, node: Node) ?Handle {
        return self.vtable.getNodeHandle(self.ptr, node);
    }

    pub inline fn ticks(self: *const GraphContext) u64 {
        return self.vtable.ticks(self.ptr);
    }

    // pub inline fn node_list(self: *const GraphContext) []Node {
    //     return self.vtable.node_list(self.ptr);
    // }

    // pub inline fn signal_list(self: *const GraphContext) []f32 {
    //     return self.vtable.signal_list(self.ptr);
    // }

    pub inline fn root(self: *const GraphContext) *Signal {
        return self.vtable.root(self.ptr);
    }
};

pub const Options = struct {
    max_node_count: u8 = MAX_NODE_COUNT,
    scratch_size: u16 = SCRATCH_SIZE,
    channel_count: u8 = 2,
};

// TODO: could be broken up
// TODO: parent context? Nesting graphs?
pub fn Graph(comptime opts: Options) type {
    const SignalGenArr = GenArray(f32, opts.scratch_size);
    const NodeGenArr = GenArray(Node, opts.max_node_count);

    return struct {
        signal_list: SignalGenArr = SignalGenArr{},
        node_list: NodeGenArr = NodeGenArr{},
        scratch_source_map: [opts.scratch_size]u16 = std.mem.zeroes([opts.scratch_size]u16),
        node_process_list: [opts.max_node_count]u16 = undefined,
        root_signal: Signal = .{ .static = 0.0 },
        format: fmt.FormatData,
        _ticks: u64 = 0,

        ctx: ?GraphContext = null,

        // Holds the last sample frame
        sink: [opts.channel_count]f32 = undefined,

        pub const Self = @This();

        pub fn context(self: *Self) *const GraphContext {
            if (self.ctx == null) {
                self.ctx = .{
                    .ptr = self,
                    .opts = opts,
                    .sample_rate = self.format.sample_rate,
                    .inv_sample_rate = self.format.invSampleRate(),
                    .vtable = &.{
                        .register = register,
                        .deregister = deregister,
                        .connect = connect,
                        .next = next,
                        .getSignal = getSignal,
                        .setSignal = setSignal,
                        .getNode = getNode,
                        .getSignalSourceHandle = getSignalSourceHandle,
                        .ticks = ticks,
                        // .node_list = node_list,
                        // .signal_list = signal_list,
                        .root = root,
                    },
                };
            }
            return &self.ctx.?;
        }

        // TODO: consider better ergonomics for connecting signals.
        // maybe signal.connect(other signal)? That's how WebAudio does it
        //
        // Really just an assignment of a signal value to another, then a
        // recalculation of graph process order.
        pub fn connect(ptr: *anyopaque, dest: *Signal, val: *Signal) !void {
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            dest.* = val.*;

            ctx.buildProcessList() catch {
                for (ctx.node_list.itemSlice()) |item| {
                    std.log.err("{s}", .{item.id});
                }
                return Error.BadProcessList;
            };
        }

        // TODO: do we really need the entire node count?
        const AdjMatrix = [opts.max_node_count][opts.max_node_count]bool;
        pub fn getAdjMatrix(ctx: *Self) AdjMatrix {
            const nodes = ctx.node_list.itemSlice();
            var adj_matrix = std.mem.zeroes(AdjMatrix);

            for (nodes, 0..) |node, idx| {
                for (node.ins()) |in| {
                    if (in.field_ptr.* == .handle) {
                        const src_node_idx = ctx.scratch_source_map[in.field_ptr.*.handle.hdl.idx];
                        adj_matrix[idx][src_node_idx] = true;
                    }
                }
            }

            return adj_matrix;
        }

        // TODO: omit unconnected nodes from processing? What about non-alive/deleted nodes?
        pub fn buildProcessList(ctx: *Self) !void {
            var mat: AdjMatrix = ctx.getAdjMatrix();

            log.debug("building list", .{});

            var queue_buf: [opts.max_node_count]u16 = undefined;

            try adj.topographicList(&mat, ctx.node_list.len, &ctx.node_process_list, queue_buf[0..ctx.node_list.len]);
        }

        pub fn printNodeList(ctx: *Self) void {
            log.debug("node list:\t", .{});

            const node_process_list = ctx.node_process_list[0..ctx.node_list.len];
            for (node_process_list) |node_idx| {
                const n = ctx.node_list.getPtr(.{ .gen = std.math.maxInt(u8), .idx = node_idx });
                log.debug("{s}, ", .{n.id});
            }
        }

        pub fn process(ptr: *anyopaque) void {
            const ctx: *Self = @ptrCast(@alignCast(ptr));
            // for node in context graph, compute new values

            const node_process_list = ctx.node_process_list[0..ctx.node_list.len];
            for (node_process_list) |node_idx| {
                var node = ctx.node_list.getPtr(.{ .gen = std.math.maxInt(u8), .idx = node_idx });
                node.process();
            }
        }

        pub fn next(ptr: *anyopaque) []f32 {
            var ctx: *Self = @ptrCast(@alignCast(ptr));

            // process all nodes
            process(ptr);

            // tick counter
            ctx._ticks += 1;

            // for now, take single output val and dupe to every channel
            const val = std.math.clamp(ctx.root_signal.get(), -1.0, 1.0);
            for (0..opts.channel_count) |ch_idx| {
                ctx.sink[ch_idx] = val;
            }

            return ctx.sink[0..];
        }

        // Reserves space for node and processing output in context
        // TODO: confirm there's space for all the node's signals before populating signal array
        pub fn register(ptr: *anyopaque, node: Node) !Handle {
            var ctx: *Self = @ptrCast(@alignCast(ptr));

            const node_hdl = ctx.node_list.push(node) catch {
                return Error.NoMoreNodeSpace;
            };

            const node_handle: Handle = .{
                .tag = .node,
                .idx = node_hdl.idx,
                .gen = node_hdl.gen,
            };

            const node_ptr = ctx.node_list.getPtr(node_hdl);

            // reasigns node outsignals after slotting space for them in memeory
            for (node_ptr.outs()) |*out| {
                const new_signal = ctx.signal_list.push(0.0) catch {
                    return Error.OtherError;
                };

                ctx.scratch_source_map[new_signal.idx] = node_hdl.idx;

                const store_signal: Signal = .{
                    .handle = .{
                        .hdl = .{
                            .idx = new_signal.idx,
                            .gen = new_signal.gen,
                            .tag = .signal,
                        },
                        .ctx = ctx.context(),
                    },
                };

                out.*.field_ptr.* = store_signal;
            }

            // re-sort node processing list
            ctx.buildProcessList() catch {
                return Error.BadProcessList;
            };

            return node_handle;
        }

        pub fn deregister(ptr: *anyopaque, hdl: Handle) !void {
            var ctx: *Self = @ptrCast(@alignCast(ptr));

            if (ctx.node_list.len == 0 or ctx.node_list.len <= hdl.idx or hdl.tag != .node) {
                return;
            }

            if (getNode(ctx, hdl)) |node| {
                for (node.outs()) |out| {
                    // increment gen on all signals for node
                    switch (out.field_ptr.*) {
                        .handle => |out_hdl| {
                            ctx.signal_list.delete(.{ .gen = out_hdl.hdl.gen, .idx = out_hdl.hdl.idx }) catch {
                                return Error.OtherError;
                            };
                        },
                        else => {},
                    }
                }
            }

            ctx.node_list.delete(.{ .idx = hdl.idx, .gen = hdl.gen }) catch {
                return Error.OtherError;
            };

            ctx.buildProcessList() catch {
                return error.BadProcessList;
            };
        }

        fn getSignal(ptr: *anyopaque, hdl: Handle) f32 {
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            return ctx.signal_list.get(.{ .gen = hdl.gen, .idx = hdl.idx }) orelse 0.0;
        }

        fn setSignal(ptr: *anyopaque, hdl: Handle, val: f32) void {
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            return ctx.signal_list.set(.{ .gen = hdl.gen + 100, .idx = hdl.idx }, val) catch {
                // TODO: do something about catch here?
            };
        }

        fn getSignalSource(ptr: *anyopaque, hdl: Handle) ?*Node {
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            const source_idx = ctx.scratch_source_map[hdl.idx];
            return ctx.node_list.getPtr(.{ .idx = source_idx, .gen = hdl.gen });
        }

        fn getSignalSourceHandle(ptr: *anyopaque, hdl: Handle) ?Handle {
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            const sig = ctx.signal_list.get(.{ .gen = hdl.gen, .idx = hdl.idx });

            if (sig) |_| {
                const node_idx = ctx.scratch_source_map[hdl.idx];
                return .{
                    .idx = node_idx,
                    .gen = hdl.gen,
                    .tag = .node,
                };
            }

            return null;
        }

        fn getNode(ptr: *anyopaque, hdl: Handle) ?*Node {
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            return switch (hdl.tag) {
                .node => ctx.node_list.getPtr(.{ .gen = hdl.gen, .idx = hdl.idx }),
                .signal => getSignalSource(ctx, hdl),
            };
        }

        fn ticks(ptr: *anyopaque) u64 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self._ticks;
        }

        fn root(ptr: *anyopaque) *Signal {
            const ctx: *Self = @ptrCast(@alignCast(ptr));
            return &ctx.root_signal;
        }

        //     fn node_list(ptr: *anyopaque) []Node {
        //         const self: *Self = @ptrCast(@alignCast(ptr));

        //         return self.node_list.items[0..];
        //     }

        //     fn signal_list(ptr: *anyopaque) []f32 {
        //         const self: *Self = @ptrCast(@alignCast(ptr));

        //         return self.signal_list.items[0..];
        //     }
    };
}

// TODO: inlet and outlet maximums should probably be supplied to generic. Fine for now, tho
pub const Node = struct {
    ptr: *anyopaque,
    // TODO: test out storing the backing node type as a field,
    // base_type: type,
    src_type: []const u8,
    id: []const u8 = "x",
    num_inlets: u8 = undefined,
    num_outlets: u8 = undefined,
    inlets: [MAX_PORT_COUNT]signal.PortField = undefined,
    outlets: [MAX_PORT_COUNT]signal.PortField = undefined,
    processFn: *const fn (*anyopaque) void,
    getPortFn: *const fn (*anyopaque, []const u8) signal.PortField,

    pub fn init(ptr: *anyopaque, T: type) Node {
        const concrete: *T = @ptrCast(@alignCast(ptr));
        const P = signal.Ports(T);
        var node: Node = .{
            .src_type = @typeName(T),
            .ptr = ptr,
            .id = concrete.id,
            .processFn = &T.process,
            .getPortFn = &P.getPort,
        };

        const p_ins = P.ins(ptr);
        const p_outs = P.outs(ptr);

        node.num_inlets = p_ins.len;
        node.num_outlets = p_outs.len;

        std.mem.copyForwards(signal.PortField, node.inlets[0..], p_ins[0..]);
        std.mem.copyForwards(signal.PortField, node.outlets[0..], p_outs[0..]);

        return node;
    }

    pub fn process(n: *const Node) void {
        n.processFn(n.ptr);
    }

    pub fn ins(n: *const Node) []const signal.PortField {
        return n.inlets[0..n.num_inlets];
    }

    pub fn outs(n: *const Node) []const signal.PortField {
        return n.outlets[0..n.num_outlets];
    }

    pub fn port(n: *const Node, field_name: []const u8) signal.PortField {
        return n.getPortFn(n.ptr, field_name);
    }
};
