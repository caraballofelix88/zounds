const std = @import("std");
const testing = std.testing;
const c = @import("compat.zig");

const main = @import("../main.zig");
const sources = @import("../sources/main.zig");
const osc = @import("../sources/osc.zig");
const utils = @import("../utils.zig");
const midi = @import("../midi.zig");
// shoutouts to my mans jamal for planting the seeds -- https://gist.github.com/jamal/8ee096ca98759f83b4942f22d365d449

const DeviceState = enum {
    uninitialized,
    stopped,
    started,
    stopping,
    starting,
};

const DeviceBackend = enum { core_audio };

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

        const player: *Player = @ptrCast(@alignCast(refPtr));
        var source: *sources.AudioSource = @ptrCast(@alignCast(player.source));
        // var source = player.source;

        // TODO: this can be format-independent if we count samples over byte by byte???
        // byte-per-byte should resolve channel playback as well as format size
        var buf: [*]f32 = @ptrCast(@alignCast(buffer_list.?.*.mBuffers[0].mData));

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
        const player = try self.alloc.create(Player);

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

        p.is_playing = true;
    }

    pub fn pause(p: *Player) void {
        osStatusHandler(c.AudioOutputUnitStop(p.audio_unit.*)) catch |err| {
            std.debug.print("uh oh, playing didn't work: {}\n", .{err});
        };

        p.is_playing = false;
    }

    // TODO: there should be some kind of unified volume scale across backends/sources
    pub fn setVolume(p: *Player, vol: f32) !void { // vol in Dbs
        const amplitude = utils.decibelsToAmplitude(vol);

        osStatusHandler(c.AudioUnitSetParameter(
            p.audio_unit.*,
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
        p.pause();
        p.source = source;
        p.play();
    }

    fn deinit() void {} // TODO:

};

const Error = error{ GenericError, InitializationError, PlaybackError, MIDIObjectNotFound };

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

    const config = main.Context.Config{ .sample_format = f32, .sample_rate = 44_100, .channel_count = 2, .frames_per_packet = 1 };
    const playerContext = try Context.init(alloc, config);

    defer playerContext.deinit();
}

fn midiNotifyProc(notif: [*c]const c.MIDINotification, refCon: ?*anyopaque) callconv(.C) void {
    _ = refCon;

    // TODO: use c.kMIDImsg* to track incoming notifications
    std.debug.print("MIDI notification received:\t{any}\n", .{notif.*});
}

