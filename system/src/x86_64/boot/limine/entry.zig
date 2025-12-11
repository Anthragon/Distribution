const std = @import("std");
const builtin = @import("builtin");
const boot = @import("root").lib.boot;
const limine = @import("limine.zig");
const arch = builtin.cpu.arch;

// limine requests
pub export var base_revision: limine.BaseRevision = .{ .revision = 3 };
pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var memory_map_request: limine.MemoryMapRequest = .{};
pub export var kernel_addr_request: limine.KernelAddressRequest = .{};
pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var rsdp_request: limine.RsdpRequest = .{};
pub export var kfile_request: limine.KernelFileRequest = .{};

pub export fn __boot_entry__() callconv(.c) noreturn {

    // Tiny subroutine to make sure some main
    // CPU extra features are enabled
    switch (arch) {
        .x86_64 => {
            // Forcefully active common CPU features
            var cr0: usize = 0;
            var cr4: usize = 0;

            asm volatile ("mov %%cr0, %[out]"
                : [out] "=r" (cr0),
            );
            cr0 &= ~@as(usize, 1 << 2); // EM = 0
            cr0 |= @as(usize, 1 << 1); // MP = 1
            asm volatile ("mov %[in], %%cr0"
                :
                : [in] "r" (cr0),
            );

            asm volatile ("mov %%cr4, %[out]"
                : [out] "=r" (cr4),
            );
            cr4 |= @as(usize, 1 << 9); // OSFXSR
            cr4 |= @as(usize, 1 << 10); // OSXMMEXCPT
            asm volatile ("mov %[in], %%cr4"
                :
                : [in] "r" (cr4),
            );

            asm volatile ("fninit");
        },
        else => {},
    }

    if (!base_revision.is_supported()) done();
    if (framebuffer_request.response == null) done();
    if (framebuffer_request.response.?.framebuffer_count < 1) done();
    if (memory_map_request.response == null) done();
    if (kernel_addr_request.response == null) done();
    if (hhdm_request.response == null) done();
    if (rsdp_request.response == null) done();
    if (kfile_request.response == null) done();

    const fbuffer = framebuffer_request.response.?.framebuffers_ptr[0];
    const fbuffer_size = fbuffer.pitch * fbuffer.height;

    const mmap = memory_map_request.response.?;
    const addr = kernel_addr_request.response.?;
    const hhdm = hhdm_request.response.?;
    const rsdp = rsdp_request.response.?;
    var stbp: usize = undefined;

    asm volatile ("mov %%rbp, %[out]"
        : [out] "=r" (stbp),
        :
        : .{});

    const kfile = kfile_request.response.?.kernel_file;
    const boot_device: boot.BootDevice = b: {
        if (kfile.mbr_disk_id != 0) {
            break :b .{ .mbr = .{
                .disk_id = kfile.mbr_disk_id,
                .partition_index = kfile.partition_index,
            } };
        } else {
            break :b .{ .gpt = .{
                .disk_uuid = @bitCast(kfile.gpt_disk_uuid),
                .part_uuid = @bitCast(kfile.gpt_part_uuid),
            } };
        }
    };

    const boot_info: boot.BootInfo = .{
        .kernel_base_physical = addr.physical_base,
        .kernel_base_virtual = addr.virtual_base,
        .kernel_stack_pointer_base = stbp,
        .hhdm_base_offset = hhdm.offset,
        .rsdp_physical = @intFromPtr(rsdp.address),

        .framebuffer = .{ .framebuffer = fbuffer.address[0..fbuffer_size], .width = fbuffer.width, .height = fbuffer.height, .pps = fbuffer.pitch },

        .memory_map = @ptrCast(mmap.entries_ptr[0..mmap.entry_count]),

        .boot_device = boot_device,
    };

    @import("root").main(boot_info);
    unreachable;
}

fn done() noreturn {
    // Error here, the CPU is hard resetted
    // after tripple falt

    std.mem.doNotOptimizeAway({
        const a: u64 = 1;
        var b: u64 = 0;
        _ = a / b;
        b = undefined;
    });

    unreachable;
}
