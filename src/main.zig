const std = @import("std");
pub const coreaudio = @import("backends/coreaudio.zig");
pub const sources = @import("sources/main.zig");
pub const osc = @import("sources/osc.zig");
pub const wav = @import("readers/wav.zig");
pub const utils = @import("utils.zig");
pub const filters = @import("filters.zig");
pub const envelope = @import("envelope.zig");
pub const signals = @import("signals.zig");
pub const midi = @import("midi.zig");

pub const Player = coreaudio.Player;

pub const SampleFormat = enum {
    f32,
    i16,

    pub fn size(fmt: SampleFormat) u8 {
        return bitSize(fmt) / 8;
    }

    pub fn bitSize(fmt: SampleFormat) u8 {
        return switch (fmt) {
            .f32 => 32,
            .i16 => 16,
        };
    }

    pub fn fmtType(comptime fmt: SampleFormat) type {
        return switch (fmt) {
            .f32 => f32,
            .i16 => i16,
        };
    }
};

pub const FormatData = struct {
    sample_format: SampleFormat,
    num_channels: u16,
    sample_rate: u32,
    is_interleaved: bool = true, // channel samples interleaved?

    pub fn frameSize(f: FormatData) usize {
        return f.sample_format.size() * f.num_channels;
    }
};

pub const AudioBuffer = struct {
    format: FormatData,
    buf: []u8,

    pub fn sampleCount(b: AudioBuffer) usize {
        return b.buf.len / b.format.sample_format.size();
    }

    pub fn frameCount(b: AudioBuffer) usize {
        return b.buf.len / b.format.frameSize();
    }

    pub fn trackLength(b: AudioBuffer) usize {
        return b.sampleCount() / b.format.sample_rate;
    }
};

// Context structure ideas:
//
// - desired audio output
// - audio graph
// - available midi device inputs
// - current connected midi device input

pub const Context = struct {
    pub const Config = struct {
        sample_format: SampleFormat,
        sample_rate: u32,
        channel_count: u8,
        frames_per_packet: u8,
    };
};

pub const ChannelPosition = enum { left, right };

pub const CoreAudioContext = coreaudio.Context;

pub const Device = struct { ptr: *anyopaque, name: []u8, channels: []ChannelPosition, sample_rate: u24, sample_fmt: SampleFormat };
