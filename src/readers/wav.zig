const std = @import("std");
const testing = std.testing;

// reference: http://soundfile.sapp.org/doc/WaveFormat/

// bytes 0 - 12: RIFF description
// ChunkId(4)
// ChunkSize(4)
//
// bytes 12 - 36: "fmt" subchunk
//
//

// TODO: return results with more detail about the audio stream, pulled from header
// - sample rate
// - sample size
// - sample format
// - channel count + ids
// - etc.

pub fn readWav(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(dir, .{});
    defer file.close();

    var buffer = std.io.bufferedReader(file.reader());
    var reader = buffer.reader();

    // read RIFF description
    var chunk1 = try reader.readBytesNoEof(12);
    _ = chunk1;

    // Reads format data subchunk
    // Assumes PCM format, where format has no extra params
    var subChunk = try reader.readBytesNoEof(24);
    _ = subChunk;

    var data = try reader.readBytesNoEof(8);
    _ = try reader.readBytesNoEof(2); // theres some weird offset....
    std.debug.print("Heres the bytes:\t{any} : current head is {any}\n", .{ data, reader.context.start }); // "data    "

    // assuming f32, mono, 44_100hz (non-exhaustive list of assumptions)
    var slice = try reader.readAllAlloc(alloc, std.math.maxInt(usize));

    std.debug.print("How big is our buffer?\t {} bytes", .{slice.len});

    return slice; // return alloc-owned slice;
}

test "readWav" {
    const dir = "res/evil_laugh.wav";
    var fileBuf = try readWav(testing.allocator, dir);
    defer testing.allocator.free(fileBuf);
}
