const std = @import("std");
const testing = std.testing;
const c = @import("compat.zig");

const main = @import("../main.zig");
const sources = @import("../sources/main.zig");
const osc = @import("../sources/osc.zig");
const utils = @import("../utils.zig");
const midi = @import("../midi.zig");
const backends = @import("backends.zig");
// shoutouts to my mans jamal for planting the seeds -- https://gist.github.com/jamal/8ee096ca98759f83b4942f22d365d449

const DeviceState = enum {
    uninitialized,
    stopped,
    started,
    stopping,
    starting,
};
// TODO:
// - get a working device list going
// - Move audiounit creation to player initialization
pub const Context = struct {
    alloc: std.mem.Allocator,
    audioUnit: c.AudioUnit,
    devices: std.ArrayList(main.Device),

    pub fn init(allocator: std.mem.Allocator, config: main.ContextConfig) !backends.Context {
        var acd = c.AudioComponentDescription{
            .componentType = c.kAudioUnitType_Output,
            .componentSubType = c.kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = c.kAudioUnitManufacturer_Apple,
            .componentFlags = std.mem.zeroes(u32),
            .componentFlagsMask = std.mem.zeroes(u32),
        };

        // get next available audio component
        var device: c.AudioComponent = undefined;
        device = c.AudioComponentFindNext(null, &acd) orelse {
            std.debug.panic("error finding device \n", .{});
        };

        // capture audio unit instance for device
        var audioUnit: c.AudioUnit = undefined;
        osStatusHandler(c.AudioComponentInstanceNew(device, &audioUnit)) catch |err| {
            std.debug.panic("audio component instance failed: {}\n", .{err});
        };

        const bytesPerFrame: u32 = @intCast(config.desired_format.frameSize());

        const asbd = c.AudioStreamBasicDescription{
            .mFormatID = c.kAudioFormatLinearPCM,
            .mFormatFlags = 0 | c.kAudioFormatFlagIsFloat, // forcing float sample format here for now
            .mSampleRate = @as(f64, @floatFromInt(config.desired_format.sample_rate)),
            .mBitsPerChannel = config.desired_format.sample_format.bitSize(),
            .mChannelsPerFrame = @as(u32, @intCast(config.desired_format.channels.len)),
            .mFramesPerPacket = config.frames_per_packet, // apparently should always be 1 for PCM output
            .mBytesPerFrame = bytesPerFrame,
            .mBytesPerPacket = bytesPerFrame * config.frames_per_packet,
            .mReserved = 0,
        };

        osStatusHandler(c.AudioUnitSetProperty(audioUnit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Input, 0, &asbd, @sizeOf(@TypeOf(asbd)))) catch |err| {
            std.debug.panic("failed to stream format: {}\n", .{err});
        };

        const ctx = try allocator.create(Context);

        ctx.* = .{
            .alloc = allocator,
            .audioUnit = audioUnit,
            .devices = undefined,
        };

        return .{ .coreaudio = ctx };
    }

    pub fn deinit(ctx: *Context) void {
        // TODO:
        _ = ctx;
    }

    pub fn devices(ctx: Context) []const main.Device {
        return ctx.devices.items;
    }

    pub fn renderCallback(refPtr: ?*anyopaque, au_render_flags: [*c]c.AudioUnitRenderActionFlags, timestamp: [*c]const c.AudioTimeStamp, bus_number: c_uint, num_frames: c_uint, buffer_list: [*c]c.AudioBufferList) callconv(.C) c.OSStatus {
        _ = au_render_flags;
        _ = timestamp;
        _ = bus_number;

        const player: *Player = @ptrCast(@alignCast(refPtr));

        // TODO: move render stuff into writeFn
        const writeFn: main.WriteFn = player.writeFn;
        _ = writeFn;

        var source: *sources.AudioSource = @ptrCast(@alignCast(player.write_ref));

        // TODO: this can be format-independent if we count samples over byte by byte???
        // byte-per-byte should resolve channel playback as well as format size
        var buf: [*]f32 = @ptrCast(@alignCast(buffer_list.?.*.mBuffers[0].mData));

        const sample_size = 4; // TODO: pull in from player context
        const num_samples = num_frames * 2;

        var frame: u32 = 0;

        while (frame < num_samples) : (frame += 2) { // TODO: manually interleave channels for stereo for now

            const nextSample: f32 = std.mem.bytesAsValue(f32, source.next().?[0..sample_size]).*;

            buf[frame] = std.math.clamp(nextSample, -1.0, 1.0);
            buf[frame + 1] = std.math.clamp(nextSample, -1.0, 1.0);
            // buf[frame + 1] = fromIterR; //std.math.shr(f64, fromIter, 32) | fromIter;
        }

        return c.noErr;
    }

    pub fn refresh() void {} // TODO: list available devices here

    pub fn createPlayer(ctx: *Context, device: main.Device, writeFn: main.WriteFn, options: main.StreamOptions) !backends.Player {
        const player = try ctx.alloc.create(Player);

        _ = device;

        player.* = Player{
            .alloc = ctx.alloc,
            .audio_unit = ctx.audioUnit,
            .is_playing = false,
            .ctx = ctx,
            .writeFn = writeFn,
            .write_ref = options.write_ref,
        };

        const input = try ctx.alloc.create(c.AURenderCallbackStruct);
        errdefer ctx.alloc.destroy(input);

        input.* = c.AURenderCallbackStruct{
            .inputProc = &renderCallback,
            .inputProcRefCon = player,
        };

        osStatusHandler(c.AudioUnitSetProperty(
            ctx.audioUnit,
            c.kAudioUnitProperty_SetRenderCallback,
            c.kAudioUnitScope_Input,
            0,
            input,
            @sizeOf(@TypeOf(input.*)),
        )) catch |err| {
            std.debug.panic("failed to set render callback: {}\n", .{err});
        };

        // initialize player
        osStatusHandler(c.AudioUnitInitialize(player.audio_unit)) catch |err| {
            std.debug.panic("failed to initialize: {}\n", .{err});
        };

        return .{ .coreaudio = player };
    }
};

