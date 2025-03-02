const std = @import("std");

// Lifted from hexops/mach-engine implementation (MIT, afaik) while upgrading
// from 0.15->0.16
// https://code.hexops.org/hexops/mach/src/branch/main/src/sysaudio/coreaudio_c.zig

// Native Zig declarations for CoreAudio types, constants, and functions.
// Replaces @cImport of macOS SDK headers which fail under aro-based translate-c
// due to Obj-C block syntax (^) in AudioToolbox headers.

// Base types

pub const OSStatus = i32;
pub const AudioObjectID = u32;
pub const Boolean = u8;

pub const noErr: OSStatus = 0;

// Midi stuff can live here for now too
pub const kMIDIObjectNotFound: i32 = -10842;

// AudioObjectPropertyAddress (from CoreAudio/AudioHardwareBase.h)

pub const AudioObjectPropertySelector = u32;
pub const AudioObjectPropertyScope = u32;
pub const AudioObjectPropertyElement = u32;

pub const AudioObjectPropertyAddress = extern struct {
    mSelector: AudioObjectPropertySelector,
    mScope: AudioObjectPropertyScope,
    mElement: AudioObjectPropertyElement,
};

// AudioStreamBasicDescription (from CoreAudioTypes/CoreAudioBaseTypes.h)

pub const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

// AudioBuffer / AudioBufferList (from CoreAudioTypes/CoreAudioBaseTypes.h)

pub const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

pub const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

// AudioTimeStamp (from CoreAudioTypes/CoreAudioBaseTypes.h)

pub const AudioTimeStamp = extern struct {
    mSampleTime: f64,
    mHostTime: u64,
    mRateScalar: f64,
    mWordClockTime: u64,
    mSMPTETime: SMPTETime,
    mFlags: u32,
    mReserved: u32 = 0,
};

pub const SMPTETime = extern struct {
    mSubframes: i16,
    mSubframeDivisor: i16,
    mCounter: u32,
    mType: u32,
    mFlags: u32,
    mHours: i16,
    mMinutes: i16,
    mSeconds: i16,
    mFrames: i16,
};

// Format constants (from CoreAudioTypes)

pub const kAudioFormatLinearPCM: u32 = fourcc("lpcm");
pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
pub const kAudioFormatFlagIsBigEndian: u32 = 1 << 1;
pub const kAudioFormatFlagIsSignedInteger: u32 = 1 << 2;

// AudioObject constants (from CoreAudio/AudioHardwareBase.h)

pub const kAudioObjectPropertyScopeGlobal: u32 = fourcc("glob");
pub const kAudioObjectPropertyScopeInput: u32 = fourcc("inpt");
pub const kAudioObjectPropertyScopeOutput: u32 = fourcc("outp");
pub const kAudioObjectPropertyElementMain: u32 = fourcc("main");
pub const kAudioObjectPropertyElementMaster: u32 = 0;

// AudioHardware constants (from CoreAudio/AudioHardware.h)

pub const kAudioObjectSystemObject: AudioObjectID = 1;
pub const kAudioHardwarePropertyDevices: u32 = fourcc("dev#");
pub const kAudioHardwarePropertyDefaultInputDevice: u32 = fourcc("dIn ");
pub const kAudioHardwarePropertyDefaultOutputDevice: u32 = fourcc("dOut");

// AudioDevice constants

pub const kAudioDevicePropertyStreamConfiguration: u32 = fourcc("slay");
pub const kAudioDevicePropertyNominalSampleRate: u32 = fourcc("nsrt");
pub const kAudioDevicePropertyScopeInput: u32 = fourcc("inpt");
pub const kAudioDevicePropertyScopeOutput: u32 = fourcc("outp");
pub const kAudioDevicePropertyDeviceName: u32 = fourcc("name");
pub const kAudioDevicePropertyDeviceManufacturer: u32 = 1835101042;

// Deprecated type aliases

pub const AudioHardwarePropertyID = AudioObjectPropertySelector;
pub const AudioDeviceID = AudioObjectID;
pub const AudioDevicePropertyID = AudioObjectPropertySelector;

// AudioComponent types (from AudioToolbox/AudioComponent.h)

pub const AudioComponent = ?*opaque {};
pub const AudioComponentInstance = ?*opaque {};
pub const AudioUnit = AudioComponentInstance;

pub const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32,
    componentFlagsMask: u32,
};

// AudioUnit types and constants (from AudioToolbox/AUComponent.h)

pub const AudioUnitRenderActionFlags = u32;
pub const AudioUnitPropertyID = u32;
pub const AudioUnitScope = u32;
pub const AudioUnitElement = u32;
pub const AudioUnitParameterID = u32;
pub const AudioUnitParameterValue = f32;

pub const AURenderCallback = *const fn (
    inRefCon: ?*anyopaque,
    ioActionFlags: *AudioUnitRenderActionFlags,
    inTimeStamp: *const AudioTimeStamp,
    inBusNumber: u32,
    inNumberFrames: u32,
    ioData: *AudioBufferList,
) callconv(.c) OSStatus;

