const std = @import("std");

// TODO: move graph into core dir
const graph = @import("../signals.zig");

const Handle = graph.Handle;

const log = std.log.scoped(.signal);

pub const Signal = union(enum) {
    const ValueType = f32;

    static: ValueType,
    ptr: *ValueType,
    handle: struct { hdl: Handle, ctx: *const graph.GraphContext },

    pub fn get(s: Signal) ValueType {
        return switch (s) {
            .ptr => |ptr| ptr.*,
            .handle => |handle| handle.ctx.getSignal(handle.hdl),
            .static => |val| val,
        };
    }

    pub fn set(s: Signal, v: ValueType) void {
        switch (s) {
            .ptr => |ptr| {
                ptr.* = v;
            },
            .handle => |handle| {
                handle.ctx.setSignal(handle.hdl, v);
            },
            .static => {
                return;
            },
        }
    }

    pub fn source(s: Signal) ?Handle {
        return switch (s) {
            .ptr => null,
            .handle => |handle| handle.ctx.getSignalSourceHandle(handle.hdl),
            .static => null,
        };
    }
};

pub const PortField = struct {
    field_ptr: *Signal, // TODO: Is there a way to get away with not using pointers here?
    name: []const u8,
    default_val: Signal,
};

// https://zigbin.io/9222cb
// shoutouts to Francis on the forums
pub fn Ports(comptime T: anytype) type {
    // Serves as an interface to a concrete processor struct's input and output.
    // Upstream types must designate which fields are input and output data through
    // FieldEnum arrays.
    //
    // ^ TODO: We might be able to adjust this in the future by checking structs for fields that are of type Signal, instead of providing explicit
    // field enum lists.

    // S type designates the expected type for inputs and outputs. For now, all inputs and outputs are expected to
    // be the same type, because I can't quite figure out how to make lists of heterogeneous pointers work ergonomically at runtime.
    // eg. how do we provide Signal types that don't care what their Child type is?
    // idea: Signals as union types, like before
    //

    const FieldEnum = std.meta.FieldEnum(T);

    const fields = @typeInfo(T).@"struct".fields;

    const in_count = comptime blk: {
        var idx = 0;

        for (fields) |field| {
            if (field.type == DirSignal(.in)) {
                idx += 1;
            }
        }
        break :blk idx;
    };

    const in_sigs: [in_count]FieldEnum = comptime blk: {
        var ins: [fields.len]FieldEnum = undefined;
        var idx = 0;

        for (fields) |field| {
            if (field.type == DirSignal(.in)) {
                ins[idx] = @field(FieldEnum, field.name);
                idx += 1;
            }
        }
        break :blk ins[0..idx].*;
    };

    const out_count = comptime blk: {
        var idx = 0;

        for (fields) |field| {
            if (field.type == DirSignal(.out)) {
                idx += 1;
            }
        }
        break :blk idx;
    };

    const out_sigs: [out_count]FieldEnum = comptime blk: {
        var outs: [fields.len]FieldEnum = undefined;
        var idx = 0;

        for (fields) |field| {
            if (field.type == DirSignal(.out)) {
                outs[idx] = @field(FieldEnum, field.name);
                idx += 1;
            }
        }
        break :blk outs[0..idx].*;
    };

    const t_ins = if (@hasDecl(T, "ins")) T.ins else in_sigs;
    const t_outs = if (@hasDecl(T, "outs")) T.outs else out_sigs;

    return struct {
        t: *T,

        const Self = @This();
        const default_signal: Signal = .{ .static = 0.0 };

        pub fn ins(ptr: *anyopaque) [t_ins.len]PortField {
            const t: *T = @ptrCast(@alignCast(ptr));
            var buf: [t_ins.len]PortField = undefined;

            inline for (t_ins, 0..t_ins.len) |port, idx| {
                const info = std.meta.fieldInfo(T, port);

                switch (info.type) {
                    DirSignal(.in) => {
                        var outer_field = &@field(t, @tagName(port));

                        // DirSignals nest Signal structs, so we need
                        // to pull the internal signal value field here.
                        const default_val = if (info.defaultValue()) |def| def.val else default_signal;

                        buf[idx] = .{
                            .field_ptr = &@field(outer_field, "val"),
                            .name = info.name,
                            .default_val = default_val,
                        };
                    },
                    Signal => {
                        const default_val = info.defaultValue() orelse default_signal;

                        buf[idx] = .{
                            .field_ptr = &@field(t, @tagName(port)),
                            .name = info.name,
                            .default_val = default_val,
                        };
                    },
                    else => {},
                }
            }

            return buf;
        }

        pub fn outs(ptr: *anyopaque) [t_outs.len]PortField {
            const t: *T = @ptrCast(@alignCast(ptr));
            var buf: [t_outs.len]PortField = undefined;

            inline for (t_outs, 0..t_outs.len) |port, idx| {
                const info = std.meta.fieldInfo(T, port);

                switch (info.type) {
                    DirSignal(.out) => {
                        var outer_field = &@field(t, @tagName(port));
                        const default_val = if (info.defaultValue()) |def| def.val else default_signal;

                        buf[idx] = .{
                            .field_ptr = &@field(outer_field, "val"),
                            .name = info.name,
                            .default_val = default_val,
                        };
                    },

                    Signal => {
                        const default_val = info.defaultValue() orelse default_signal;

                        buf[idx] = .{
                            .field_ptr = &@field(t, @tagName(port)),
                            .name = info.name,
                            .default_val = default_val,
                        };
                    },
                    else => {},
                }
            }

            return buf;
        }

        pub fn getPort(ptr: *anyopaque, field_str: []const u8) PortField {
            const t: *T = @ptrCast(@alignCast(ptr));

            inline for (t_ins ++ t_outs) |port| {
                if (std.mem.eql(u8, @tagName(port), field_str)) {
                    const info = std.meta.fieldInfo(T, port);

                    switch (info.type) {
                        DirSignal(.in), DirSignal(.out) => {
                            var outer_field = &@field(t, @tagName(port));
                            const default_val = if (info.defaultValue()) |def| def.val else default_signal;

                            return .{
                                .field_ptr = &@field(outer_field, "val"),
                                .name = info.name,
                                .default_val = default_val,
                            };
                        },
                        Signal => {
                            const default_val = info.defaultValue() orelse default_signal;

                            return .{
                                .field_ptr = &@field(t, @tagName(port)),
                                .name = info.name,
                                .default_val = default_val,
                            };
                        },
                        else => {},
                    }
                }
            }

            unreachable;
        }
    };
}
// comptime directional signal idea. The structural distinction between "in" and "out" is trivial, but I wanted a good way to distinguish
// at comptime without digging into signal field default values or names. Got it's own jank, though.
pub const SignalDirection = enum { in, out };
pub const ValueTag = enum { f, i };

