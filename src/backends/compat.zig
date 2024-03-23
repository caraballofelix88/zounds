const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreAudio/CoreAudio.h");
    @cInclude("AudioUnit/AudioUnit.h");
    @cInclude("CoreMidi/CoreMidi.h");
});

pub usingnamespace c;
