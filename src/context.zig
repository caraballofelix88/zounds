// TODO: likely needs a better name or to be put elsewhere
const fmt = @import("audio_format.zig");

pub const ContextConfig = struct {
    desired_format: fmt.FormatData,
    frames_per_packet: u8, // TODO: this is more of a stream option concern
};
