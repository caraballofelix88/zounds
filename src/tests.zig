const std = @import("std");

pub const main = @import("main.zig");

// envelopes, ramps
pub const envelope = @import("envelope.zig");

// file reader
pub const wav = @import("readers/wav.zig");

pub const coreaudio = @import("backends/coreaudio.zig");

pub const clock = @import("clock.zig");
pub const convert = @import("convert.zig");
pub const signals = @import("signals.zig");

test {
    std.testing.refAllDecls(@This());
}