pub fn DirSignal(comptime dir: SignalDirection) type {
    return struct {
        dir: SignalDirection = dir,
        val: Signal,

        const Self = @This();

        pub fn get(s: Self) f32 {
            return s.val.get();
        }

        pub fn set(s: Self, v: f32) void {
            return s.val.set(v);
        }
    };
}
pub const In = DirSignal(.in);
pub const Out = DirSignal(.out);

test "DirSignal types differentiable?" {
    const t = std.testing;
    _ = t; // autofix
    // TODO: validate what we can and cant do with types here, there's
    // juice to be squeezed
}

test "Ports for directional signals" {
    const t = std.testing;

    const Wobble = struct {
        id: []const u8 = "wobb",

        base_pitch: DirSignal(.in) = .{ .val = .{ .static = 440.0 } },
        frequency: DirSignal(.in) = .{ .val = .{ .static = 10.0 } },
        amp: DirSignal(.in) = .{ .val = .{ .static = 10.0 } },

        out: DirSignal(.out) = .{ .val = .{ .static = 0.0 } },

        old_signal: Signal = .{ .static = 5.0 },

        phase: f32 = 0,
    };

    var wobb = Wobble{};

    const P = Ports(Wobble);

    try t.expectEqual(
        P.getPort(&wobb, "base_pitch"),
        PortField{
            .field_ptr = &wobb.base_pitch.val,
            .name = "base_pitch",
            .default_val = .{ .static = 440.0 },
        },
    );

    try t.expectEqual(
        3,
        P.ins(&wobb).len,
    );
}
