const std = @import("std");

pub const main = @import("main.zig");

// envelopes, ramps
pub const envelope = @import("envelope.zig");

// file reader
pub const wav = @import("readers/wav.zig");

// audio sources
pub const bufferered = @import("sources/buffered.zig");
pub const osc = @import("sources/osc.zig");

pub const coreaudio = @import("backends/coreaudio.zig");

test {
    std.testing.refAllDecls(@This());
}
