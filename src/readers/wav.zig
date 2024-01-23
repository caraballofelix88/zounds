const std = @import("std");
const testing = std.testing;

// reference: http://soundfile.sapp.org/doc/WaveFormat/
//
//

// bytes 0 - 12: RIFF description
// ChunkId(4)
// ChunkSize(4)
//
// bytes 12 - 36: "fmt" subchunk

const EOF: u8 = 0x03;

pub fn readWav(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    var arrayList = std.ArrayList(u8).init(alloc);

    var file = try std.fs.cwd().openFile(dir, .{});
    defer file.close();

    var buffer = std.io.bufferedReader(file.reader());
    var reader = buffer.reader();

    var chunk1 = try reader.readBytesNoEof(12);
    _ = chunk1;

    // Assumes PCM format, where format has no extra params
    var subChunk = try reader.readBytesNoEof(24);
    _ = subChunk;

    // assuming f32, mono, 44_100hz (non-exhaustive list of assumptions)
    _ = try reader.streamUntilDelimiter(arrayList.writer(), EOF, null);

    return arrayList.toOwnedSlice();
}

test "readWav" {
    const dir = "res/evil_laugh.wav";
    var fileBuf = try readWav(testing.allocator, dir);
    defer testing.allocator.free(fileBuf);
}
