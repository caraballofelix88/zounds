const std = @import("std");

const zgui = @import("zgui");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");

const zounds = @import("zounds");

const window_title = "zights and zounds";

pub fn main() !void {
    _ = try zglfw.init();
    defer zglfw.terminate();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const window = try zglfw.Window.create(400, 400, window_title, null);
    defer window.destroy();
    window.setSizeLimits(1400, 1400, -1, -1);

    const gctx = try zgpu.GraphicsContext.create(alloc, window, .{});
    defer gctx.destroy(alloc);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    zgui.init(alloc);
    defer zgui.deinit();

    _ = zgui.backend.init(
        window,
        gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    zgui.getStyle().scaleAllSizes(scale_factor);

    // UI state
    var vol: f32 = 0;
    var pitchNote: i32 = 76;

    const config = zounds.Context.Config{ .sample_format = .f32, .sample_rate = 44_100, .channel_count = 2, .frames_per_packet = 1 };
    var waveIterator: zounds.WavetableIterator = zounds.WavetableIterator{
        .wavetable = @constCast(&zounds.sineWave),
        .pitch = 440.0,
        .sample_rate = 44_100,
    };

    const playerContext = try zounds.CoreAudioContext.init(alloc, config);
    defer playerContext.deinit();

    const player = try playerContext.createPlayer(@constCast(&waveIterator.source()));

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();

        zgui.backend.newFrame(
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        );

        // Set the starting window position and size to custom values
        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

        if (zgui.begin("Player Controls", .{})) {
            if (player.is_playing) {
                if (zgui.button("Pause", .{ .w = 200.0 })) {
                    std.debug.print("Pausing player\n", .{});
                    player.pause();
                }
            } else {
                if (zgui.button("Play", .{ .w = 200.0 })) {
                    std.debug.print("Playing player\n", .{});
                    player.play();
                }
            }

            if (zgui.sliderFloat("Volume (dB)", .{
                .v = &vol,
                .min = 0.0,
                .max = 1.0,
            })) {
                // set Volume
                _ = try player.setVolume(vol);
            }
            if (zgui.sliderInt("Pitch", .{
                .v = &pitchNote,
                .min = 0,
                .max = 127,
            })) {
                // update pitch
                waveIterator.setPitch(zounds.utils.pitchFromNote(pitchNote));
            }
        }
        zgui.end();

        const swapchain_texv = gctx.swapchain.getCurrentTextureView();
        defer swapchain_texv.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            // GUI pass
            {
                const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
                defer zgpu.endReleasePass(pass);
                zgui.backend.draw(pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});
        _ = gctx.present();
    }
}
