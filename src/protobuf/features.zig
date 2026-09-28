const remielle = @import("../remielle.zig");
const protobuf = remielle.protobuf;

pub const Feature = enum {
    log_out,
    player_kick,
};

const desc_set: protobuf.Descriptors = .main;

/// Inline function so that `isAvailable` is known at comptime.
pub inline fn isAvailable(comptime feature: Feature) bool {
    return switch (feature) {
        .log_out => desc_set.getDescriptorByName("PlayerLogoutCsReq") != null,
        .player_kick => if (desc_set.getDescriptorByName("PlayerKickScNotify")) |message|
            message.hasField("reason")
        else
            false,
    };
}
