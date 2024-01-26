const std = @import("std");
const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreAudio/CoreAudio.h");
    @cInclude("AudioUnit/AudioUnit.h");
});

const testing = std.testing;
const main = @import("../main.zig");
const osc = @import("../sources/osc.zig");

// shoutouts to my mans jamal for planting the seeds -- https://gist.github.com/jamal/8ee096ca98759f83b4942f22d365d449

// Set of a single sample across some number of audio channels
pub fn Frame(comptime T: type, comptime channel_count: u8) type {
    return [channel_count]T;
}

test "Frame" {
    try testing.expectEqual(Frame(main.SampleFormat, 3), [3]f32);
}

const DeviceState = enum {
    uninitialized,
    stopped,
    started,
    stopping,
    starting,
};

const DeviceBackend = enum { core_audio };

const default_sample_rate = 44_100; // 44.1khz

// Synonymous with coreaudio.AudioUnit???

// TODO: might not need to keep all these pointers, just rebuild the config components each time
pub const Context = struct {
    alloc: std.mem.Allocator,
    acd: *c.AudioComponentDescription,
    asbd: *c.AudioStreamBasicDescription,
    device: *c.AudioComponent,
    audioUnit: *c.AudioUnit,
    input: *c.AURenderCallbackStruct,
    // source: *anyopaque = &iter, // TODO: clean this up

    devices: []main.Device,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: main.Context.Config) !Self {
        // var ctx = try allocator.create(Context);
        // errdefer allocator.destroy(ctx);

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

        const input = try allocator.create(c.AURenderCallbackStruct);
        input.* = c.AURenderCallbackStruct{
            .inputProc = &renderCallback,
            .inputProcRefCon = std.mem.zeroes(?*anyopaque), // TODO: pass in a reference to the player here, instead
        };

        // TODO: where should setting render callback live? Probably move renderCallback to player object
        osStatusHandler(c.AudioUnitSetProperty(audioUnit.*, c.kAudioUnitProperty_SetRenderCallback, c.kAudioUnitScope_Input, 0, input, @sizeOf(@TypeOf(input.*)))) catch |err| {
            std.debug.panic("failed to set render callback: {}\n", .{err});
        };

        const asbd = try allocator.create(c.AudioStreamBasicDescription);

        // TODO: we can pull channel descriptions from the
        // Get StreamDescription from context config
        const bytesPerFrame = config.sample_format.size() * config.channel_count;
        asbd.* = c.AudioStreamBasicDescription{
            .mFormatID = c.kAudioFormatLinearPCM, //TODO: other audiostream formats?
            // TODO: update audio format flags based on config.sample_format
            .mFormatFlags = 0 | c.kAudioFormatFlagIsFloat,
            .mSampleRate = @as(f64, @floatFromInt(config.sample_rate)),
            .mBitsPerChannel = config.sample_format.bitSize(),
            .mChannelsPerFrame = config.channel_count,
            .mFramesPerPacket = config.frames_per_packet, // TODO: is this configurable for our purposes? Apparently always 1 for PCM output
            .mBytesPerFrame = bytesPerFrame,
            .mBytesPerPacket = bytesPerFrame * config.frames_per_packet,
            .mReserved = 0,
        };

        osStatusHandler(c.AudioUnitSetProperty(audioUnit.*, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Input, 0, asbd, @sizeOf(@TypeOf(asbd.*)))) catch |err| {
            std.debug.panic("failed to stream format: {}\n", .{err});
        };

        // initialize player
        osStatusHandler(c.AudioUnitInitialize(audioUnit.*)) catch |err| {
            std.debug.panic("failed to initialize: {}\n", .{err});
        };

        const ctx: Context = .{ .alloc = allocator, .acd = acd, .asbd = asbd, .audioUnit = audioUnit, .device = device, .input = input, .devices = &.{} };

        return ctx;
    }

    pub fn deinit(self: Self) void {
        // stop audioUnit
        _ = c.AudioOutputUnitStop(self.audioUnit.*);
        _ = c.AudioUnitUninitialize(self.audioUnit.*);

        // dispose of instance
        _ = c.AudioComponentInstanceDispose(self.audioUnit.*);

        //        for (self.devices) |device| {
        //            freeDevice(device);
        //            self.alloc.destroy(device);
        //        }
        //        self.alloc.destory(self.devices);

        self.alloc.destroy(self.audioUnit);
        self.alloc.destroy(self.acd);
        self.alloc.destroy(self.asbd);
        self.alloc.destroy(self.input);
        self.alloc.destroy(self.device);
    }

    // TODO: getTheta function for signal generators
    pub fn renderCallback(refPtr: ?*anyopaque, au_render_flags: [*c]c.AudioUnitRenderActionFlags, timestamp: [*c]const c.AudioTimeStamp, bus_number: c_uint, num_frames: c_uint, buffer_list: [*c]c.AudioBufferList) callconv(.C) c.OSStatus {
        _ = refPtr;
        _ = au_render_flags;
        _ = timestamp;
        _ = bus_number;

        // TODO: this can be format-independent if we count samples over byte by byte???
        // byte-per-byte should resolve channel playback as well as format size
        var buf: [*]f32 = @ptrCast(@alignCast(buffer_list.?.*.mBuffers[0].mData));

        // TODO: handle amplitude/volume in player, not signal generators

        const bytesInFrames = buffer_list.?.*.mBuffers[0].mDataByteSize;
        std.debug.print("mDataByteSize: {}, frames: {}\n", .{ bytesInFrames, num_frames });
        std.debug.print("mChannels: {},\tbuffers: {}\n", .{ buffer_list.?.*.mBuffers.len, buffer_list.?.*.mNumberBuffers });

        const frame_size = bytesInFrames / num_frames;
        const num_samples = num_frames * 2;
        _ = frame_size;

        var frame: u32 = 0;
        while (frame < num_samples) : (frame += 2) {
            // Where should we determine source audio format? Here, on render?
            // chunk 2 samples at once
            const fromIterL = iterL.next();
            const fromIterL2 = iterL2.next();
            const fromIterR = iterR.next();
            buf[frame] = (fromIterL + fromIterL2);
            buf[frame + 1] = fromIterR; //std.math.shr(f64, fromIter, 32) | fromIter;
        }

        return c.noErr;
    }

    pub fn refresh() void {} // TODO: not sure what this is for yet, copypasted lol

    pub fn createPlayer(self: Self) Player {
        return .{ .alloc = self.alloc, .audio_unit = self.audioUnit, .is_playing = false, .ctx = &self };
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

    // TODO: dont use @This() for concrete structs!
    // https://zig.news/kristoff/dont-self-simple-structs-fj8
    const Self = @This();

    fn init() void {}

    pub fn play(self: *Player) void {
        osStatusHandler(c.AudioOutputUnitStart(self.audio_unit.*)) catch |err| {
            std.debug.print("uh oh, playing didn't work: {}\n", .{err});
        };

        self.is_playing = false;
    }

    pub fn pause(self: *Player) void {
        osStatusHandler(c.AudioOutputUnitStop(self.audio_unit.*)) catch |err| {
            std.debug.print("uh oh, playing didn't work: {}\n", .{err});
        };

        self.is_playing = false;
    }

    pub fn setVolume(self: *Self, vol: f32) !void {
        osStatusHandler(c.AudioUnitSetParameter(
            self.audio_unit.*,
            c.kHALOutputParam_Volume,
            c.kAudioUnitScope_Global,
            0,
            vol,
            0,
        )) catch |err| {
            std.debug.print("error setting volume: {}\n", .{err});
        };
    }

    pub fn volume(self: *Self) !f32 {
        var vol: f32 = 0;
        osStatusHandler(c.AudioUnitGetParameter(
            self.audio_unit.*,
            c.kHALOutputParam_Volume,
            c.kAudioUnitScope_Global,
            0,
            &vol,
        )) catch |err| {
            std.debug.print("error retrieving volume: {}\n", .{err});
        };
        return vol;
    }

    fn deinit() void {}

    // NEXT UP: flesh out player, pause/stop, passing in audio source
};

// Manages signal composition
const Synth = struct {};

//
const FilePlayback = struct {};

// mostly copypasta below
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
