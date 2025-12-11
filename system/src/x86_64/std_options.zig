const std = @import("std");
const root = @import("root");
const ports = @import("io/ports.zig");
const serial = @import("io/serial.zig");

pub const page_size_min = 4096;
pub const page_size_max = 4096;
