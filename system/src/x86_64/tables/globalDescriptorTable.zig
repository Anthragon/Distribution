const std = @import("std");
const root = @import("root");
const debug = root.debug;

const log = std.log.scoped(.x86_64_GDT);

pub var tables: [5 + 2]Entry = undefined;
pub const selector = .{
    .null = @as(u16, 0 << 3),
    .code64 = @as(u16, 1 << 3),
    .data64 = @as(u16, 2 << 3),
    .usercode64 = @as(u16, 3 << 3 | 3),
    .userdata64 = @as(u16, 4 << 2 | 3),
    .tss = @as(u16, 5 << 3),
};
var current_ptr: Pointer = undefined;

pub const Pointer = extern struct { limit: u16, base: u64 align(2) };
pub const Entry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: Access,
    limit_high: u4,
    flags: Flags,
    base_high: u8,
};

pub const Access = packed struct(u8) { acessed: bool, readable_writeable: bool, direction_conforming: bool, executable: bool, segment_type: enum(u1) { system = 0, data = 1 }, privilege: u2, present: bool };
pub const Flags = packed struct(u4) {
    available: bool,
    long_mode: bool,
    _ignored_0: u1 = 0,
    granularity: enum(u1) { byte = 0, page = 1 },
};

// TODO see why this shit is important and refactorate it
pub const Tss = packed struct {
    _rsvd_0: u32 = 0,

    // The Stack Pointers used to load the stack when a privilege level
    // change occurs from a lower privilege level to a higher one.
    interrupt_stack: u64 = 0,
    schedule_stack: u64 = 0,
    syscall_stack: u64 = 0,

    _rsvd_1: u64 = 0,

    // Interrupt Stack Table. The Stack Pointers used to load the stack
    // when an entry in the Interrupt Descriptor Table has an IST value
    // other than 0.
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,

    _rsvd_2: u64 = 0,
    _rsvd_3: u16 = 0,

    // I/O Map Base Address Field. Contains a 16-bit offset
    // from the base of the TSS to the I/O Permission Bit Map.
    iopb: u16 = 0,

    pub fn set_interrupt_stack(self: *@This(), stack: usize) void {
        self.interrput_stack = stack;
    }
    pub fn set_scheduler_stack(self: *@This(), stack: usize) void {
        self.scheduler_stack = stack;
    }
    pub fn set_syscall_stack(self: *@This(), stack: usize) void {
        self.syscall_stack = stack;
    }
};
var tss: Tss = undefined;

pub fn install() void {

    // Null entry
    set_gdt_entry(&tables[0], @bitCast(@as(u8, 0)), @bitCast(@as(u4, 0)));

    // Kernel code
    set_gdt_entry(
        &tables[1],
        .{
            .acessed = false,
            .readable_writeable = true,
            .direction_conforming = false,
            .executable = true,
            .segment_type = .data,
            .privilege = 0,
            .present = true,
        },
        .{ .available = false, .long_mode = true, .granularity = .page },
    );

    // Kernel data
    set_gdt_entry(
        &tables[2],
        .{
            .acessed = false,
            .readable_writeable = true,
            .direction_conforming = false,
            .executable = false,
            .segment_type = .data,
            .privilege = 0,
            .present = true,
        },
        .{ .available = false, .long_mode = true, .granularity = .page },
    );

    // User code
    set_gdt_entry(
        &tables[3],
        .{
            .acessed = false,
            .readable_writeable = true,
            .direction_conforming = false,
            .executable = true,
            .segment_type = .data,
            .privilege = 3,
            .present = true,
        },
        .{ .available = false, .long_mode = true, .granularity = .page },
    );

    // User data
    set_gdt_entry(
        &tables[4],
        .{
            .acessed = false,
            .readable_writeable = true,
            .direction_conforming = false,
            .executable = false,
            .segment_type = .data,
            .privilege = 3,
            .present = true,
        },
        .{ .available = false, .long_mode = true, .granularity = .page },
    );

    // Tast state segment
    set_tss_entry(tables[5..7], &tss);

    tss = .{};

    load_gdt(&tables);
    asm volatile ("ltr %[a]"
        :
        : [a] "r" (selector.tss),
    );
}
/// Returns the pointer to the last installed GDT
pub inline fn get_ptr() Pointer {
    return current_ptr;
}

fn load_gdt(gdt: []Entry) void {
    var gdtp = Pointer{ .limit = @intCast(@sizeOf(Entry) * gdt.len - 1), .base = @intFromPtr(gdt.ptr) };
    log.debug("GDT at {x}", .{@intFromPtr(gdt.ptr)});

    // load gdt
    asm volatile ("lgdt (%[gdt])"
        :
        : [gdt] "r" (&gdtp),
    );

    // use data selectors
    asm volatile (
        \\ mov %[dsel], %%ds
        \\ mov %[dsel], %%fs
        \\ mov %[dsel], %%gs
        \\ mov %[dsel], %%es
        \\ mov %[dsel], %%ss
        :
        : [dsel] "rm" (selector.data64),
    );

    // use code selectors
    asm volatile (
        \\ push %[csel]
        \\ lea 1f(%%rip), %%rax
        \\ push %%rax
        \\ lretq
        \\ 1:
        :
        : [csel] "i" (selector.code64),
        : .{ .rax = true }
    );

    current_ptr = gdtp;
}
fn set_gdt_entry(gdt: *Entry, access: Access, flags: Flags) void {
    const base: u32 = 0;
    const limit: u20 = 0xffff;

    gdt.base_low = @intCast(base & 0xFFFF);
    gdt.base_middle = @intCast((base >> 16) & 0xFF);
    gdt.base_high = @intCast((base >> 24) & 0xFF);

    gdt.limit_low = @intCast(limit & 0xFFFF);
    gdt.limit_high = @truncate(std.math.shr(u20, limit, 16) & 0xF);

    gdt.access = access;
    gdt.flags = flags;
}
fn set_tss_entry(gdt: *[2]Entry, tssref: *Tss) void {
    const base = @intFromPtr(tssref);
    const limit = @sizeOf(Tss) - 1;

    const gdt_0 = (limit & 0xffff) |
        ((base & 0xffffff) << 16) |
        (0x89 << 40) |
        ((limit >> 16) & 0xF) << 48 |
        ((base >> 24) & 0xFF) << 56;
    const gdt_1 = (base >> 32) & 0xFFFFFFFF;

    gdt[0] = @bitCast(gdt_0);
    gdt[1] = @bitCast(gdt_1);
}
