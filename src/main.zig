const std = @import("std");
const coreaudio = @import("backends/coreaudio.zig");
pub const sources = @import("sources/main.zig");
const osc = @import("sources/osc.zig");

const adder = @import("adder/main.zig");

pub const wav = @import("readers/wav.zig");

pub const utils = @import("utils.zig");

pub const filters = @import("filters.zig");

pub const envelope = @import("envelope.zig");

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

pub const Context = struct {
    pub const Config = struct {
        sample_format: SampleFormat,
        sample_rate: u32,
        channel_count: u8,
        frames_per_packet: u8,
    };
};

pub const sineWave = osc.bigWave;
pub const hiss = osc.hiss;
pub const WavetableIterator = osc.WavetableIterator;

pub const ChannelPosition = enum { left, right };

pub const CoreAudioContext = coreaudio.Context;

pub const Device = struct { ptr: *anyopaque, name: []u8, channels: []ChannelPosition, sample_rate: u24, sample_fmt: SampleFormat };
