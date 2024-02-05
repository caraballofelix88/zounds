const std = @import("std");
const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreAudio/CoreAudio.h");
    @cInclude("AudioUnit/AudioUnit.h");
});

const testing = std.testing;
const main = @import("../main.zig");
const sources = @import("../sources/main.zig");
const osc = @import("../sources/osc.zig");

// shoutouts to my mans jamal for planting the seeds -- https://gist.github.com/jamal/8ee096ca98759f83b4942f22d365d449

const DeviceState = enum {
    uninitialized,
    stopped,
    started,
    stopping,
    starting,
};

const DeviceBackend = enum { core_audio };

const default_sample_rate = 44_100; // 44.1khz

// TODO: might not need to keep all these pointers, just rebuild the config components each time
pub const Context = struct {
    alloc: std.mem.Allocator,
    acd: *c.AudioComponentDescription,
    asbd: *c.AudioStreamBasicDescription,
    device: *c.AudioComponent,
    audioUnit: *c.AudioUnit,
    devices: []main.Device, // TODO: list available devices

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: main.Context.Config) !Self {
        const acd = try allocator.create(c.AudioComponentDescription);

        acd.* = c.AudioComponentDescription{
            .componentType = c.kAudioUnitType_Output,
            .componentSubType = c.kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = c.kAudioUnitManufacturer_Apple,
            .componentFlags = std.mem.zeroes(u32), //TODO: what are these?
            .componentFlagsMask = std.mem.zeroes(u32),
        };

        // get next available audio component
        const device = try allocator.create(c.AudioComponent);
        device.* = c.AudioComponentFindNext(null, acd) orelse {
            std.debug.panic("error finding device \n", .{});
        };

        // capture audio unit instance for device
        const audioUnit = try allocator.create(c.AudioUnit);
        osStatusHandler(c.AudioComponentInstanceNew(device.*, audioUnit)) catch |err| {
            std.debug.panic("audio component instance failed: {}\n", .{err});
        };

        const asbd = try allocator.create(c.AudioStreamBasicDescription);

        // get audiounit stream description
        const bytesPerFrame = config.sample_format.size() * config.channel_count;
        asbd.* = c.AudioStreamBasicDescription{
            .mFormatID = c.kAudioFormatLinearPCM,
            // TODO: update audio format flags based on config.sample_format, or just force convert into f32
            .mFormatFlags = 0 | c.kAudioFormatFlagIsFloat,
            .mSampleRate = @as(f64, @floatFromInt(config.sample_rate)),
            .mBitsPerChannel = config.sample_format.bitSize(),
            .mChannelsPerFrame = config.channel_count,
            .mFramesPerPacket = config.frames_per_packet, // apparently should always be 1 for PCM output
            .mBytesPerFrame = bytesPerFrame,
            .mBytesPerPacket = bytesPerFrame * config.frames_per_packet,
            .mReserved = 0,
        };

        osStatusHandler(c.AudioUnitSetProperty(audioUnit.*, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Input, 0, asbd, @sizeOf(@TypeOf(asbd.*)))) catch |err| {
            std.debug.panic("failed to stream format: {}\n", .{err});
        };

        return .{ .alloc = allocator, .acd = acd, .asbd = asbd, .audioUnit = audioUnit, .device = device, .devices = &.{} };
    }

    pub fn deinit(self: Self) void {
        // stop audioUnit
        _ = c.AudioOutputUnitStop(self.audioUnit.*);
        _ = c.AudioUnitUninitialize(self.audioUnit.*);

        // dispose of instance
        _ = c.AudioComponentInstanceDispose(self.audioUnit.*);

        self.alloc.destroy(self.audioUnit);
        self.alloc.destroy(self.acd);
        self.alloc.destroy(self.asbd);
        self.alloc.destroy(self.device);
    }

    pub fn renderCallback(refPtr: ?*anyopaque, au_render_flags: [*c]c.AudioUnitRenderActionFlags, timestamp: [*c]const c.AudioTimeStamp, bus_number: c_uint, num_frames: c_uint, buffer_list: [*c]c.AudioBufferList) callconv(.C) c.OSStatus {
        _ = au_render_flags;
        _ = timestamp;
        _ = bus_number;

        var player: *Player = @ptrCast(@alignCast(refPtr));
        var source: *sources.AudioSource = @ptrCast(@alignCast(player.source));
        var iter: *osc.WavetableIterator = @ptrCast(@alignCast(source.ptr));

        // TODO: this can be format-independent if we count samples over byte by byte???
        // byte-per-byte should resolve channel playback as well as format size
        var buf: [*]f32 = @ptrCast(@alignCast(buffer_list.?.*.mBuffers[0].mData));

        const bytesInFrames = buffer_list.?.*.mBuffers[0].mDataByteSize;

        std.debug.print("mDataByteSize: {}, frames: {}\n", .{ bytesInFrames, num_frames });
        std.debug.print("current pitch:\t{}\n", .{iter.pitch});
        const sample_size = 4; // TODO: pull in from player audio source eventually
        const num_samples = num_frames * 2;

        var frame: u32 = 0;

        while (frame < num_samples) : (frame += 2) { // TODO: manually interleaf channels for stereo for now
            // TODO: Where should we determine source audio format? Here, on render?

            const nextSample: f32 = std.mem.bytesAsValue(f32, source.next().?[0..sample_size]).*;
            //std.debug.print("sample in bytes:\t{}\n", .{nextSample});

            buf[frame] = std.math.clamp(nextSample, -1.0, 1.0);
            buf[frame + 1] = std.math.clamp(nextSample, -1.0, 1.0);
            // buf[frame + 1] = fromIterR; //std.math.shr(f64, fromIter, 32) | fromIter;
        }

        return c.noErr;
    }

    pub fn refresh() void {} // TODO: not sure whats goin on in here just yet

    pub fn createPlayer(self: Self, source: *sources.AudioSource) !*Player {
        var player = try self.alloc.create(Player);

        player.* = Player{ .alloc = self.alloc, .audio_unit = self.audioUnit, .is_playing = false, .ctx = &self, .source = source };

        const input = try self.alloc.create(c.AURenderCallbackStruct);
        defer self.alloc.destroy(input);

        input.* = c.AURenderCallbackStruct{
            .inputProc = &renderCallback,
            .inputProcRefCon = player,
        };

        osStatusHandler(c.AudioUnitSetProperty(self.audioUnit.*, c.kAudioUnitProperty_SetRenderCallback, c.kAudioUnitScope_Input, 0, input, @sizeOf(@TypeOf(input.*)))) catch |err| {
            std.debug.panic("failed to set render callback: {}\n", .{err});
        };

        // initialize player
        osStatusHandler(c.AudioUnitInitialize(player.audio_unit.*)) catch |err| {
            std.debug.panic("failed to initialize: {}\n", .{err});
        };

        return player;
    }
};

