const std = @import("std");

const log = std.log.scoped(.adjmatrix);

pub const Error = error{BadTopographicList};

// TODO: it's probably better to do a single [N * M] array instead of
// N arrays of size M
fn AdjMatrix(size: u16) type {
    return [size][size]f32;
}

pub fn indegree(mat: anytype, size: u16, idx: u16) u16 {
    var result: u16 = 0;
    for (0..size) |i| {
        if (mat[idx][i]) {
            result += 1;
        }
    }
    return result;
}

pub fn outdegree(mat: anytype, size: u16, idx: u16) u16 {
    var result: u16 = 0;
    for (0..size) |i| {
        if (mat[i][idx]) {
            result += 1;
        }
    }
    return result;
}

pub fn topographicList(mat: anytype, size: u16, ret: []u16, queue_buf: []u16) !void {
    var queue: std.Deque(u16) = .initBuffer(queue_buf);
    var processed: u16 = 0;

    for (0..size) |idx| {
        if (indegree(mat, size, @intCast(idx)) == 0) {
            try queue.pushBackBounded(@intCast(idx));
        }
    }

    while (queue.popFront()) |visited_idx| {
        ret[processed] = visited_idx;
        processed += 1;
        for (0..size) |idx| {
            if (mat[idx][visited_idx]) {
                mat[idx][visited_idx] = false;
                if (indegree(mat, size, @intCast(idx)) == 0) {
                    try queue.pushBackBounded(@intCast(idx));
                }
            }
        }
    }

    // typically means a cycle's been detected
    if (processed < size) {
        log.warn("uh oh, somethings up. Likely cycle found.\n", .{});
        log.warn("processed: {}, list_size: {}", .{ processed, size });
        std.log.warn("process list so far: {any}", .{ret});
        return Error.BadTopographicList;
    }
}

test {
    // TK, like all the other tests
}
