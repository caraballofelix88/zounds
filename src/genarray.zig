const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.genarray);

pub const Error = error{
    NoMoreSpace,
    OutOfBounds,
};

// TODO: extend to multiarraylist?
pub fn GenArray(comptime T: type, comptime capacity: u16) type {
    const Generation = u8;
    const Index = u16;
    const Fifo = std.fifo.LinearFifo(Index, .{ .Static = capacity });

    return struct {
        items: [capacity]T = undefined,
        gens: [capacity]Generation = [_]Generation{0} ** capacity,
        // TODO: test
        is_alive: [capacity]bool = [_]bool{false} ** capacity,
        free_list: Fifo = Fifo.init(),
        len: Index = 0,

        pub const Handle = struct {
            gen: Generation,
            idx: Index,
        };

        pub const Self = @This();

        inline fn isValidHandle(g: *Self, hdl: Handle) bool {
            return g.gens[hdl.idx] <= hdl.gen;
        }

        pub fn isAlive(g: *Self, idx: Index) bool {
            return g.is_alive[idx];
        }

        // should return handle?
        pub fn push(g: *Self, val: T) !Handle {
            var recycled = false;
            var next_spot = g.len;

            if (g.free_list.readItem()) |free_spot| {
                recycled = true;
                next_spot = free_spot;
            } else {
                if (g.len == capacity) {
                    return Error.NoMoreSpace;
                }
            }

            g.items[next_spot] = val;
            g.is_alive[next_spot] = true;

            if (!recycled) {
                g.len += 1;
            }

            return .{
                .gen = g.gens[next_spot],
                .idx = next_spot,
            };
        }

        pub fn get(g: *Self, hdl: Handle) ?T {
            // TODO: what happens if we we get a number >= capacity?
            if (!g.isValidHandle(hdl)) {
                log.debug("lol null: {}", .{hdl});
                return null;
            }

            return g.items[hdl.idx];
        }

        pub fn delete(g: *Self, hdl: Handle) !void {
            if (!g.isValidHandle(hdl)) {
                return;
            }
            // TODO: generation needs to account for max representable number
            g.gens[hdl.idx] += 1;
            g.is_alive[hdl.idx] = false;
            _ = try g.free_list.writeItem(hdl.idx);
        }

        pub fn put(g: *Self, hdl: Handle, val: T) !void {
            if (hdl.idx > capacity) {
                return Error.OutOfBounds;
            }

            if (!g.isValidHandle(hdl)) {
                return;
            }

            g.items[hdl.idx] = val;
            g.gens[hdl.idx] += 1;
            g.is_alive[hdl.idx] = true;

            return .{
                .gen = hdl.gen + 1,
                .idx = hdl.idx,
            };
        }

        // Update value without incrementing generation
        pub fn set(g: *Self, hdl: Handle, val: T) !void {
            if (hdl.idx > capacity) {
                return Error.OutOfBounds;
            }

            //std.log.debug("setting w/ handle {}, current gen {}", .{ hdl, g.gens[hdl.idx] });
            if (!g.isValidHandle(hdl)) {
                return;
            }
            g.items[hdl.idx] = val;
        }

        // TODO: checks, do we need this?
        pub fn getPtr(g: *Self, hdl: Handle) *T {
            return &g.items[hdl.idx];
        }

        // What do old handles do here?
        pub fn clear(g: *Self) void {
            g.len = 0;
            g.gens = [_]u8{0} ** capacity;
            g.is_alive = [_]bool{false} ** capacity;
            g.free_list.discard(capacity);
        }

        // TODO: rename
        pub fn itemSlice(g: *Self) []T {
            return g.items[0..g.len];
        }

        pub fn liveLen(g: Self) u16 {
            return g.len - g.free_list;
        }

        // NEXT: we cant do any real operations on our lists without this
        // Consider keeping 2 lists of indices, for live and dead entries?
        pub fn iteratorForAliveEntries(g: *Self) []T {
            _ = g;
        }
    };
}

test "Genarray" {
    var garr = GenArray(u16, 8){};

    _ = try garr.push(1);
    const a = try garr.push(2);
    const b = try garr.push(3);
    _ = try garr.push(4);
    _ = try garr.push(5);
    _ = try garr.push(6);
    _ = try garr.push(7);
    _ = try garr.push(8);

    try testing.expectEqual(8, garr.len);
    try testing.expectError(Error.NoMoreSpace, garr.push(9));

    try garr.delete(b);
    try garr.delete(a);

    _ = try garr.push(1001);
    _ = try garr.push(1002);

    try testing.expectEqual(garr.get(.{ .gen = 1, .idx = 1 }), 1002);
    try testing.expectEqual(garr.get(.{ .gen = 1, .idx = 2 }), 1001);
    try testing.expectEqual(garr.get(.{ .gen = 0, .idx = 0 }), 1);
}
