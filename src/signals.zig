const std = @import("std");
const testing = std.testing;

const main = @import("main.zig");
const osc = @import("sources/osc.zig");
const sources = @import("sources/main.zig");

pub const Context = struct {
    alloc: std.mem.Allocator,
    scratch: []f32,
    node_list: ?[]*const Context.Node = null,
    sink: ?Context.Signal = null, // should be ptr?
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
        inlet_buf: [8]Portlet = undefined,
        outlet_buf: [8]Portlet = undefined,
        ptr: *anyopaque,
        // ports: *anyopaque = @ptrFromInt(0xDEADBEEF),
        processFn: *const fn (*anyopaque) void,
        portLetFn: *const fn (*anyopaque, []const u8) Portlet,
        // inletsFn: *const fn (*anyopaque) []*?Context.Signal,
        // outletsFn: *const fn (*anyopaque) []*?Context.Signal,
        z_inletsFn: *const fn (*anyopaque, []Portlet) []Portlet,
        z_outletsFn: *const fn (*anyopaque, []Portlet) []Portlet,

        const Portlet = Let(?Context.Signal);

        pub fn process(n: Context.Node) void {
            n.processFn(n.ptr);
        }

        // pub fn ins(n: Context.Node) []*?Context.Signal {
        //     return n.inletsFn(n.ports);
        // }

        pub fn in_lets(n: *Context.Node) []Portlet {
            return n.z_inletsFn(n.ptr, &n.inlet_buf);
        }

        // pub fn outs(n: Context.Node) []*?Context.Signal {
        //     return n.outletsFn(n.ports);
        // }

        pub fn out_lets(n: *Context.Node) []Portlet {
            return n.z_outletsFn(n.ptr, &n.outlet_buf);
        }

        // pub fn port(n: Context.Node, field_name: []const u8) *?Context.Signal {
        //     return n.portFn(n.ptr, field_name);
        // }

        pub fn port_lets(n: Context.Node, field_name: []const u8) Portlet {
            return n.portLetFn(n.ptr, field_name);
        }
    };

    //     // TODO: Consider alternatives for the interface objects outside of the concrete class
    //     // Prioritiies:
    //     // - Runtime-performant
    //     // - End-user ergonomics

    pub const Signal = struct {
        val: *f32,
        src_node: *Context.Node,
        pub fn get(s: *@This()) f32 {
            return s.val.*;
        }
    };

    pub const ConcreteA = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteA",
        in: ?Context.Signal = null,
        out: ?Context.Signal = null,

        pub const P = Ports(ConcreteA, ?Context.Signal);
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
                    break :blk in.val.*;
                }
                break :blk 1.0;
            };

            n.out.?.val.* = in * 5.0;
        }

        pub fn node(self: *ConcreteA) Context.Node {
            return .{
                .ptr = self,
                .processFn = &ConcreteA.process,
                // .ports = ports_ptr,
                // .inletsFn = &P.inlets,
                // .outletsFn = &P.outlets,
                .portLetFn = &P.get_let,
                .z_outletsFn = &P.zOutlets,
                .z_inletsFn = &P.zInlets,
            };
        }
    };

    pub const ConcreteSink = struct {
        ctx: *Context,
        id: []const u8 = "ConcreteSink",
        inputs: std.ArrayList(?Context.Signal),
        out: ?Context.Signal = null,

        const P = Ports(ConcreteSink, ?Context.Signal);
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
                    result += in.val.*;
                    input_count += 1;
                }
            }

            result /= @floatFromInt(@max(input_count, 1));
            sink.out.?.val.* = result;
        }

        pub fn node(self: *ConcreteSink) Context.Node {
            return .{
                .ptr = self,
                .processFn = &ConcreteSink.process,
                //.inletsFn = &P.inlets,
                //.outletsFn = &P.outlets,
                //.portFn = &P.get,
                .portLetFn = &P.get_let,
                .z_outletsFn = &P.zOutlets,
                .z_inletsFn = &P.zInlets,
            };
        }
    };

    test "sink node" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var sink = try ConcreteSink.init(&ctx);
        defer sink.deinit();
        var sink_node = sink.node();

        _ = ctx.registerNode(&sink_node);

        // std.debug.print("sink_node.out: {?}\n", .{sink.out});

        try testing.expect(sink.out != null);

        var concrete_a = ConcreteA{ .ctx = &ctx };
        var a_node = concrete_a.node();

        var a: f32 = 1.0;
        var b: f32 = 3.0;
        var c: f32 = 8.0;
        try sink.inputs.append(.{ .val = &a, .src_node = &a_node });
        try sink.inputs.append(.{ .val = &b, .src_node = &a_node });
        try sink.inputs.append(.{ .val = &c, .src_node = &a_node });

        // confirm outlet points to same value
        try testing.expectEqual(sink_node.out_lets()[0].single, &sink.out);

        sink_node.process();

        try testing.expectEqual(4.0, sink_node.out_lets()[0].single.*.?.val.*);
    }

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

        const L = Let(S);

        return struct {
            t: *T,
            ins: [T.ins.len]*S,
            outs: [T.outs.len]*S,
            in_lets: [T.ins.len]L,
            out_lets: [T.outs.len]L,

            pub const num_ins = T.ins.len;
            pub const num_outs = T.outs.len;

            const Self = @This();
            const FE = std.meta.FieldEnum(T);

            // TODO: do away with init, find a way to eliminate state inside Port, is it useful?
            pub fn init(ptr: *T) Self {
                const ins: [T.ins.len]*S = blk: {
                    var result: [T.ins.len]*S = undefined;

                    inline for (T.ins, 0..) |port, idx| {
                        result[idx] = &@field(ptr, @tagName(port));
                    }

                    break :blk result;
                };

                const in_lets: [T.ins.len]L = blk: {
                    var result: [T.ins.len]L = undefined;

                    inline for (T.ins, 0..) |port, idx| {
                        const field_ptr = &@field(ptr, @tagName(port));
                        result[idx] = switch (std.meta.FieldType(T, port)) {
                            S => .{ .single = field_ptr },
                            std.ArrayList(S) => .{ .list = field_ptr },
                            else => unreachable,
                        };
                        //result[idx] = &@field(ptr, @tagName(port));
                    }

                    break :blk result;
                };

                const outs: [T.outs.len]*S = blk: {
                    var result: [T.outs.len]*S = undefined;

                    inline for (T.outs, 0..) |port, idx| {
                        result[idx] = &@field(ptr, @tagName(port));
                    }

                    break :blk result;
                };

                const out_lets: [T.outs.len]L = blk: {
                    var result: [T.outs.len]L = undefined;

                    inline for (T.outs, 0..) |port, idx| {
                        const field_ptr = &@field(ptr, @tagName(port));
                        result[idx] = switch (std.meta.FieldType(T, port)) {
                            S => .{ .single = field_ptr },
                            std.ArrayList(S) => .{ .list = field_ptr },
                            else => unreachable,
                        };
                    }

                    break :blk result;
                };

                return .{ .t = ptr, .ins = ins, .in_lets = in_lets, .outs = outs, .out_lets = out_lets };
            }

            // assumes all port fields are the same type
            pub fn inlets(ptr: *anyopaque) []*S {
                const self: *Self = @ptrCast(@alignCast(ptr));
                return self.ins[0..];
            }

            // idea for accessing array of in/outlets directly, w/o Ports instance
            pub fn zInlets(ptr: *anyopaque, buf: []L) []L {
                var t: *T = @ptrCast(@alignCast(ptr));

                inline for (T.ins, 0..) |port, idx| {
                    const field_ptr = &@field(t, @tagName(port));
                    buf[idx] = switch (std.meta.FieldType(T, port)) {
                        S => .{ .single = field_ptr },
                        std.ArrayList(S) => .{ .list = field_ptr },
                        else => unreachable,
                    };
                }

                return buf[0..T.ins.len];
            }

            pub fn outlets(ptr: *anyopaque) []*S {
                const self: *Self = @ptrCast(@alignCast(ptr));
                return self.outs[0..];
            }

            pub fn zOutlets(ptr: *anyopaque, buf: []L) []L {
                var t: *T = @ptrCast(@alignCast(ptr));

                inline for (T.outs, 0..) |port, idx| {
                    const field_ptr = &@field(t, @tagName(port));
                    buf[idx] = switch (std.meta.FieldType(T, port)) {
                        S => .{ .single = field_ptr },
                        std.ArrayList(S) => .{ .list = field_ptr },
                        else => unreachable,
                    };
                }

                return buf[0..T.outs.len];
            }

            // pub fn get(ptr: *anyopaque, field_str: []const u8) *S {
            //     const t: *T = @ptrCast(@alignCast(ptr));
            //
            //     inline for (T.ins) |in| {
            //         if (std.mem.eql(u8, @tagName(in), field_str)) {
            //             return &@field(t, @tagName(in));
            //         }
            //     }
            //
            //     inline for (T.outs) |out| {
            //         if (std.mem.eql(u8, @tagName(out), field_str)) {
            //             return &@field(t, @tagName(out));
            //         }
            //     }
            //
            //     unreachable;
            // }

            pub fn get_let(ptr: *anyopaque, field_str: []const u8) L {
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

            pub fn getIn(self: Self, comptime idx: usize) *std.meta.FieldType(T, T.ins[idx]) {
                return &@field(self.t, @tagName(T.ins[idx]));
            }

            pub fn getOut(self: Self, comptime idx: usize) *std.meta.FieldType(T, T.outs[idx]) {
                return &@field(self.t, @tagName(T.outs[idx]));
            }

            pub fn getPtr(self: Self, comptime fe: FE) *std.meta.FieldType(T, fe) {
                return &@field(self.t, @tagName(fe));
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

        var p = Ports(PortNode, []const u8).init(&node);

        try testing.expectEqualSlices(*const []const u8, &.{ &node.in_one, &node.in_two, &node.in_three }, Ports(PortNode, []const u8).inlets(&p));

        try testing.expectEqual(@TypeOf(p.getPtr(.out_back)), *[]const u8);
        try testing.expectEqual(@TypeOf(p.getPtr(.steak_house)), *f32);

        const in_two = @TypeOf(p).get_let(&node, "in_two");
        in_two.single.* = @TypeOf(p).getOut(p, 0).*;

        try testing.expectEqual(p.getPtr(.in_two).*, p.getPtr(.out_back).*);
    }

    test "ConcreteA node interface" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = ConcreteA{ .ctx = &ctx };
        var node = concrete_a.node();

        concrete_a.out = ctx.registerNode(&node);

        try testing.expect(concrete_a.out != null);

        // confirm outlet points to same value
        try testing.expectEqual(node.out_lets()[0].single, &concrete_a.out);

        // test assignment
        node.port_lets("out").single.* = .{
            .val = @as(*f32, @ptrFromInt(0xDEADBEEF + 1)),
            .src_node = &node,
        };
    }

    // TODO: get topologically sorted list of nodes
    pub fn refreshNodeList(ctx: *Context) !void {
        if (ctx.node_list) |nodes| {
            ctx.alloc.free(nodes);
        }
        var node_list = std.ArrayList(*Context.Node).init(ctx.alloc);

        // reversing DFS for now, just to see if this works
        var curr_node: ?*Context.Node = ctx.sink.?.src_node;
        var prev_node: ?*Context.Node = null;

        while (curr_node) |n| {
            try node_list.append(n);

            prev_node = n;

            for (n.in_lets()) |let| {
                switch (let) {
                    .single => |maybe_in| {
                        if (maybe_in.*) |in_signal| {
                            curr_node = in_signal.src_node;
                            break;
                        } else {
                            curr_node = null;
                        }
                    },
                    .list => |list| {
                        for (list.items) |maybe_sig| {
                            if (maybe_sig) |sig| {
                                // check for node presence before slapping onto node list
                                if (!std.mem.containsAtLeast(*Context.Node, node_list.items, 1, &.{sig.src_node})) {
                                    try node_list.append(sig.src_node);
                                }
                                curr_node = null;
                            }
                        }
                    },
                }
            }
        }

        std.mem.reverse(*const Context.Node, node_list.items);

        ctx.node_list = try node_list.toOwnedSlice();
    }

    // TODO: NEXT: Node graph traversal, sort out shape of signals and nodes
    test "context getNodeList" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();

        _ = ctx.registerNode(&node_a);

        var concrete_b = Context.ConcreteA{ .ctx = &ctx, .id = "node_b", .in = node_a.out_lets()[0].single.* };
        var node_b = concrete_b.node();

        concrete_b.out = ctx.registerNode(&node_b);

        try testing.expect(node_b.out_lets()[0].single.* != null);

        ctx.sink = node_b.out_lets()[0].single.*;

        try ctx.refreshNodeList();

        try testing.expectEqualSlices(*const Context.Node, &.{ &node_a, &node_b }, ctx.node_list.?);
    }

    pub fn process(ctx: *Context) void {
        // for node in context graph, compute new values
        if (ctx.node_list) |list| {
            for (list) |node| {
                node.process();
            }
        }
        ctx.ticks += 1;
    }

    test "process" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();

        _ = ctx.registerNode(&node_a);

        var concrete_b = Context.ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.out_lets()[0].single.* };
        var node_b = concrete_b.node();

        _ = ctx.registerNode(&node_b);

        var oscillator = Context.Oscillator{ .ctx = &ctx, .pitch = node_b.out_lets()[0].single.*, .amp = node_a.out_lets()[0].single.* };
        var osc_node = oscillator.node();

        _ = ctx.registerNode(&osc_node);

        var sink = try Context.ConcreteSink.init(&ctx);
        defer sink.deinit();

        var sink_node = sink.node();

        try sink.inputs.append(concrete_a.out);
        try sink.inputs.append(concrete_b.out);
        try sink.inputs.append(oscillator.out);

        _ = ctx.registerNode(&sink_node);

        ctx.sink = sink_node.port_lets("out").single.*;

        try ctx.refreshNodeList();

        ctx.process();

        try testing.expectEqual(5, node_a.port_lets("out").single.*.?.val.*); // TODO: goodness gracious would you look at this nonsense
        try testing.expectEqual(3.33333333, ctx.sink.?.val.*);

        // lil mini benchmark
        // about 1ms for 44_100 iterations through very simple graph, doesn't bode well.
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
    pub fn registerNode(ctx: *Context, node: *Context.Node) Context.Signal {
        // TODO: assert type has process function with compatible signature

        const signal: Context.Signal = .{ .val = ctx.getListAddress(ctx.node_count), .src_node = node };

        ctx.node_count += 1;

        node.out_lets()[0].single.* = signal;
        return signal;
    }

    test "registerNode" {
        var ctx = try Context.init(testing.allocator_instance.allocator());
        defer ctx.deinit();

        var concrete_a = Context.ConcreteA{ .ctx = &ctx, .id = "node_a" };
        var node_a = concrete_a.node();

        _ = ctx.registerNode(&node_a);

        var concrete_b = Context.ConcreteB{ .ctx = &ctx, .id = "node_b", .in = node_a.out_lets()[0].single.* };
        var node_b = concrete_b.node();

        concrete_b.out = ctx.registerNode(&node_b);

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
        in: ?Context.Signal = null,
        multiplier: ?Context.Signal = null,
        out: ?Context.Signal = null,

        const SignalType = ?Context.Signal;
        pub const P = Ports(ConcreteB, SignalType);
        pub const ins = [_]std.meta.FieldEnum(ConcreteB){ .in, .multiplier };
        pub const outs = [_]std.meta.FieldEnum(ConcreteB){.out};

        pub fn process(ptr: *anyopaque) void {
            const n: *Context.ConcreteB = @ptrCast(@alignCast(ptr));

            if (n.out == null) {
                // need to register node first to assign signal
                std.debug.print("Uh oh, there's no out for {s}\n", .{n.id});
                return;
            }

            const multi = blk: {
                if (n.multiplier) |m| {
                    break :blk m.val.*;
                }
                break :blk 1.0;
            };

            const in = blk: {
                if (n.in) |in| {
                    break :blk in.val.*;
                }
                break :blk 1.0;
            };

            n.out.?.val.* = in * multi + 5.0;
        }

        pub fn node(self: *ConcreteB) Context.Node {
            return .{
                .ptr = self,
                .processFn = &ConcreteB.process,
                //.ports = ports_ptr,
                //.inletsFn = &P.inlets,
                //.outletsFn = &P.outlets,
                //.portFn = &P.get,
                .portLetFn = &P.get_let,
                .z_outletsFn = &P.zOutlets,
                .z_inletsFn = &P.zInlets,
            };
        }
    };

    pub const Oscillator = struct {
        ctx: *Context,
        wavetable: []const f32 = &wave,
        pitch: ?Context.Signal = null,
        amp: ?Context.Signal = null,
        out: ?Context.Signal = null,

        const SignalType = ?Context.Signal;
        pub const P = Ports(Oscillator, SignalType);
        pub const ins = [_]std.meta.FieldEnum(Oscillator){ .pitch, .amp };
        pub const outs = [_]std.meta.FieldEnum(Oscillator){.out};

        pub fn process(ptr: *anyopaque) void {
            const n: *Context.Oscillator = @ptrCast(@alignCast(ptr));

            if (n.out == null) {
                return;
            }

            const pitch = blk: {
                if (n.pitch) |pitch| {
                    break :blk pitch.val.*;
                }
                break :blk 440.0;
            };

            const amp = blk: {
                if (n.amp) |amp| {
                    break :blk amp.val.*;
                }
                break :blk 0.5;
            };

            const len: f32 = @floatFromInt(n.wavetable.len);
            var phase = @as(f32, @floatFromInt(n.wavetable.len)) * pitch * @as(f32, @floatFromInt(@mod(n.ctx.ticks, n.ctx.sample_rate))) / @as(f32, @floatFromInt(n.ctx.sample_rate));

            while (phase >= len) {
                phase -= len;
            }

            const lowInd: usize = @intFromFloat(@floor(phase));
            const highInd: usize = @intFromFloat(@mod(@ceil(phase), len));

            const fractional_distance: f32 = @rem(phase, 1);

            const result: f32 = std.math.lerp(n.wavetable[lowInd], n.wavetable[highInd], fractional_distance) * amp;

            // store latest result
            n.out.?.val.* = result;
        }

        pub fn node(self: *Oscillator) Context.Node {
            return .{
                .ptr = self,
                .processFn = &Oscillator.process,
                //.ports = ports_ptr,
                // .inletsFn = &P.inlets,
                // .outletsFn = &P.outlets,
                // .portFn = &P.get,
                .portLetFn = &P.get_let,
                .z_outletsFn = &P.zOutlets,
                .z_inletsFn = &P.zInlets,
            };
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