pub const AURenderCallbackStruct = extern struct {
    inputProc: AURenderCallback,
    inputProcRefCon: ?*anyopaque,
};

// AudioUnit type constants
pub const kAudioUnitType_Output: u32 = fourcc("auou");
pub const kAudioUnitSubType_HALOutput: u32 = fourcc("ahal");
pub const kAudioUnitSubType_DefaultOutput: u32 = fourcc("def ");
pub const kAudioUnitManufacturer_Apple: u32 = fourcc("appl");

// AudioUnit scope constants
pub const kAudioUnitScope_Global: u32 = 0;
pub const kAudioUnitScope_Input: u32 = 1;
pub const kAudioUnitScope_Output: u32 = 2;

// AudioUnit property constants
pub const kAudioUnitProperty_StreamFormat: u32 = 8;
pub const kAudioUnitProperty_SetRenderCallback: u32 = 23;
pub const kAudioOutputUnitProperty_EnableIO: u32 = 2003;
pub const kAudioOutputUnitProperty_CurrentDevice: u32 = 2000;
pub const kAudioOutputUnitProperty_SetInputCallback: u32 = 2005;

// HAL output parameter constants
pub const kHALOutputParam_Volume: u32 = 14;

// Functions from AudioToolbox

pub extern fn AudioComponentFindNext(
    inComponent: AudioComponent,
    inDesc: *const AudioComponentDescription,
) AudioComponent;

pub extern fn AudioComponentInstanceNew(
    inComponent: AudioComponent,
    outInstance: *AudioComponentInstance,
) OSStatus;

pub extern fn AudioComponentInstanceDispose(
    inInstance: AudioComponentInstance,
) OSStatus;

pub extern fn AudioUnitInitialize(inUnit: AudioUnit) OSStatus;
pub extern fn AudioUnitUninitialize(inUnit: AudioUnit) OSStatus;

pub extern fn AudioUnitSetProperty(
    inUnit: AudioUnit,
    inID: AudioUnitPropertyID,
    inScope: AudioUnitScope,
    inElement: AudioUnitElement,
    inData: *const anyopaque,
    inDataSize: u32,
) OSStatus;

pub extern fn AudioUnitGetParameter(
    inUnit: AudioUnit,
    inID: AudioUnitParameterID,
    inScope: AudioUnitScope,
    inElement: AudioUnitElement,
    outValue: *AudioUnitParameterValue,
) OSStatus;

pub extern fn AudioUnitSetParameter(
    inUnit: AudioUnit,
    inID: AudioUnitParameterID,
    inScope: AudioUnitScope,
    inElement: AudioUnitElement,
    inValue: AudioUnitParameterValue,
    inBufferOffsetInFrames: u32,
) OSStatus;

pub extern fn AudioUnitRender(
    inUnit: AudioUnit,
    ioActionFlags: *AudioUnitRenderActionFlags,
    inTimeStamp: *const AudioTimeStamp,
    inOutputBusNumber: u32,
    inNumberFrames: u32,
    ioData: *AudioBufferList,
) OSStatus;

pub extern fn AudioOutputUnitStart(ci: AudioUnit) OSStatus;
pub extern fn AudioOutputUnitStop(ci: AudioUnit) OSStatus;

// Functions from CoreAudio/AudioHardware.h

pub extern fn AudioObjectGetPropertyDataSize(
    inObjectID: AudioObjectID,
    inAddress: *const AudioObjectPropertyAddress,
    inQualifierDataSize: u32,
    inQualifierData: ?*const anyopaque,
    outDataSize: *u32,
) OSStatus;

pub extern fn AudioObjectGetPropertyData(
    inObjectID: AudioObjectID,
    inAddress: *const AudioObjectPropertyAddress,
    inQualifierDataSize: u32,
    inQualifierData: ?*const anyopaque,
    ioDataSize: *u32,
    outData: *anyopaque,
) OSStatus;

// Deprecated functions from CoreAudio/AudioHardwareDeprecated.h

pub extern fn AudioHardwareGetProperty(
    inPropertyID: AudioHardwarePropertyID,
    ioPropertyDataSize: *u32,
    outPropertyData: *anyopaque,
) OSStatus;

pub extern fn AudioDeviceGetPropertyInfo(
    inDevice: AudioDeviceID,
    inChannel: u32,
    isInput: Boolean,
    inPropertyID: AudioDevicePropertyID,
    outSize: ?*u32,
    outWritable: ?*Boolean,
) OSStatus;

pub extern fn AudioDeviceGetProperty(
    inDevice: AudioDeviceID,
    inChannel: u32,
    isInput: Boolean,
    inPropertyID: AudioDevicePropertyID,
    ioPropertyDataSize: *u32,
    outPropertyData: *anyopaque,
) OSStatus;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}
