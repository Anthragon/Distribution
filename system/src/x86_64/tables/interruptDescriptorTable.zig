const std = @import("std");
const root = @import("root");
const sys = root.system;
const gdt = @import("globalDescriptorTable.zig");
const TaskContext = @import("../taskContext.zig").TaskContext;
const ports = @import("../io/ports.zig");

const debug = root.debug;
const log = std.log.scoped(.x86_64_IDT);
const handler_impl = @extern(
    ?*const fn (*TaskContext) callconv(.c) void,
    .{ .name = "interrupt_handler" },
) orelse @panic("Expected 'interrupt_handler' function implementation");

var entries: [256]Entry = undefined;

pub const Pointer = extern struct { limit: u16, base: u64 align(2) };
pub const Entry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3,
    _reserved_0: u5 = 0,
    gate_type: enum(u4) { interrupt = 0b1110, trap = 0b1111 },
    zero: u1,
    privilege: u2,
    present: bool,

    offset_mid: u16,
    offset_high: u32,
    zeroes: u32 = 0,
};

var current_ptr: Pointer = undefined;

pub fn install() void {
    inline for (0..256) |i| {
        set_entry(
            &entries,
            @intCast(i),
            make_handler(comptime @intCast(i)),
            gdt.selector.code64,
            0,
        );
    }

    load_idt(&entries);
}
pub fn set_privilege(int: u8, privilege: root.lib.Privilege) void {
    entries[@intCast(int)].privilege = switch (privilege) {
        .kernel => 0,
        .user => 3,
    };
}

/// Returns the pointer to the last installed IDT
pub inline fn get_ptr() Pointer {
    return current_ptr;
}

fn load_idt(idt: *[256]Entry) void {
    var idtp = Pointer{ .limit = @intCast(@sizeOf(Entry) * 256 - 1), .base = @intFromPtr(idt) };
    asm volatile ("lidt (%[idtp])"
        :
        : [idtp] "r" (&idtp),
    );

    log.debug("IDT is now {X}", .{idtp.base});
}
fn set_entry(self: *[256]Entry, num: u8, b: *const fn () callconv(.naked) void, selector: u16, privilege: u2) void {
    const ie = &self[num];

    const baseAsInt = @intFromPtr(b);
    ie.offset_low = @intCast(baseAsInt & 0xFFFF);

    ie.selector = selector;
    ie.zero = 0;
    ie.privilege = privilege;
    ie.ist = 0;
    ie.present = true;
    ie.gate_type = .interrupt;

    ie.offset_mid = @intCast((baseAsInt >> 16) & 0xFFFF);
    ie.offset_high = @intCast(baseAsInt >> 32);
}
fn make_handler(comptime intnum: u8) fn () callconv(.naked) void {
    return struct {
        fn func() callconv(.naked) void {
            const ec = if (comptime (!has_error_code(intnum))) "push $0\n" else "";
            asm volatile (ec ++
                    \\ push %[intnum]
                    \\ jmp interrupt_common
                :
                : [intnum] "i" (intnum),
            );
        }
    }.func;
}

fn has_error_code(intnum: u8) bool {
    return switch (intnum) {
        // Exceptions
        0x00...0x07 => false,
        0x08 => true,
        0x09 => false,
        0x0A...0x0E => true,
        0x0F...0x10 => false,
        0x11 => true,
        0x12...0x14 => false,
        //0x15 ... 0x1D => unreachable,
        0x1E => true,
        //0x1F          => unreachable,

        // Other interrupts
        else => false,
    };
}

export fn interrupt_common() callconv(.naked) void {
    asm volatile (
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rbp
        \\push %%rsi
        \\push %%rdi
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\
        \\sub $512, %%rsp
        \\fxsave64 (%%rsp)
        \\push %%rax
        \\
        \\mov %%ds, %%rax
        \\push %%rax
        \\mov %%es, %%rax
        \\push %%rax
        \\mov %%cr2, %%rax
        \\push %%rax
        \\
        \\mov %%rsp, %%rdi
        \\mov %[dsel], %%ax
        \\mov %%ax, %%es
        \\mov %%ax, %%ds
        \\ 
        \\call __internal_interrupt_handler__
        \\
        \\pop %%rax
        \\pop %%rax
        \\mov %%rax, %%es
        \\pop %%rax
        \\mov %%rax, %%ds
        \\
        \\pop %%rax
        \\fxrstor64 (%%rsp)
        \\add $512, %%rsp
        \\
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rbp
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\add $16, %%rsp // Pop error code and interrupt number
        \\iretq
        :
        : [dsel] "i" (gdt.selector.data64),
    );
}

export fn __internal_interrupt_handler__(fptr: u64) void {
    const int_frame: *TaskContext = @ptrFromInt(fptr);
    handler_impl(int_frame);
    ports.outb(0x20, 0x20);
}
