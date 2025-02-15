const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.genarray);

pub const Error = error{
    NoMoreSpace,
    OutOfBounds,
};

pub fn GenArray(comptime T: type, comptime capacity: u16) type {
    const Generation = u8;
    const Index = u16;
    const Fifo = std.fifo.LinearFifo(Index, .{ .Static = capacity });

    return struct {
        items: [capacity]T = undefined,
        gens: [capacity]Generation = [_]Generation{0} ** capacity,
        free_list: Fifo = Fifo.init(),
        len: Index = 0,

        pub const Self = @This();

        // should return handle?
        pub fn push(g: *Self, val: T) !Generation {
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

            if (!recycled) {
                g.len += 1;
            }

            return g.gens[next_spot];
        }

        pub fn get(g: *Self, idx: Index, gen: Generation) ?T {
            // TODO: what happens if we we get a number >- capacity
            if (g.gens[idx] > gen) {
                return null;
            }

            return g.items[idx];
        }

        // is this necessary?
        pub fn getGen(g: *Self, idx: Index) Generation {
            return g.gens[idx];
        }

        pub fn invalidateEntry(g: *Self, idx: Index) !void {
            // TODO: generation needs to account for max representable number
            g.gens[idx] += 1;
            _ = try g.free_list.writeItem(idx);
        }

        pub fn put(g: *Self, idx: Index, val: T) !Generation {
            if (idx > capacity) {
                return Error.OutOfBounds;
            }
            g.items[idx] = val;

            // g.indices[idx] += 1;

            return g.gens[idx];
        }
    };
}

test "Genarray" {
    var garr = GenArray(u16, 8){};

    _ = try garr.push(1);
    _ = try garr.push(2);
    _ = try garr.push(3);
    _ = try garr.push(4);
    _ = try garr.push(5);
    _ = try garr.push(6);
    _ = try garr.push(7);
    _ = try garr.push(8);

    try testing.expectEqual(8, garr.len);
    try testing.expectError(Error.NoMoreSpace, garr.push(9));

    try garr.invalidateEntry(2);
    try garr.invalidateEntry(1);

    _ = try garr.push(1001);
    _ = try garr.push(1002);

    try testing.expectEqual(garr.getGen(1), 1);

    try testing.expectEqual(garr.get(1, 1), 1002);
    try testing.expectEqual(garr.get(2, 1), 1001);
}
