const root = @import("root");
const std = @import("std");
const debug = root.debug;

const log = std.log.scoped(.@"x86_64 PMM");

const paging = @import("paging.zig");

const units = root.utils.units.data;

var memory_blocks_root: *Block = undefined;
var memory_blocks_buffer: []Block = undefined;

pub var hhdm_offset: usize = undefined;
var total_memory_bytes: usize = undefined;

pub var kernel_page_start: usize = undefined;
pub var kernel_page_end: usize = undefined;

pub var kernel_virt_start: usize = undefined;
pub var kernel_virt_end: usize = undefined;

pub const page_size = 4096;

pub const atributes_ROX_privileged_fixed = root.mem.paging.Attributes{
    .privileged = true,

    .read = true,
    .write = true,
    .execute = true,

    // This will prevent the kernel to go into the swap memory,
    // not desired as this pages are shared by all aplications
    .lock = true,
};

pub fn setup() void {
    var blocks: [30]Block = undefined;
    @memset(&blocks, @bitCast(@as(u320, 0)));

    memory_blocks_buffer = &blocks;
    memory_blocks_root = &blocks[0];
    memory_blocks_root.* = .{ .start = 0, .length = 0, .status = .reserved, .previous = null, .next = null };

    var next_free_block: usize = 1;

    const boot_info = root.get_boot_info();
    hhdm_offset = boot_info.hhdm_base_offset;
    const mmap = boot_info.memory_map;

    for (mmap) |i| {
        if (i.type == .usable) {
            // Entry is useable, do some checks and if valid,
            // mark it as free

            // Skip first 1MiB
            // Theorically, it is possible to use a
            // tiny range of memory bellow it in SOME
            // cases but i prefer to ignore it
            if (i.base < 0x100000) continue;

            log.debug("[mem {X:0>16}..{X:0>16}] free", .{ i.base, i.base + i.size });

            // Marking block as free
            blocks[next_free_block] = .{ .start = i.base / page_size, .length = i.size / page_size, .status = .free, .previous = null, .next = null };
        } else if (i.type == .framebuffer) {
            // I personally prefer have track of the framebuffer
            log.debug("[mem {X:0>16}..{X:0>16}] framebuffer", .{ i.base, i.base + i.size });

            // Marking block as free
            blocks[next_free_block] = .{ .start = i.base / page_size, .length = i.size / page_size, .status = .framebuffer, .previous = null, .next = null };
        } else if (i.type == .kernel_and_modules) {
            // Entry is not usable, but will be marked
            // as kernel

            log.debug("[mem {X:0>16}..{X:0>16}] kernel", .{ i.base, i.base + i.size });
            blocks[next_free_block] = .{ .start = i.base / page_size, .length = i.size / page_size, .status = .kernel, .previous = null, .next = null };

            kernel_page_start = i.base / page_size;
            kernel_page_end = kernel_page_start + i.size / page_size;
        } else {
            log.debug("[mem {X:0>16}..{X:0>16}] skipped ({s})", .{ i.base, i.base + i.size, @tagName(i.type) });
            continue;
        }

        // Link blocks
        if (next_free_block >= 1) {
            blocks[next_free_block].previous = &blocks[next_free_block - 1];
            blocks[next_free_block - 1].next = &blocks[next_free_block];
        }

        next_free_block += 1;
        total_memory_bytes += i.size;
    }

    const size = root.lib.utils.units.calc(total_memory_bytes, &root.lib.utils.units.data);

    log.info("Total memory available: {d:.2} {s} ({} pages)", .{ size.@"0", size.@"1", total_memory_bytes / page_size });
    log.debug("\nHHDM offset: {X}", .{hhdm_offset});

    paging.enumerate_paging_features();

    // Generating the definitive memory map
    _ = paging.create_new_map();

    const phys_mapping_range_bits = @min(paging.features.maxphyaddr, 39);

    // marking the kernel range
    const kernel_phys = boot_info.kernel_base_physical;
    const kernel_len = (kernel_page_end - kernel_page_start) * page_size;

    kernel_virt_start = std.mem.alignBackward(usize, boot_info.kernel_base_virtual, page_size);
    kernel_virt_end = std.mem.alignForward(usize, @intFromPtr(@extern(*u64, .{ .name = "__kernel_end__" })), page_size);

    log.debug("phys base: {X: >16}", .{kernel_phys});
    log.debug("phys end:  {X: >16}", .{kernel_phys + kernel_len});
    log.debug("virt base: {X: >16}", .{kernel_virt_start});
    log.debug("virt end:  {X: >16}", .{kernel_virt_end});

    // Creating identity map
    const idmap_len = std.math.shl(usize, 1, phys_mapping_range_bits);
    log.debug("\nMarking identity map {x}..{x}...", .{ hhdm_offset, hhdm_offset + idmap_len });
    paging.map_range(0, hhdm_offset, idmap_len, atributes_ROX_privileged_fixed) catch unreachable;

    // Mapping kernel
    log.debug("Marking kernel...", .{});
    log.debug("\nmapping kernel range {x} .. {x} ({} pages) to {x}..{x}", .{ kernel_phys, kernel_phys + kernel_len, kernel_len / page_size, kernel_virt_start, kernel_virt_end });
    paging.map_range(kernel_phys, kernel_virt_start, kernel_len, atributes_ROX_privileged_fixed) catch unreachable;

    log.debug("Commiting new map to CR3...", .{});
    paging.commit_map();

    log.info("\nOk theorically we are in our owm mem map now...", .{});
    log.info("Nothing exploded yay :3...", .{});

    // allocating pmm final heap
    const pmm_heap = get_multiple_pages(16, .kernel_heap);
    memory_blocks_buffer = @as([*]Block, @ptrCast(@alignCast(pmm_heap.?)))[0 .. 16 * page_size / @sizeOf(Block)];

    var cblk: ?*Block = memory_blocks_root;
    var idx: usize = 0;

    while (cblk) |cur_block| : ({
        idx += 1;
        cblk = cur_block.next;
    }) {
        memory_blocks_buffer[idx].status = cur_block.status;
        memory_blocks_buffer[idx].start = cur_block.start;
        memory_blocks_buffer[idx].length = cur_block.length;

        if (idx > 0) {
            memory_blocks_buffer[idx].previous = &memory_blocks_buffer[idx - 1];
            memory_blocks_buffer[idx - 1].next = &memory_blocks_buffer[idx];
        }
    }

    memory_blocks_buffer[0].previous = null;
    memory_blocks_buffer[idx - 1].next = null;
    @memset(memory_blocks_buffer[idx..], .{ .start = 0, .length = 0, .status = .unused, .previous = null, .next = null });

    memory_blocks_root = &memory_blocks_buffer[0];
    log.debug("Memory blocks final heap created", .{});
}