fn freeDevice(device: main.Device) void {
    // clean up audioUnit
    // stop audioUnit
    _ = c.AudioOutputUnitStop(device.ptr.*);
    _ = c.AudioUnitUninitialize(device.ptr.*);

    // dispose of instance
    _ = c.AudioComponentInstanceDispose(device.ptr.*);
}

// Controls audio context and interfaces playback actions
pub const Player = struct {
    alloc: std.mem.Allocator,
    audio_unit: *c.AudioUnit,
    ctx: *const Context,
    volume: f32 = 0.5, // useless for now
    is_playing: bool,
    source: *sources.AudioSource,

    // NOTE: Don't use @This for simple structs!
    // https://zig.news/kristoff/dont-self-simple-structs-fj8

    fn init() void {}

    pub fn play(p: *Player) void {
        osStatusHandler(c.AudioOutputUnitStart(p.audio_unit.*)) catch |err| {
            std.debug.print("uh oh, playing didn't work: {}\n", .{err});
        };

        p.is_playing = false;
    }

    pub fn pause(p: *Player) void {
        osStatusHandler(c.AudioOutputUnitStop(p.audio_unit.*)) catch |err| {
            std.debug.print("uh oh, playing didn't work: {}\n", .{err});
        };

        p.is_playing = false;
    }

    pub fn setVolume(p: *Player, vol: f32) !void {
        osStatusHandler(c.AudioUnitSetParameter(
            p.audio_unit.*,
            c.kHALOutputParam_Volume,
            c.kAudioUnitScope_Global,
            0,
            vol,
            0,
        )) catch |err| {
            std.debug.print("error setting volume: {}\n", .{err});
        };
    }

    pub fn volume(p: *Player) !f32 {
        var vol: f32 = 0;
        osStatusHandler(c.AudioUnitGetParameter(
            p.audio_unit.*,
            c.kHALOutputParam_Volume,
            c.kAudioUnitScope_Global,
            0,
            &vol,
        )) catch |err| {
            std.debug.print("error retrieving volume: {}\n", .{err});
        };
        return vol;
    }

    // TODO: sounds smoother without pause/play, but there's popping
    pub fn setAudioSource(p: *Player, source: *sources.AudioSource) void {
        // p.pause();
        p.source = source;
        // p.play();
    }

    fn deinit() void {} // TODO:

};

// TODO: Manage signal composition
const Synth = struct {};

const Error = error{ GenericError, InitializationError, PlaybackError };

fn osStatusHandler(result: c.OSStatus) !void {
    if (result != c.noErr) {
        // TODO: Map to specific errors
        return Error.GenericError;
    }
}

var iterL = osc.SineIterator(0.5, 440.0, 44100){};
var iterR = osc.SineIterator(0.5, 444.0, 44100){};
var iterL2 = osc.SineIterator(0.5, 490.0, 44100){};

test "basic check for leaks" {
    const alloc = std.testing.allocator;

    const config = main.Context.Config{ .sample_format = f32, .sample_rate = default_sample_rate, .channel_count = 2, .frames_per_packet = 1 };
    const playerContext = try Context.init(alloc, config);

    defer playerContext.deinit();
}
