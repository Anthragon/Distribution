const KeyValuePair = struct { key: @TypeOf(.enum_literal), value: u8 };
const default: u8 = 0b00000000;
const ignore_log: u8 = 0b00000001;
const ignore_err: u8 = 0b00000010;
const ignore_dbg: u8 = 0b00000100;
const ignore_warn: u8 = 0b00001000;
const ignore_all: u8 = 0b00001101;

pub const descriptive_errors = true;

pub const debug_ignore = [_]KeyValuePair{
    .{ .key = .@"page allocator", .value = ignore_all },

};
