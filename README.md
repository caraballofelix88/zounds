# Zounds

> [!CAUTION]
> Please please please do watch your ears when using this software.
> Bugs could cause unexpected output that results in damage to audio devices or
> even your hearing!

A minimal, zero-dependency signal graph processing toolkit, geared toward audio
synthesis.

Zounds is primarily a personal exploration in systems programming,
DSP, and how to build from scratch, and it has been a lovely learning experience
so far. As a result, the feature set is limited and certainly not production
ready. This library remains a work in progress: try not to use it for anything
super important just yet!

This library has been initially designed with the expectation it could run
reasonably well on embedded hardware. My aim is to keep memory footprint and
computation as predictable and as compact as possible. Zig has been particularly
great for this, as it allows for right-sized graph types, waveforms, and other
things defined at compile time, as well as flexibility with allocation.

Currently, the MIDI and audio playback backends only work for MacOS, but the
signal graph's output can be used with any backend as long as you provide it
yourself.


## How does it work?
Architecture docs TK


## Adding to your stuff
In `build.zig`, add the dependency:
```zig
//...
const zounds_dep = b.dependency("zounds", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "example",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zounds", .module = zounds_dep.module("zounds") },
        },
    }),
});
//...
```


Then, in your main, initialize the necessary contexts:
```zig
const format: fmt.FormatData = .{
    .sample_format = .f32,
    .sample_rate = 44_100,
    .channels = fmt.ChannelPosition.fromChannelCount(2),
    .is_interleaved = true,
};
const config: zounds.backend_context.ContextConfig = .{ .frames_per_packet = 1, .desired_format = format };
```

Create a zounds Graph instance:
```zig
var signal_graph = zounds.Graph(.{ .channel_count = 2 }){ .format = format };
const graph_ctx = signal_graph.context();
```

Initialize a Node:
```zig
var osc = zounds.dsp.Oscillator{ .ctx = graph_ctx, .pitch = .{ .static = 440.0 } };
const osc_hdl = try graph_ctx.register(&osc);
var osc_node = graph_ctx.getNode(osc_hdl).?;

signal_graph.root_signal = osc_node.port("out").field_ptr.*;
```

and attach it to a Player and play:
```zig
fn writeFn(write_ref: *anyopaque, buf: []u8, num_frames: usize) void {
    const graph: *zounds.GraphContext = @ptrCast(@alignCast(write_ref));
    const samples: []align(1) f32 = std.mem.bytesAsSlice(f32, buf);
    const channels = graph.opts.channel_count;

    for (0..num_frames) |i| {
        @memcpy(samples[i * channels ..][0..channels], graph.next());
    }
}

//...then elsewhere:

var player = try player_ctx.createPlayer(device, &writeFn, .{
    .write_ref = @ptrCast(@constCast(graph_ctx)),
    .format = format,
});
defer player.deinit();
_ = try player.setVolume(-20.0);

player.play();
try std.Io.sleep(init_data.io, .fromSeconds(1), .real);
```

Phew! Not too bad!


### Examples (Under Construction)
Take a peek at the `/examples` folder to see what we can do, and how you might
be able to use it for your projects.

Run any of the examples with `zig build run -Dexample_name={example}`. For now,
only the `tada` example works.
