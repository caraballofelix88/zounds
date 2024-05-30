const builtin = @import("builtin");
const std = @import("std");

// multi-backend structure idea lifted wholesale from mach engine audio lib
// https://github.com/hexops/mach/blob/main/src/sysaudio/backends.zig

pub const Backend = std.meta.Tag(Context);

pub const Context = switch (builtin.os.tag) {
    .macos => union(enum) {
        coreaudio: *@import("coreaudio.zig").Context,
        dummy: *@import("dummy.zig").Context,
    },
    else => union(enum) { dummy: *@import("dummy.zig").Context },
};

//
pub const Player = switch (builtin.os.tag) {
    .macos => union(enum) {
        coreaudio: *@import("coreaudio.zig").Player,
        dummy: *@import("dummy.zig").Player,
    },
    else => union(enum) { dummy: *@import("dummy.zig").Player },
};

// TODO: MIDIClient should get the same breakout treatment
const MidiClient = struct {};