// Interface for playback actions
pub const Player = struct {
    alloc: std.mem.Allocator,
    audio_unit: c.AudioUnit,
    ctx: *const Context,
    volume: f32 = 0.5,
    is_playing: bool,
    writeFn: main.WriteFn,
    write_ref: *anyopaque,

    fn init() void {}

    // TODO: appropriate error handling
    pub fn play(p: *Player) void {
        osStatusHandler(c.AudioOutputUnitStart(p.audio_unit)) catch |err| {
            std.debug.print("uh oh, playing didn't work: {}\n", .{err});
        };

        p.is_playing = true;
    }

    pub fn pause(p: *Player) void {
        osStatusHandler(c.AudioOutputUnitStop(p.audio_unit)) catch |err| {
            std.debug.print("uh oh, playing didn't work: {}\n", .{err});
        };

        p.is_playing = false;
    }

    pub fn setVolume(p: *Player, vol: f32) !void { // vol in dBs
        const amplitude = utils.decibelsToAmplitude(vol);

        osStatusHandler(c.AudioUnitSetParameter(
            p.audio_unit,
            c.kHALOutputParam_Volume,
            c.kAudioUnitScope_Global,
            0,
            amplitude,
            0,
        )) catch |err| {
            std.debug.print("error setting volume: {}\n", .{err});
        };
    }

    pub fn volume(p: *Player) !f32 {
        var vol: f32 = 0;
        osStatusHandler(c.AudioUnitGetParameter(
            p.audio_unit,
            c.kHALOutputParam_Volume,
            c.kAudioUnitScope_Global,
            0,
            &vol,
        )) catch |err| {
            std.debug.print("error retrieving volume: {}\n", .{err});
        };
        return vol;
    }

    pub fn deinit(p: *Player) void {
        // clean up audioUnit instance
        _ = c.AudioOutputUnitStop(p.audio_unit);
        _ = c.AudioUnitUninitialize(p.audio_unit);
        _ = c.AudioComponentInstanceDispose(p.audio_unit);

        p.alloc.destroy(p);
    }
};

const Error = error{ GenericError, InitializationError, PlaybackError, MIDIObjectNotFound, MIDIPropertyError };

fn osStatusHandler(result: c.OSStatus) !void {
    if (result != c.noErr) {
        // TODO: Map to specific errors
        // MidiServices -- /Library/Developer/CommandLineTools/SDKs/MacOSX14.2.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h:126

        const out = switch (result) {
            c.kMIDIObjectNotFound => Error.MIDIObjectNotFound,
            else => Error.GenericError,
        };

        std.debug.print("OSStatus error:\t{}\n\n", .{out});

        return out;
    }
}

test "basic check for leaks" {
    const alloc = std.testing.allocator;

    const config = main.ContextConfig{
        .frames_per_packet = 1,
        .desired_format = .{
            .sample_format = .f32,
            .sample_rate = 44_100,
            .channels = main.ChannelPosition.fromChannelCount(2),
            .is_interleaved = true,
        },
    };
    const playerContext = try Context.init(alloc, config);

    defer playerContext.coreaudio.deinit();
}