// assumes single packet transmission for now. Will need refactoring to handle traversing packet list
fn midiPacketReader(packets: [*c]const c.MIDIPacketList, ref_a: ?*anyopaque, ref_b: ?*anyopaque) callconv(.C) void {
    _ = ref_a;
    _ = ref_b;

    // NOTE: MIDIPacket within packet list needs to be pulled by memory address, not by array reference
    const packet_bytes = std.mem.asBytes(packets);
    const packet = std.mem.bytesToValue(c.MIDIPacket, packet_bytes[4..]);

    const msg = try midi.Message.fromBytes(packet.data[0..packet.length], null);
    std.debug.print("MIDI Message:\t{}, channel:{}, {x}\n\n", .{ msg.status.kind(), msg.status.channel(), msg.data });
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
fn getStringProperty(buf: []u8, obj_ref: c.MIDIObjectRef, property_key: []const u8) []const u8 {
    var property_ref: c.CFStringRef = undefined;
    const key_ref = getStringRef(property_key);

    // TODO: propagate errors?
    osStatusHandler(c.MIDIObjectGetStringProperty(obj_ref, key_ref, &property_ref)) catch |err| {
        std.debug.print("Error getting MIDIObject property {s}:\t{}\n", .{ property_key, err });
        return buf; // TODO: we dont want to return this in the case of an error, make sure to throw
    };

    _ = c.CFStringGetCString(property_ref, @alignCast(buf.ptr), @intCast(buf.len), c.kCFStringEncodingUTF8);

    std.debug.print("String Property: {s}:\n|{s}|\n", .{ property_key, buf });
    return std.mem.trimRight(u8, buf, "\xaa");
}

const PropertyType = enum { str, int };

fn getIntegerProperty(val: *i32, obj_ref: c.MIDIObjectRef, property_key: []const u8) void {
    const key_ref = getStringRef(property_key);

    osStatusHandler(c.MIDIObjectGetIntegerProperty(obj_ref, key_ref, @alignCast(val))) catch |err| {
        std.debug.print("Error getting MIDIObject Property: {s}:\t{}\n", .{ property_key, err });
    };
}

fn getPropertiesString(buf: []u8, ref: c.MIDIObjectRef) void {
    var object_plist: c.CFPropertyListRef = undefined;

    const DEEP = 1;
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
        is_input: bool = false, // TODO: cmon lol

        pub fn init(
            alloc: std.mem.Allocator,
            name: []const u8,
            id: i32,
            is_input: bool,
            entity: ?Entity,
        ) !Endpoint {
            const _name = try alloc.dupe(u8, name);

            return .{
                .alloc = alloc,
                .name = _name,
                .id = id,
                .is_input = is_input,
                .entity = entity,
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

        pub fn init(alloc: std.mem.Allocator) !Client {
            const name = try alloc.dupe(u8, &"Test".*);
            const id = 12345;

            const available_devices = std.ArrayList(Device).init(alloc);
            var available_inputs = std.ArrayList(Endpoint).init(alloc);

            const num_sources = c.MIDIGetNumberOfSources();

            // ignore destinations for now
            const num_destinations = c.MIDIGetNumberOfDestinations();
            _ = num_destinations;

            // initialize Client
            const ref = createMidiClient();

            // initialize client input port
            var port_ref: c.MIDIPortRef = undefined;
            const port_name = getStringRef("MIDI Input Port for Zounds"); // TODO: name designated here isn't reflected in other applications, wonder what's up w that
            // InputPortCreate + MIDIReadProc should be deprecated in favor of MIDIInputPortCreateWithProtocol + midiReceiveBlock
            // zig C header translation doesn't yet support C block nodes, so it is what it is for now
            osStatusHandler(c.MIDIInputPortCreate(ref, port_name, &midiPacketReader, null, &port_ref)) catch |err| {
                std.debug.print("Error creating midi client:\t{}\n", .{err});
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
                //input.deinit();
            }
            client.available_inputs.deinit();

            client.alloc.free(client.name);
        }

        pub fn connectInput(client: *Client, index: u8) void {
            if (client.active_input == index) {
                return;
            }

            var source: c.MIDIEndpointRef = undefined;

            const source_id = client.available_inputs.items[index].id;
            _ = c.MIDIObjectFindByUniqueID(source_id, &source, null);

            _ = osStatusHandler(c.MIDIPortConnectSource(client.input_port, source, null)) catch |err| {
                std.debug.print("Error connecting port to source:\t{}\n", .{err});
            };

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
            }
        };

        var name_buf: [64]u8 = undefined;
        var source_id: i32 = undefined;

        const name = getStringProperty(&name_buf, source, "name"); // do sources have names?
        getIntegerProperty(&source_id, source, "uniqueID");

        var entity_id: i32 = undefined;
        var entity_name_buf: [64]u8 = undefined;
        var embedded: i32 = undefined;

        var entity: ?Endpoint.Entity = null;
        if (!is_virtual) {
            const entity_name = getStringProperty(&entity_name_buf, entity_ref, "name");
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

        var name = getStringProperty(&name_buf, device_ref, "name");
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
        // TODO: update MIDINotifyProc to track updates to midi devices
        osStatusHandler(c.MIDIClientCreate(receiver_name, &midiNotifyProc, null, &ref)) catch |err| {
            std.debug.print("Error creating midi client:\t{}\n", .{err});
        };
        return ref;
    }
};

test "Client init" {
    const alloc = testing.allocator_instance.allocator();

    var client = try Midi.Client.init(alloc);
    defer client.deinit();
}

test "getStringRef" {
    const test_str = "Testing";

    const out: c.CFStringRef = getStringRef(test_str);
    _ = out;
}

test "MidiClient" {}
