const std = @import("std");
const testing = std.testing;

const main = @import("../main.zig");

// reference: http://soundfile.sapp.org/doc/WaveFormat/

pub const WavFileData = struct {
    file_size: u32,
    format_length: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    format: main.FormatData,
};

// pub const Field = struct { name: []u8, size_bytes: u8, field_type: type, is_big_endian: bool = false, optional: bool = false };
//
// pub fn FileSpec(comptime T: type) type {
//     return struct { fields: []Field, spec_type: T };
// }

// const wav_spec = FileSpec{
//     .spec_type = WavFormatData,
//     .fields = .{
//         .{ .name = "RAFF", .size_bytes = 4, .field_type = u8, .optional = true },
//         .{ .name = "file_size", .size_bytes = 4, .field_type = u8, .optional = true },
//     },
// };
//
// pub fn parseData(reader: std.io.Reader, spec: FileSpec) WavFormatData {
//     _ = reader;
//
//     var out = spec.spec_type{};
//
//     inline for (spec.fields) |spec_field| {}
// }

// shoutouts to the mach folks
// TODO: move to its own file
fn convert(comptime SourceType: type, comptime DestType: type, source: []SourceType, dest: []DestType) void {
    // lets start with a single concrete case for now
    // std.debug.assert(SourceType == u16 and DestType == f32)

    //TODO: assert source data will fit in dest

    switch (DestType) {
        f32 => {
            switch (SourceType) {
                u16 => {
                    for (source, dest) |*src_sample, *dst_sample| {
                        const half = (std.math.maxInt(SourceType) + 1) / 2;
                        dst_sample.* = (@as(DestType, @floatFromInt(src_sample.*)) - half) * 1.0 / half;
                    }
                },
                i16 => {
                    const max: comptime_float = std.math.maxInt(SourceType) + 1;
                    const inv_max = 1.0 / max;
                    for (source, dest) |*src_sample, *dst_sample| {
                        dst_sample.* = @as(DestType, @floatFromInt(src_sample.*)) * inv_max;
                    }
                },
                f32 => { // just copy the data over
                    @memcpy(dest, source);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "convert.i16 -> f32" {
    const epsilon = 0.001;
    var source: [3]i16 = .{ 0, 32767, -32768 };
    const expected: [3]f32 = .{ 0.0, 1.0, -1.0 };
    var dest: [3]f32 = undefined;

    convert(i16, f32, &source, &dest);

    for (expected, dest) |a, b| {
        try testing.expectApproxEqAbs(a, b, epsilon);
    }
}

test "convert.u16 -> f32" {
    const epsilon = 0.001;
    var source: [3]u16 = .{ 0, 32_768, 65_535 };
    const expected: [3]f32 = .{ -1.0, 0.0, 1.0 };
    var dest: [3]f32 = undefined;

    convert(u16, f32, &source, &dest);

    for (expected, dest) |a, b| {
        try testing.expectApproxEqAbs(a, b, epsilon);
    }
}

// TODO: maybe generalize file header parsing
pub fn readWav(alloc: std.mem.Allocator, dir: []const u8) !main.AudioBuffer {
    var file = try std.fs.cwd().openFile(dir, .{});
    defer file.close();

    var buffer = std.io.bufferedReader(file.reader());
    var reader = buffer.reader();

    // read RIFF description
    const riff_bytes = try reader.readBytesNoEof(4);
    std.debug.print("\t{s}RAFF\n", .{riff_bytes});

    const file_size_raw = try reader.readBytesNoEof(4);
    const file_size = std.mem.bytesToValue(u32, &file_size_raw);
    std.debug.print("File size (B):\t{}\n", .{file_size});

    const wavefmt = try reader.readBytesNoEof(4 + 4); // 'WAVE' + 'fmt '
    std.debug.print("{s}\n", .{wavefmt});

    const format_length_raw = try reader.readBytesNoEof(4);
    const format_length = std.mem.bytesToValue(u32, &format_length_raw);
    std.debug.print("Format data size:\t{}\n", .{format_length});

    const format_type_raw = try reader.readBytesNoEof(2);
    const format_type = std.mem.bytesToValue(u16, &format_type_raw);
    std.debug.print("Format Type (1 is PCM):\t{}\n", .{format_type});

    const num_channels_raw = try reader.readBytesNoEof(2);
    const num_channels = std.mem.bytesToValue(u16, &num_channels_raw);
    std.debug.print("Number of channels:\t{}\n", .{num_channels});

    const sample_rate_raw = try reader.readBytesNoEof(4);
    const sample_rate = std.mem.bytesToValue(u32, &sample_rate_raw);
    std.debug.print("Sample rate:\t{}\n", .{sample_rate});

    // (Sample Rate * BitsPerSample * Channels) / 8
    // https://docs.fileformat.com/audio/wav/
    const byte_rate_raw = try reader.readBytesNoEof(4);
    const byte_rate = std.mem.bytesToValue(u32, &byte_rate_raw);
    std.debug.print("Byte rate:\t{}\n", .{byte_rate});

    const block_align_raw = try reader.readBytesNoEof(2);
    const block_align = std.mem.bytesToValue(u16, &block_align_raw);
    std.debug.print("Block align:\t{}\n", .{block_align});

    // (BitsPerSample * Channels) / 8.1 - 8 bit mono2 - 8 bit stereo/16 bit mono4 - 16 bit stereo
    // https://docs.fileformat.com/audio/wav/
    const bits_per_sample_raw = try reader.readBytesNoEof(2);
    const bits_per_sample = std.mem.bytesToValue(u16, &bits_per_sample_raw);
    std.debug.print("bits per sample:\t{}\n", .{bits_per_sample});

    const data_header = try reader.readBytesNoEof(4);
    _ = data_header;

    const data_section_size = try reader.readBytesNoEof(4);
    _ = data_section_size;

    const slice = try reader.readAllAlloc(alloc, std.math.maxInt(usize));

    var base_buffer: main.AudioBuffer = .{
        .format = .{
            .num_channels = num_channels,
            .sample_rate = sample_rate,
            .sample_format = .i16,
        },
        .buf = slice,
    };

    const source_slice: []i16 = @alignCast(std.mem.bytesAsSlice(i16, slice));
    const dest_slice = try alloc.alloc(f32, source_slice.len);

    convert(i16, f32, source_slice, dest_slice);

    base_buffer.format.sample_format = .f32;
    base_buffer.buf = std.mem.sliceAsBytes(dest_slice);

    const track_length = base_buffer.trackLength();
    std.debug.print("Track length:\t{}:{d:2}\n", .{ @divFloor(track_length, 60), @mod(track_length, 60) });

    return base_buffer;
}

test "readWav" {
    const dir = "../../res/evil_laugh.wav";
    const file = try readWav(testing.allocator, dir);
    defer testing.allocator.free(file.buf);

    // TODO: assert correct specs
    try testing.expectEqual(44_100, file.format.sample_rate);
    try testing.expectEqual(.i16, file.format.sample_format);
    try testing.expectEqual(1, file.format.num_channels);
}