fn midiNotifyProc(notif: [*c]const c.MIDINotification, refCon: ?*anyopaque) callconv(.C) void {
    _ = refCon;

    // TODO: use c.kMIDImsg* to track incoming notifications
    // /Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h:683
    std.debug.print("MIDI notification received:\t{any}\n", .{notif.*});
}

// assumes single packet transmission for now. Will need refactoring to handle traversing packet list
// Follows MIDIReadProc signature: /Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h:366
fn midiPacketReader(packets: [*c]const c.MIDIPacketList, read_proc_ref: ?*anyopaque, source_connect_ref: ?*anyopaque) callconv(.C) void {
    _ = source_connect_ref;

    const cb_struct: *Midi.ClientCallbackStruct = @ptrCast(@alignCast(read_proc_ref));
    const cb: *fn (*const midi.Message, *anyopaque) void = @ptrCast(@constCast(@alignCast(cb_struct.cb)));

    // NOTE: MIDIPacket within packet list needs to be pulled by memory address, not by array reference
    const packet_bytes = std.mem.asBytes(packets);
    const packet = std.mem.bytesToValue(c.MIDIPacket, packet_bytes[4..]);

    const msg: midi.Message = midi.Message.fromBytes(packet.data[0..packet.length], null) catch |err| {
        std.debug.panic("message parse failure:\t{}\n", .{err});
    };
    std.debug.print("MIDI Message:\t{}, channel:{}, {x}\n\n", .{ msg.status.kind(), msg.status.channel(), msg.data });

    std.Thread.Mutex.lock(cb_struct.mut);
    defer std.Thread.Mutex.unlock(cb_struct.mut);

    // not entirely sure why msg needs to be passed as a ref for this to work. Otherwise, param comes through as garbage. Is there some weird ambiguity around passing structs by value?
    cb(&msg, cb_struct.ref.?);
}

fn getStringRef(buf: []const u8) c.CFStringRef {
    // TODO: probably a memory leak if we don't use the no-copy version of this func
    return c.CFStringCreateWithCString(
        c.kCFAllocatorDefault,
        @alignCast(buf.ptr),
        c.kCFStringEncodingUTF8,
        //c.kCFAllocatorDefault,
    );
}

fn getWriteStream(buf: []u8) c.CFWriteStreamRef {
    return c.CFWriteStreamCreateWithBuffer(c.kCFAllocatorDefault, @alignCast(buf.ptr), @intCast(buf.len));
}

// resulting slice owned by buffer.
fn getStringProperty(buf: []u8, obj_ref: c.MIDIObjectRef, property_key: []const u8) ![]const u8 {
    var property_ref: c.CFStringRef = undefined;
    const key_ref = getStringRef(property_key);

    osStatusHandler(c.MIDIObjectGetStringProperty(obj_ref, key_ref, &property_ref)) catch |err| {
        std.debug.print("Error getting MIDIObject property {s}:\t{}\n", .{ property_key, err });
        return Error.MIDIPropertyError;
    };

    _ = c.CFStringGetCString(property_ref, @alignCast(buf.ptr), @intCast(buf.len), c.kCFStringEncodingUTF8);

    return std.mem.trimRight(u8, buf, "\xaa");
}

fn getIntegerProperty(val: *i32, obj_ref: c.MIDIObjectRef, property_key: []const u8) void {
    const key_ref = getStringRef(property_key);

    osStatusHandler(c.MIDIObjectGetIntegerProperty(obj_ref, key_ref, @alignCast(val))) catch |err| {
        std.debug.print("Error getting MIDIObject Property: {s}:\t{}\n", .{ property_key, err });
    };
}

fn getPropertiesString(buf: []u8, ref: c.MIDIObjectRef) void {
    var object_plist: c.CFPropertyListRef = undefined;

    const DEEP = 1; // DEEP = 1 gets nested properties
    osStatusHandler(c.MIDIObjectGetProperties(ref, &object_plist, DEEP)) catch |err| {
        std.debug.print("Error pulling MIDI object properties:\t{}\n", .{err});
    };

    const stream: c.CFWriteStreamRef = getWriteStream(buf);

    _ = c.CFWriteStreamOpen(stream);

    const bytes_written = c.CFPropertyListWrite(object_plist, stream, c.kCFPropertyListXMLFormat_v1_0, 0, null);
    std.debug.assert(bytes_written != 0);

    _ = c.CFWriteStreamClose(stream);
}