pub fn lsmemtable() callconv(.c) void {
    log.warn("lsmemblocks", .{});
    log.info("\nPhysical Memory Blocks:", .{});

    var free_pages: usize = 0;
    var used_pages: usize = 0;

    var cur: ?*Block = memory_blocks_root;
    var last: ?*Block = null;

    log.info("| Beguin     End        Length     Ptr              Length (bytes)   Status", .{});
    log.info("|---------------------------------------------------------------------------------", .{});

    while (cur != null) : ({
        last = cur;
        cur = cur.?.next;
    }) {
        if (cur.?.previous != last) break;

        log.info("| {: >10} {: >10} {: >10} {x: >16} {: >16} {s}", .{ cur.?.start, cur.?.start + cur.?.length, cur.?.length, cur.?.start * page_size, cur.?.length * page_size, @tagName(cur.?.status) });

        if (cur.?.status == .free) free_pages += cur.?.length else used_pages += cur.?.length;
    }

    log.info("|---------------------------------------------------------------------------------", .{});

    log.info("{} free pages", .{free_pages});
    log.info("{} used pages", .{used_pages});

    const free_float: f64 = @floatFromInt(free_pages);
    const used_float: f64 = @floatFromInt(used_pages);

    log.info("{d:.2}% memory used\n", .{used_float / free_float * 100});
}

