const std = @import("std");
const testing = std.testing;

const main = @import("../main.zig");
const convert = @import("../convert.zig");

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

// TODO: maybe generalize file header parsing
// Perhaps follow through with the "Field" stuff above?
// NOTE: duplicates input data, doesn't own the incoming slice
pub fn readWav(alloc: std.mem.Allocator, data: []const u8) !main.AudioBuffer {
    var buffer = std.io.fixedBufferStream(data);
    const reader = buffer.reader();

    // read RIFF description
    const riff_bytes = try reader.readBytesNoEof(4);
    _ = riff_bytes;

    const file_size_raw = try reader.readBytesNoEof(4);
    const file_size = std.mem.bytesToValue(u32, &file_size_raw);
    _ = file_size;

    const wavefmt = try reader.readBytesNoEof(4 + 4); // 'WAVE' + 'fmt '
    _ = wavefmt;

    const format_length_raw = try reader.readBytesNoEof(4);
    const format_length = std.mem.bytesToValue(u32, &format_length_raw);
    _ = format_length;

    const format_type_raw = try reader.readBytesNoEof(2);
    const format_type = std.mem.bytesToValue(u16, &format_type_raw);
    _ = format_type;

    const num_channels_raw = try reader.readBytesNoEof(2);
    const num_channels = std.mem.bytesToValue(u16, &num_channels_raw);

    const sample_rate_raw = try reader.readBytesNoEof(4);
    const sample_rate = std.mem.bytesToValue(u32, &sample_rate_raw);

    // (Sample Rate * BitsPerSample * Channels) / 8
    // https://docs.fileformat.com/audio/wav/
    const byte_rate_raw = try reader.readBytesNoEof(4);
    const byte_rate = std.mem.bytesToValue(u32, &byte_rate_raw);
    _ = byte_rate;

    const block_align_raw = try reader.readBytesNoEof(2);
    const block_align = std.mem.bytesToValue(u16, &block_align_raw);
    _ = block_align;

    // (BitsPerSample * Channels) / 8.1 - 8 bit mono2 - 8 bit stereo/16 bit mono4 - 16 bit stereo
    // https://docs.fileformat.com/audio/wav/
    const bits_per_sample_raw = try reader.readBytesNoEof(2);
    const bits_per_sample = std.mem.bytesToValue(u16, &bits_per_sample_raw);
    _ = bits_per_sample;

    const data_header = try reader.readBytesNoEof(4);
    _ = data_header;

    const data_section_size = try reader.readBytesNoEof(4);
    _ = data_section_size;

    const slice = try reader.readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var base_buffer: main.AudioBuffer = .{
        .format = .{
            .channels = main.ChannelPosition.fromChannelCount(num_channels),
            .sample_rate = sample_rate,
            .sample_format = .i16,
        },
        .buf = slice,
    };

    const source_slice: []i16 = @alignCast(std.mem.bytesAsSlice(i16, slice));
    const dest_slice = try alloc.alloc(f32, source_slice.len);

    convert.convert(i16, f32, source_slice, dest_slice);

    base_buffer.format.sample_format = .f32;
    base_buffer.buf = std.mem.sliceAsBytes(dest_slice);

    const track_length = base_buffer.trackLength();
    _ = track_length;
    //std.debug.print("Track length:\t{}:{d:2}\n", .{ @divFloor(track_length, 60), @mod(track_length, 60) });

    return base_buffer;
}

pub fn readWavFile(alloc: std.mem.Allocator, dir: []const u8) !main.AudioBuffer {
    var file = try std.fs.cwd().openFile(dir, .{});
    defer file.close();

    const file_buf = try file.readToEndAlloc(alloc, std.math.maxInt(u32));
    defer alloc.free(file_buf);

    return try readWav(alloc, file_buf);
}

test "readWavFile" {
    const dir = "res/test.wav";
    const file = try readWavFile(testing.allocator, dir);
    defer testing.allocator.free(file.buf);

    try testing.expectEqual(44_100, file.format.sample_rate);
    try testing.expectEqual(.f32, file.format.sample_format);
    try testing.expectEqual(1, file.format.channels.len);
}

test "readWav" {
    const dir = "res/test.wav";
    var file = try std.fs.cwd().openFile(dir, .{});
    defer file.close();

    const file_buf = try file.readToEndAlloc(testing.allocator, std.math.maxInt(u32));
    defer testing.allocator.free(file_buf);

    const buf = try readWav(testing.allocator, file_buf);
    defer testing.allocator.free(buf.buf);

    try testing.expectEqual(44_100, buf.format.sample_rate);
    try testing.expectEqual(.f32, buf.format.sample_format);
    try testing.expectEqual(1, buf.format.channels.len);
}
