const std = @import("std");

pub fn LimitedString(comptime limit: usize) type {
    return struct {
        const String = @This();

        pub const Error = error{TooLongString};

        pub const max_length = limit;
        pub const empty: String = .{};

        bytes: [max_length + 1]u8 = @splat(0),

        pub fn fromSlice(value: []const u8) Error!String {
            var string: String = .{};
            try string.set(value);

            return string;
        }

        pub fn constant(comptime value: []const u8) String {
            return comptime String.fromSlice(value) catch
                unreachable; // Constant string is too long.
        }

        pub fn view(string: *const String) [:0]const u8 {
            std.debug.assert(string.bytes[max_length] == 0);
            return std.mem.span(@as([*:0]const u8, @ptrCast(&string.bytes)));
        }

        pub fn set(string: *String, value: []const u8) Error!void {
            if (value.len > max_length) return error.TooLongString;

            @memcpy(string.bytes[0..value.len], value);
            string.bytes[value.len] = 0;
        }
    };
}