/// Allocates and returns a single page
pub fn get_single_page(status: BlockStatus) *anyopaque {
    var block: *Block = undefined;

    // search for a free block
    var free_block = b: {
        var a: ?*Block = memory_blocks_root;
        while (a != null and a.?.status != .free) : (a = a.?.next) {}
        if (a == null) root.oom_panic();
        break :b a.?;
    };

    // cut the block if needed
    if (free_block.length == 1) {
        free_block.status = status;
        block = free_block;
    } else {
        var new_block = b: {
            for (memory_blocks_buffer) |*mb| {
                if (mb.status == .unused) break :b mb;
            }
            @panic("TODO increase buffer length (A)");
        };

        new_block.status = status;
        new_block.start = free_block.start;
        new_block.length = 1;

        free_block.start += 1;
        free_block.length -= 1;

        new_block.previous = free_block.previous;
        free_block.previous.?.next = new_block;

        new_block.next = free_block;
        free_block.previous = new_block;

        block = new_block;
    }

    const ptr_page = block.start;

    // try merge blocks
    if (block.previous) |prev| {
        if (prev.status == block.status and prev.start + prev.length == block.start) {
            prev.length += block.length;
            prev.next = block.next;
            if (block.next) |n| n.previous = prev;

            block.status = .unused;
            block = prev;
        }
    }
    if (block.next) |next| {
        if (next.status == block.status and next.start == block.start + block.length) {
            block.length += next.length;
            block.next = next.next;
            if (next.next) |n| n.previous = block;

            next.status = .unused;
        }
    }

    return @ptrFromInt(ptr_page * 4096 + hhdm_offset);
}
pub fn get_multiple_pages(len: usize, status: BlockStatus) ?*anyopaque {
    var block: *Block = undefined;

    // search for a free block
    var free_block = b: {
        var a: ?*Block = memory_blocks_root;
        while (a != null and (a.?.status != .free or a.?.length < len)) : (a = a.?.next) {}
        if (a == null) root.oom_panic();
        break :b a.?;
    };

    // cut the block if needed
    if (free_block.length == len) {
        free_block.status = status;
        block = free_block;
    } else {
        var new_block = b: {
            for (memory_blocks_buffer) |*mb| {
                if (mb.status == .unused) break :b mb;
            }
            @panic("TODO increase buffer length");
        };

        new_block.status = status;
        new_block.start = free_block.start;
        new_block.length = len;

        free_block.start += len;
        free_block.length -= len;

        new_block.previous = free_block.previous;
        free_block.previous.?.next = new_block;

        new_block.next = free_block;
        free_block.previous = new_block;

        block = new_block;
    }

    const ptr_page = block.start;

    // try merge blocks
    if (block.previous) |prev| {
        if (prev.status == block.status) {
            prev.length += block.length;
            prev.next = block.next;
            if (block.next) |n| n.previous = prev;

            block.status = .unused;
            block = prev;
        }
    }
    if (block.next) |next| {
        if (next.status == block.status) {
            block.length += next.length;
            block.next = next.next;
            if (next.next) |n| n.previous = block;

            next.status = .unused;
        }
    }

    return @ptrFromInt(ptr_page * 4096 + hhdm_offset);
}

pub inline fn virtFromPhys(phys: usize) usize {
    return phys +% hhdm_offset;
}
pub inline fn physFromVirt(virt: usize) usize {
    return virt -% hhdm_offset;
}
pub inline fn ptrFromPhys(comptime T: type, phys: usize) T {
    return @as(T, @ptrFromInt(virtFromPhys(phys)));
}
pub inline fn physFromPtr(ptr: anytype) usize {
    return physFromVirt(@intFromPtr(ptr));
}

const Block = extern struct {
    // start and length are in pages size
    start: usize,
    length: usize,

    status: BlockStatus,

    previous: ?*Block,
    next: ?*Block,
};

const BlockStatus = root.mem.paging.MemStatus;
