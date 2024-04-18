const std = @import("std");
const signals = @import("signals.zig");
const testing = std.testing;

// amazing reference for MIDI spec: http://www.somascape.org/midi/tech/spec.html

// TODO: keep abusing tagged unions? Some kinds could use addl data
pub const Kind = enum {
    // Channel Voice messages
    note_off,
    note_on,
    polyphonic_key_pressure,
    controller,
    program_change,
    channel_pressure,
    pitch_bend,

    // Channel Mode Messages
    channel_mode,

    // System messages
    system_exclusive,
    system_common,
    system_real_time,
};

pub const Status = packed struct(u8) {
    value: u8,

    pub fn kind(s: Status) Kind {
        const _kind: u3 = @truncate(s.value >> 4);
        return switch (_kind) {
            0x0 => .note_off,
            0x1 => .note_on,
            0x2 => .polyphonic_key_pressure,
            0x3 => .controller,
            0x4 => .program_change,
            0x5 => .channel_pressure,
            0x6 => .pitch_bend,

            // TODO: rest of kinds
            else => unreachable,
        };
    }

    pub fn channel(s: Status) u4 {
        return @truncate(s.value);
    }

    // size of expected data in bytes
    pub fn dataSize(s: Status) u8 {
        return switch (s.kind()) {
            .note_off, .note_on, .polyphonic_key_pressure, .controller, .pitch_bend, .channel_mode => 2,
            .program_change, .channel_pressure => 1,
            .system_real_time => 0,

            //TODO: weird cases, find a good way to handle or throw
            .system_exclusive, .system_common => unreachable,
        };
    }

    pub fn fromByte(data: u8) ?Status {
        if (data & 0x80 != 0) {
            return Status{ .value = data };
        } else {
            return null;
        }
    }
};

test "Status" {
    const ex_note_on = [_]u8{ 0x90, 0x43, 0x29 };

    const status = Status.fromByte(ex_note_on[0]).?;

    try testing.expectEqual(.note_on, status.kind());
    try testing.expectEqual(0, status.channel());

    const no_status = Status.fromByte(0x70);
    try testing.expectEqual(null, no_status);
}

// TODO: sysex won't work w this data structure
pub const Message = struct {
    status: Status,
    data: u16 = undefined, // pair of 7-bit values packed together
    pub fn fromBytes(data: []const u8, prev_status: ?Status) !Message {
        if (data.len == 0) {
            unreachable; // TODO: figure out real errors
        }

        var status: Status = undefined;
        var from: usize = 1;

        if (Status.fromByte(data[0])) |s| {
            if (s.kind() == .system_exclusive) {
                unreachable; // TODO: something else should happen to allow support for sysex
            }

            if (data.len < s.dataSize() + 1) {
                unreachable;
            }

            status = s;
        } else if (prev_status) |s| {
            if (data.len < s.dataSize()) {
                unreachable;
            }

            status = s;
            from = 0;
        } else {
            // if we don't have an old status, ???
            unreachable;
        }

        // cant pack byte array, so we're holding onto message data as an int. We'll need to keep endianness straight ourselves.
        const data_val = std.mem.bytesToValue(u16, data[from .. from + status.dataSize()]);
        return Message{ .status = status, .data = std.mem.nativeToBig(u16, data_val) };
    }
};

test "Message" {
    const ex_note_on = [_]u8{ 0x90, 0x43, 0x29 };

    const msg = try Message.fromBytes(&ex_note_on, null);
    try testing.expectEqual(.note_on, msg.status.kind());
    try testing.expectEqual(msg.data, 0x4329);

    const running_status = msg.status;
    const running_msg = try Message.fromBytes(&.{ 0x44, 0x29 }, running_status);
    try testing.expectEqual(.note_on, running_msg.status.kind());
}
