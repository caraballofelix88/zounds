const std = @import("std");
const zounds = @import("zounds");

pub const ChordNode = struct {
    ctx: *zounds.signals.AudioContext,
    notes: [3]zounds.signals.Signal(f32),
    buf: [4]u8 = undefined,

    pub fn nextFn(ptr: *anyopaque) f32 {
        var n: *ChordNode = @ptrCast(@alignCast(ptr));

        const sum: f32 = (n.notes[0].get() + n.notes[1].get() + n.notes[2].get()) / 3.0;
        n.buf = @bitCast(sum);
        return sum;
    }

    pub fn node(n: *ChordNode) zounds.signals.Node(f32) {
        return .{ .ptr = n, .nextFn = nextFn };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const config = zounds.Context.Config{
        .sample_format = .f32,
        .sample_rate = 44_100,
        .channel_count = 2,
        .frames_per_packet = 1,
    };

    var audio_ctx = zounds.signals.AudioContext{ .sample_rate = 44_100 };
    var player_ctx = try zounds.CoreAudioContext.init(alloc, config);

    var trigger: bool = false;
    const trigger_sig: zounds.signals.Signal(bool) = .{ .ptr = &trigger };

    const adsr: [4]zounds.envelope.Ramp = .{
        .{ // attack
            .from = 0.0,
            .to = 1.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.05 },
        },
        .{ // decay
            .from = 1.0,
            .to = 0.7,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.5 },
        },
        .{ // sustain
            .from = 0.7,
            .to = 0.5,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.8 },
        },
        .{ // release
            .from = 0.5,
            .to = 0.0,
            .ramp_type = .linear,
            .sample_rate = 44_100,
            .duration = .{ .seconds = 0.3 },
        },
    };

    var env = zounds.envelope.Envelope.init(&adsr, trigger_sig);
    var chord_1 = zounds.signals.TestWavetableOscNode{
        .ctx = &audio_ctx,
        .pitch = .{ .static = zounds.utils.pitchFromNote(60) }, // C4
        .amp = env.node().signal(),
    };

    var chord_2 = zounds.signals.TestWavetableOscNode{
        .ctx = &audio_ctx,
        .pitch = .{ .static = zounds.utils.pitchFromNote(64) }, // E4
        .amp = env.node().signal(),
    };

    var chord_3 = zounds.signals.TestWavetableOscNode{
        .ctx = &audio_ctx,
        .pitch = .{ .static = zounds.utils.pitchFromNote(67) }, // G4
        .amp = env.node().signal(),
    };

    var chord = ChordNode{
        .ctx = &audio_ctx,
        .notes = .{ chord_1.node().signal(), chord_2.node().signal(), chord_3.node().signal() },
    };

    audio_ctx.sink = chord.node().signal();

    var context_source = audio_ctx.source();

    const player = try player_ctx.createPlayer(&context_source);
    _ = try player.setVolume(-20.0);

    player.play();

    trigger = true;
    std.debug.print("ta", .{});
    std.time.sleep(std.time.ns_per_ms * 180);

    trigger = false;
    std.time.sleep(std.time.ns_per_ms * 20);

    // dah~
    trigger = true;
    std.debug.print("-dah~\n", .{});
    std.time.sleep(std.time.ns_per_ms * 3000);
}
