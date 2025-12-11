//! System-dependent implementations and core subroutines

const std = @import("std");
const builtin = @import("builtin");

pub const arch = builtin.cpu.arch;
const archimpl = switch (arch) {
    .x86_64 => @import("x86_64/root.zig"),
    else => unreachable,
};

comptime {
    _ = archimpl.entry.__boot_entry__;
}

pub const std_options = archimpl.std_options;
pub const assembly = archimpl.assembly;
pub const interrupts = archimpl.interrupts;
pub const time = archimpl.time;

pub const io = .{
    .ports = archimpl.ports,
    .serial = archimpl.serial,
};

pub const threading = .{
    .TaskContext = archimpl.TaskContext,
};

pub const mem = .{
    .pmm = archimpl.pmm,
    .paging = archimpl.paging,
    .MapPtr = archimpl.MapPtr,
};

pub const debug = .{
    .dumpStackTrace = archimpl.dumpStackTrace,
};

pub const pre_init = archimpl.general.pre_init;
pub const post_init = archimpl.general.post_init;