pub const Midi = struct {
    pub const Device = struct {
        alloc: std.mem.Allocator,

        name: []u8,
        id: []u8,
        inputs: std.ArrayList(Endpoint) = undefined,
        outputs: std.ArrayList(Endpoint) = undefined,

        pub fn init(alloc: std.mem.Allocator, name: []const u8, id: []const u8) !Device {
            const _name = try alloc.dupe(u8, name);
            const _id = try alloc.dupe(u8, id);

            return .{ .alloc = alloc, .name = _name, .id = _id };
        }

        pub fn deinit(d: Device) void {
            d.alloc.free(d.name);
            d.alloc.free(d.id);
        }
    };

    // for OSX, represents MIDIEndpoints: Sources + num_destinations
    pub const Endpoint = struct {
        // Physical MIDI device
        const Entity = struct {
            name: []const u8,
            id: i32,
            is_embedded: bool,
        };

        alloc: std.mem.Allocator,
        name: []const u8,
        id: i32,
        entity: ?Entity = null,
        is_input: bool = false, // good enough!

        pub fn init(
            alloc: std.mem.Allocator,
            name: []const u8,
            id: i32,
            is_input: bool,
            entity: ?Entity,
        ) !Endpoint {
            // copy strings over
            const _name = try alloc.dupe(u8, name);

            var _entity: ?Entity = null;
            if (entity) |e| {
                const entity_name = try alloc.dupe(u8, e.name);
                _entity = .{ .name = entity_name, .id = e.id, .is_embedded = e.is_embedded };
            }

            return .{
                .alloc = alloc,
                .name = _name,
                .id = id,
                .is_input = is_input,
                .entity = _entity,
            };
        }

        pub fn is_virtual(e: Endpoint) bool {
            if (e.entity) {
                return true;
            }
            return false;
        }

        pub fn deinit(e: *Endpoint) void {
            e.alloc.free(e.name);

            if (e.entity) |entity| {
                e.alloc.free(entity.name);
            }
        }
    };

    // TODO: rename to clarify use as midi message capture callback
    pub const ClientCallbackStruct = struct { ref: ?*anyopaque, cb: *const fn (*const midi.Message, *anyopaque) callconv(.C) void, mut: *std.Thread.Mutex };

    // Limiting to single input source for now
    pub const Client = struct {
        alloc: std.mem.Allocator,

        name: []const u8,
        ref: c.MIDIClientRef = undefined,
        // TODO: output source
        input_port: c.MIDIPortRef = undefined,

        id: u32,
        // TODO: add notification proc
        available_devices: std.ArrayList(Device) = undefined,
        available_inputs: std.ArrayList(Endpoint) = undefined,
        available_outputs: std.ArrayList(Endpoint) = undefined,

        active_input: u8 = undefined,
        active_output: u8 = undefined,

        pub fn init(alloc: std.mem.Allocator, cb_struct: ?*const ClientCallbackStruct) !Client {
            const name = try alloc.dupe(u8, &"Test".*);
            const id = 12345;

            const available_devices = std.ArrayList(Device).init(alloc);
            var available_inputs = std.ArrayList(Endpoint).init(alloc);

            const num_sources = c.MIDIGetNumberOfSources();

            // TODO: ignore potential outputs for now
            const num_destinations = c.MIDIGetNumberOfDestinations();
            _ = num_destinations;

            // initialize Client
            const ref = createMidiClient();

            // initialize client input port
            var port_ref: c.MIDIPortRef = undefined;
            // TODO: name designated here isn't reflected in other applications, wonder what's up w that<D-s>
            const port_name = getStringRef("MIDI Input Port for Zounds");
            // InputPortCreate + MIDIReadProc should be deprecated in favor of MIDIInputPortCreateWithProtocol + midiReceiveBlock
            // zig C header translation doesn't yet support C block nodes, so it is what it is for now
            osStatusHandler(c.MIDIInputPortCreate(ref, port_name, &midiPacketReader, @ptrCast(@constCast(cb_struct orelse null)), &port_ref)) catch |err| {
                std.debug.print("Error creating midi client input port:\t{}\n", .{err});
            };

            for (0..num_sources) |n| {
                const endpoint = try createMidiSource(alloc, n);
                std.debug.print("Input Endpoint #{}:\n", .{n});
                std.debug.print("Source Name:\t{s}\n", .{endpoint.name});
                std.debug.print("Source ID:\t{}\n\n", .{endpoint.id});

                if (endpoint.entity) |e| {
                    std.debug.print("Source Entity Name:\t{s}\n", .{e.name});
                    std.debug.print("Source Entity ID:\t{}\n\n", .{e.id});
                }

                try available_inputs.append(endpoint);
            }

            return .{
                .alloc = alloc,
                .name = name,
                .available_devices = available_devices,
                .available_inputs = available_inputs,
                .id = id,
                .ref = ref,
                .input_port = port_ref,
            };
        }

        pub fn deinit(client: *Client) void {
            for (client.available_devices.items) |device| {
                device.deinit();
            }
            client.available_devices.deinit();

            for (client.available_inputs.items) |input| {
                _ = input;
                //TODO: handle deinit
                //input.deinit();
            }
            client.available_inputs.deinit();

            client.alloc.free(client.name);
        }

        // TODO: provide callback to connected port
        pub fn connectInputSource(client: *Client, index: u8) !void {
            // if (client.active_input == index) {
            //     std.debug.print("Already connected to input source {}.\n", .{index});
            //     return;
            // }

            var source: c.MIDIEndpointRef = undefined;

            const source_id = client.available_inputs.items[index].id;
            _ = c.MIDIObjectFindByUniqueID(source_id, &source, null);

            _ = osStatusHandler(c.MIDIPortConnectSource(client.input_port, source, null)) catch |err| {
                std.debug.print("Error connecting port to source:\t{}\n", .{err});
            };

            var name_buf: [64]u8 = undefined;
            const name = try getStringProperty(@constCast(&name_buf), source, "name");
            std.debug.print("Connected input {}:\t{}, {s}\n", .{ index, source_id, name });
            client.active_input = index;
        }
    };

    fn createMidiSource(alloc: std.mem.Allocator, idx: usize) !Endpoint {
        const source: c.MIDIEndpointRef = c.MIDIGetSource(idx);
        var entity_ref: c.MIDIEntityRef = undefined;

        var is_virtual: bool = false;
        osStatusHandler(c.MIDIEndpointGetEntity(source, &entity_ref)) catch |err| {
            if (err == Error.MIDIObjectNotFound) {
                // this is okay, but indicates source is virtual and not associated with a physical entity.
                is_virtual = true;
            } else {
                std.debug.print("Error creating midi source:\t{}\n", .{err});
                return err;
            }
        };

        var name_buf: [64]u8 = undefined;
        var source_id: i32 = undefined;

        const name = try getStringProperty(&name_buf, source, "name"); // do sources have names?
        getIntegerProperty(&source_id, source, "uniqueID");

        var entity_id: i32 = undefined;
        var entity_name_buf: [64]u8 = undefined;
        var embedded: i32 = undefined;

        var entity: ?Endpoint.Entity = null;
        if (!is_virtual) {
            const entity_name = try getStringProperty(&entity_name_buf, entity_ref, "name");
            getIntegerProperty(&entity_id, entity_ref, "uniqueID");
            getIntegerProperty(&embedded, entity_ref, "embedded");

            entity = .{
                .name = entity_name,
                .id = entity_id,
                .is_embedded = embedded == 1,
            };
        }

        return Endpoint.init(
            alloc,
            name,
            source_id,
            true,
            entity,
        );
    }

    fn createMidiDevice(alloc: std.mem.Allocator, idx: usize) !Device {
        var name_buf: [64]u8 = undefined;
        var id: i32 = undefined;
        const device_ref: c.MIDIDeviceRef = c.MIDIGetDevice(idx);

        std.debug.print("Create \n", .{});

        var name = try getStringProperty(&name_buf, device_ref, "name");
        getIntegerProperty(&id, device_ref, "uniqueID");

        var id_str: [32]u8 = undefined;
        _ = std.fmt.formatIntBuf(&id_str, id, 10, .lower, .{});
        std.debug.print("creating midi device {}:\n", .{idx});
        const device = try Device.init(alloc, &name, &id_str);

        return device;
    }

    // Create Midi Client on platforms
    fn createMidiClient() u32 {
        var ref: c.MIDIClientRef = undefined;
        const receiver_name = getStringRef("Zounds Midi Client");
        // TODO: update MIDINotifyProc to track updates to available midi devices
        osStatusHandler(c.MIDIClientCreate(receiver_name, &midiNotifyProc, null, &ref)) catch |err| {
            std.debug.print("Error creating midi client:\t{}\n", .{err});
        };
        return ref;
    }
};

test "Client init" {
    const alloc = testing.allocator_instance.allocator();

    var client = try Midi.Client.init(alloc, null);
    defer client.deinit();
}

test "getStringRef" {
    const test_str = "Testing";

    const out: c.CFStringRef = getStringRef(test_str);
    _ = out;
}

test "MidiClient" {}
