// TODO implement level-5 page mapping (99% unecessary)
const std = @import("std");
const root = @import("root");
const debug = root.debug;
const paging = root.mem.paging;
const pmm = @import("pmm.zig");
const assemlby = @import("../asm/asm.zig");

const log = std.log.scoped(.@"x86_64 paging");

const MemoryMap = paging.MemoryMap;
const Attributes = paging.Attributes;
const MMapError = paging.MMapError;

const ctrl_regs = assemlby.ctrl_regs;
const Cr3Value = ctrl_regs.ControlRegisterValueType(.cr3);

var current_map: ?MapPtr = undefined;

pub var features: PagingFeatures = undefined;
pub const PagingFeatures = struct {
    maxphyaddr: u8,
    linear_address_width: u8,
    five_level_paging: bool,
    gigabyte_pages: bool,
    global_page_support: bool,
};
pub fn enumerate_paging_features() void {
    const addresses = assemlby.cpuid.cpuid(.extended_address_info, {}).address_size_info;
    const feats_base = assemlby.cpuid.cpuid(.type_fam_model_stepping_features, {});
    const feats_ext = assemlby.cpuid.cpuid(.extended_fam_model_stepping_features, {});
    const flags = assemlby.cpuid.cpuid(.feature_flags, {});
    features = PagingFeatures{
        .maxphyaddr = addresses.physical_address_bits,
        .linear_address_width = addresses.virtual_address_bits,
        .five_level_paging = flags.flags2.la57,
        .gigabyte_pages = feats_ext.features2.pg1g,
        .global_page_support = feats_base.features.pge,
    };
}

// Returns the current selected memory map
pub fn get_current_map() MemoryMap {
    return current_map;
}
// Sets the current selected memory map
pub fn set_current_map(map: MapPtr) void {
    current_map = map;
}
// Loads the currently active memory map
pub fn load_commited_map() void {
    var cr3_val: Cr3Value = ctrl_regs.read(.cr3);
    const phys = cr3_val.get_phys_addr();
    current_map = pmm.ptrFromPhys(Table(PML45), phys);
    log.info("Loaded commited page table 0x{X} ({X})", .{ phys, @intFromPtr(current_map) });
}
// Active the currently loaded memory map
pub fn commit_map() void {
    var cr3_val: Cr3Value = ctrl_regs.read(.cr3);
    cr3_val.set_phys_addr(pmm.physFromPtr(current_map.?));
    ctrl_regs.write(.cr3, cr3_val);
    log.debug("Comitted page table at 0x{X} ({X})", .{ cr3_val.get_phys_addr(), @as(usize, @truncate(pmm.physFromPtr(current_map.?) >> 12)) });
}

// Creates a new empty memory map
pub fn create_new_map() MapPtr {
    const new_page_phys = pmm.get_single_page(.mem_page);
    var mmap: Table(PML45) = @ptrCast(@alignCast(new_page_phys));

    for (0..mmap.len) |i| mmap[i] = @bitCast(@as(usize, 0));

    log.debug("Map created at address {X}", .{@intFromPtr(mmap)});
    current_map = mmap;
    return mmap;
}

// Debug prints the selected memory map (lots of logs)
pub fn lsmemmap() void {
    log.warn("lsmemmap", .{});
    log.info("lsmemmap ({X}):", .{pmm.physFromPtr(current_map.?)});

    for (current_map.?, 0..) |*cmap, i| if (cmap.present) {
        log.info("PML4E {: >3} - {s11}{x:0>12} - {}", .{ i, if (i < 256) "0000" else "ffff", i << 39, cmap });

        const page_dir_ptr: Table(PDPTE) = pmm.ptrFromPhys(Table(PDPTE), cmap.get_phys_addr());
        for (page_dir_ptr, 0..) |*pdp, j| if (pdp.present) {
            log.info("\tPDPTE {: >3} - {s11}{x:0>12} - {}", .{ j, if (i < 256) "0000" else "ffff", (i << 39) | (j << 30), pdp });
            if (pdp.is_gb_page) continue;

            const page_dir: Table(PDE) = pmm.ptrFromPhys(Table(PDE), pdp.get_phys_addr());
            for (page_dir, 0..) |*pd, k| if (pd.present) {
                log.info("\t\tPDPE  {: >3} - {s11}{x:0>12} - {}", .{ k, if (i < 256) "0000" else "ffff", (i << 39) | (j << 30) | (k << 21), pd });
                if (pd.is_mb_page) continue;

                const page_table: Table(PTE) = pmm.ptrFromPhys(Table(PTE), pd.get_phys_addr());
                for (page_table, 0..) |*pt, l| if (pt.present) {
                    log.info("\t\t\tPTE   {: >3} - {s11}{x:0>12} - {}", .{ l, if (i < 256) "0000" else "ffff", (i << 39) | (j << 30) | (k << 21) | (l << 12), pt });
                };
            };
        };
    };
}

pub fn map_single_page(phys_base: usize, virt_base: usize, comptime size: usize, attributes: Attributes) MMapError!void {
    if (size != 10 and size != 20 and size != 30) @compileError(std.fmt.comptimePrint("Invalid size {} for x86_64 paging!", .{size}));

    const split: SplitPagingAddr = @bitCast(virt_base);

    const pml4: Table(PML45) = b: {
        if (split.pml4 != 0 and split.pml4 != -1) std.debug.panic("Cannot map address {f} without 5-level paging!", .{split});
        break :b current_map orelse @panic("No current map!");
    };

    const page_dir: Table(PDPTE) = b: {
        const entry: *PML45 = &pml4[split.dirptr];
        if (entry.present) break :b pmm.ptrFromPhys(Table(PDPTE), entry.get_phys_addr());

        // no entry currently present, allocating a new one
        entry.* = @bitCast(@as(usize, 0));
        entry.access = .read_write;
        entry.privilege = if (split.pml4 < 0) .user else .kernel;
        entry.cache_mode = .write_back;
        entry.no_code = false;
        entry.present = true;

        break :b try create_page_table(PDPTE, entry);
    };

    if (features.gigabyte_pages and size == 30) { // 1GB pages requested and supported

        var entry: *PDPTE = &page_dir[split.directory];
        if (entry.present) return MMapError.AddressAlreadyMapped;

        entry.* = @bitCast(@as(usize, 0));
        entry.access = if (attributes.write) .read_write else .read_only;
        entry.privilege = if (attributes.privileged or split.pml4 >= 0) .kernel else .user;
        entry.cache_mode = .write_back;
        entry.no_code = !attributes.execute;

        entry.set_phys_addr(phys_base);
        entry.is_gb_page = true;
        entry.present = true;

        return;
    } else if (size == 30) {
        for (0..512) |table| {
            const new_v_addr = virt_base + (table << 21);
            const new_p_addr = phys_base + (table << 21);
            try map_single_page(new_p_addr, new_v_addr, 20, attributes);
        }
        return;
    }

    const directory: Table(PDE) = b: {
        var entry: *PDPTE = &page_dir[split.directory];
        if (entry.present) break :b pmm.ptrFromPhys(Table(PDE), entry.get_phys_addr());

        entry.* = @bitCast(@as(usize, 0));
        entry.access = .read_write;
        entry.no_code = false;
        entry.privilege = if (split.pml4 < 0) .user else .kernel;
        entry.cache_mode = .write_though;
        entry.is_gb_page = false;
        entry.present = true;

        break :b try create_page_table(PDE, entry);
    };

    if (size == 20) {
        var entry: *PDE = &directory[split.table];
        if (entry.present) return MMapError.AddressAlreadyMapped;

        entry.* = @bitCast(@as(usize, 0));
        entry.access = if (attributes.write) .read_write else .read_only;
        entry.no_code = !attributes.execute;
        entry.privilege = if (attributes.privileged or split.pml4 >= 0) .kernel else .user;
        entry.is_mb_page = true;
        entry.set_phys_addr(phys_base);
        entry.present = true;

        return;
    }

    const table: Table(PTE) = b4: {
        var entry: *PDE = &directory[split.table];
        if (entry.present) break :b4 pmm.ptrFromPhys(Table(PTE), entry.get_phys_addr());

        entry.* = @bitCast(@as(usize, 0));
        entry.access = .read_write;
        entry.no_code = false;
        entry.privilege = if (split.pml4 < 0) .user else .kernel;
        entry.is_mb_page = false;
        entry.present = true;

        break :b4 try create_page_table(PTE, entry);
    };

    {
        var entry: *PTE = &table[split.page];
        if (entry.present) return MMapError.AddressAlreadyMapped;

        entry.* = @bitCast(@as(usize, 0));
        entry.access = if (attributes.write) .read_write else .read_only;
        entry.no_code = !attributes.execute;
        entry.privilege = if (attributes.privileged or split.pml4 >= 0) .kernel else .user;
        entry.set_phys_addr(phys_base);
        entry.present = true;
    }
}
pub fn map_range(phys_base: usize, virt_base: usize, length: usize, attributes: Attributes) MMapError!void {

    // log.debug("mapping range ${X}..${X} -> ${X}..${X} ({s}{s}{s}{s}{s}{s})",
    // .{
    //     phys_base, phys_base + length,
    //     virt_base, virt_base + length,

    //     if (attributes.read) "R" else "-",
    //     if (attributes.write) "W" else "-",
    //     if (attributes.execute) "X" else "-",
    //     if (attributes.privileged) "P" else "-",
    //     if (attributes.disable_cache) "-" else "C",
    //     if (attributes.lock) "L" else "-"
    // });

    var pa = phys_base;
    var la = virt_base;
    var sz = length;

    if (!std.mem.isAlignedLog2(pa, 12) or !std.mem.isAlignedLog2(@bitCast(la), 12) or !std.mem.isAlignedLog2(sz, 12))
        return MMapError.Missaligned;

    while (sz > 0) {
        if (std.mem.isAlignedLog2(pa, 30) and std.mem.isAlignedLog2(@bitCast(la), 30) and std.mem.isAlignedLog2(sz, 30) and sz >= 1 << 30) {
            try map_single_page(pa, la, 30, attributes);
            sz -= 1 << 30;
            pa += 1 << 30;
            la += 1 << 30;
        } else if (std.mem.isAlignedLog2(pa, 21) and std.mem.isAlignedLog2(@bitCast(la), 21) and std.mem.isAlignedLog2(sz, 21) and sz >= 1 << 21) {
            try map_single_page(pa, la, 20, attributes);
            sz -= 1 << 21;
            pa += 1 << 21;
            la += 1 << 21;
        } else if (sz >= 1 << 12) {
            try map_single_page(pa, la, 10, attributes);
            sz -= 1 << 12;
            pa += 1 << 12;
            la += 1 << 12;
        }
    }
}

pub fn unmap_single_page(virt_base: usize) MMapError!void {
    _ = virt_base;
}
pub fn unmap_range(virt_base: usize, length: usize) MMapError!void {
    _ = virt_base;
    _ = length;
}

fn create_page_table(comptime T: type, entry: anytype) !Table(T) {
    const tbl = pmm.get_single_page(.mem_page);
    entry.set_phys_addr(pmm.physFromPtr(tbl));
    const ptr: Table(T) = @ptrCast(@alignCast(tbl));
    @memset(std.mem.asBytes(ptr), 0);
    return ptr;
}

pub fn phys_from_ptr(ptr: anytype) ?usize {
    return phys_from_virt(@intFromPtr(ptr));
}
pub fn phys_from_virt(vaddr: usize) ?usize {
    const split: SplitPagingAddr = @bitCast(vaddr);

    var pml4: Table(PML45) = current_map orelse return null;
    var pml4e: *PML45 = &pml4[split.dirptr];
    if (!pml4e.present) return null;
    var pdpt: Table(PDPTE) = pmm.ptrFromPhys(Table(PDPTE), pml4e.get_phys_addr());

    var pdpte: *PDPTE = &pdpt[split.directory];
    if (!pdpte.present) return null;
    if (pdpte.is_gb_page) {
        const phys_base = pdpte.get_phys_addr();
        const offset = vaddr & ((1 << 30) - 1);
        return phys_base + offset;
    }

    var pd: Table(PDE) = pmm.ptrFromPhys(Table(PDE), pdpte.get_phys_addr());
    var pde: *PDE = &pd[split.table];
    if (!pde.present) return null;
    if (pde.is_mb_page) {
        const phys_base = pde.get_phys_addr();
        const offset = vaddr & ((1 << 21) - 1);
        return phys_base + offset;
    }

    var pt: Table(PTE) = pmm.ptrFromPhys(Table(PTE), pde.get_phys_addr());
    var pte: *PTE = &pt[split.page];
    if (!pte.present) return null;

    const phys_base = pte.get_phys_addr();
    const offset = vaddr & ((1 << 12) - 1);
    return phys_base + offset;
}

// Structures and structures related data _________________________________________-
const AccessMode = enum(u1) {
    read_only = 0,
    read_write = 1,
};
const Privilege = enum(u1) { kernel = 0, user = 1 };
const CacheMode = enum(u2) {
    /// Reading in cache. Writing go to
    /// both cache and RAM at the same time
    write_though = 0b00,
    /// Reading in cache. Writing goes
    /// first to cache, after to RAM
    write_back = 0b10,
    /// Reading and writing in RAM/IO
    uncacheable = 0b01,
};

pub const SplitPagingAddr = packed struct(isize) {
    byte: u12,
    page: u9,
    table: u9,
    directory: u9,
    dirptr: u9,
    pml4: i9,
    _: u7,

    pub fn format(self: *const @This(), fmt: anytype) !void {
        try fmt.print("0x{X:0>16} {b:0>9}:{b:0>9}:{b:0>9}:{b:0>9}:{b:0>9}:{b:0>12}", .{
            @as(usize, @bitCast(self.*)),
            @as(u9, @bitCast(self.pml4)),
            self.dirptr,
            self.directory,
            self.table,
            self.page,
            self.byte,
        });
    }
};

// _available_x are free bits that can be used
// by the kernel.
// _reserved_x must aways be 0!

/// Page map level 4/5 entry
const PML45 = packed struct(u64) {
    present: bool,
    access: AccessMode,
    privilege: Privilege,
    cache_mode: CacheMode,
    accessed: bool,

    _available_0: u1,
    _reserved_0: u1 = 0,
    _available_1: u4,
    physaddr: u40,
    _reserved_1: u7,
    _reserved_2: u4,
    no_code: bool,

    const physaddr_mask = makeTruncMask(@This(), "physaddr");
    pub inline fn get_phys_addr(self: @This()) usize {
        return @as(u64, @bitCast(self)) & physaddr_mask;
    }
    pub inline fn set_phys_addr(self: *@This(), addr: usize) void {
        self.physaddr = @truncate(addr >> 12);
    }

    pub fn format(s: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
        w.print("{s: <8} ", .{if (s.present) "present" else "disabled"}) catch unreachable;
        w.print("R{s}{s}{s} ", .{
            if (s.access == .read_write) "W" else "-",
            if (s.no_code) "-" else "X",
            if (s.privilege == .kernel) "P" else "-",
        }) catch unreachable;

        w.print("${X:0>16}", .{s.get_phys_addr()}) catch unreachable;

        w.print("cache = {s} ", .{switch (s.cache_mode) {
            .uncacheable => "un",
            .write_though => "wt",
            .write_back => "wb",
        }}) catch unreachable;
        w.print("acessed = {: <5} ", .{s.accessed}) catch unreachable;
    }
};

/// Page directory pointer table entry
const PDPTE = packed struct(u64) {
    present: bool,
    access: AccessMode,
    privilege: Privilege,
    cache_mode: CacheMode,
    accessed: bool,

    dirty: bool,
    is_gb_page: bool,
    global: bool,
    _reserved_0: u3 = 0,

    physaddr: packed union {

        // If being used as 1GB page
        gb_page: packed struct(u51) {
            pat: bool,
            _reserved_0: u17 = 0,
            physaddr: u22, // must be left shifted 30 to get true addr
            _reserved_1: u7 = 0,
            protection_key: u4, // ignored if pointing to page directory
        },

        // If being used as a normal PDTE
        pd_ptr: packed struct(u51) {
            addr: u40, // must be left shifted 12 to get true addr
            _reserved_0: u7 = 0,
            _reserved_1: u4 = 0,
        },
    },

    no_code: bool,

    pub fn get_phys_addr(self: @This()) usize {
        if (self.is_gb_page) {
            return @as(u52, @intCast(self.physaddr.gb_page.physaddr)) << 30;
        } else {
            return @as(u52, @intCast(self.physaddr.pd_ptr.addr)) << 12;
        }
    }
    pub fn set_phys_addr(self: *@This(), addr: usize) void {
        if (self.is_gb_page) {
            self.physaddr.gb_page.physaddr = @truncate(addr >> 30);
        } else {
            self.physaddr.pd_ptr.addr = @truncate(addr >> 12);
        }
    }

    pub fn format(s: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
        w.print("{s: <8} ", .{if (s.present) "present" else "disabled"}) catch unreachable;
        w.print("R{s}{s}{s} ", .{
            if (s.access == .read_write) "W" else "-",
            if (s.no_code) "-" else "X",
            if (s.privilege == .kernel) "P" else "-",
        }) catch unreachable;

        w.print("${X:0>16} ", .{s.get_phys_addr()}) catch unreachable;

        w.print("cache = {s} ", .{switch (s.cache_mode) {
            .uncacheable => "un",
            .write_though => "wt",
            .write_back => "wb",
        }}) catch unreachable;
        w.print("acessed = {: <5} ", .{s.accessed}) catch unreachable;
        w.print("global = {: <5} ", .{s.global}) catch unreachable;
        w.print("ispage = {: <5} ", .{s.is_gb_page}) catch unreachable;

        if (s.is_gb_page) {
            w.print("pkey = {x:0<4} ", .{s.physaddr.gb_page.protection_key}) catch unreachable;
            w.print("atTbl = {: <5}", .{s.physaddr.gb_page.pat}) catch unreachable;
        }
    }
};

// Page directory entry
const PDE = packed struct(u64) {
    present: bool,
    access: AccessMode,
    privilege: Privilege,
    cache_mode: CacheMode,
    accessed: bool,
    dirty: bool,

    is_mb_page: bool,
    global: bool,
    _ignored1: u3 = 0,

    physaddr: packed union {

        // If being used as 1MB page
        mb_page: packed struct(u51) {
            pat: bool,
            _reserved_0: u8 = 0,
            physaddr: u31, // must be left shifted 21 to get true addr
            _reserved_1: u7 = 0,
            protection_key: u4,
        },

        // If being used as a normal PDE
        pd_ptr: packed struct(u51) {
            addr: u40, // must be left shifted 12 to get true addr
            _reserved_0: u7 = 0,
            _reserved_1: u4 = 0,
        },
    },

    no_code: bool,

    pub fn get_phys_addr(self: @This()) usize {
        if (self.is_mb_page) {
            // 1mb page
            return @as(u52, @intCast(self.physaddr.mb_page.physaddr)) << 21;
        } else {
            return @as(u52, @intCast(self.physaddr.pd_ptr.addr)) << 12;
        }
    }

    pub fn set_phys_addr(self: *@This(), addr: usize) void {
        if (self.is_mb_page) {
            // 1mb page
            self.physaddr.mb_page.physaddr = @truncate(addr >> 21);
        } else {
            self.physaddr.pd_ptr.addr = @truncate(addr >> 12);
        }
    }

    pub fn format(s: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
        w.print("{s: <8} ", .{if (s.present) "present" else "disabled"}) catch unreachable;
        w.print("R{s}{s}{s} ", .{
            if (s.access == .read_write) "W" else "-",
            if (s.no_code) "-" else "X",
            if (s.privilege == .kernel) "P" else "-",
        }) catch unreachable;

        w.print("${X:0>16} ", .{s.get_phys_addr()}) catch unreachable;

        w.print("cache = {s} ", .{switch (s.cache_mode) {
            .uncacheable => "un",
            .write_though => "wt",
            .write_back => "wb",
        }}) catch unreachable;
        w.print("acessed = {: <5} ", .{s.accessed}) catch unreachable;
        w.print("global = {: <5} ", .{s.global}) catch unreachable;
        w.print("ispage = {: <5} ", .{s.is_mb_page}) catch unreachable;

        if (s.is_mb_page) {
            w.print("global = {: <5} ", .{s.global}) catch unreachable;
            w.print("pkey = {x:0<4} ", .{s.physaddr.mb_page.protection_key}) catch unreachable;
            w.print("atTbl = {: <5}", .{s.physaddr.mb_page.pat}) catch unreachable;
        }
    }
};

// Page table entry
const PTE = packed struct(u64) {
    present: bool,
    access: AccessMode,
    privilege: Privilege,
    cache_mode: CacheMode,
    accessed: bool,
    dirty: bool,
    attribute_table: bool,
    global: bool,
    _reserved_0: u3 = 0,
    physaddr: u40, // must be left shifted 12 to get true addr
    _available_0: u7 = 0,
    protection_key: u4,
    no_code: bool,

    const physaddr_mask = makeTruncMask(@This(), "physaddr");
    pub fn get_phys_addr(self: @This()) usize {
        return @as(u64, @bitCast(self)) & physaddr_mask;
    }
    pub fn set_phys_addr(self: *@This(), addr: usize) void {
        self.physaddr = @truncate(addr >> 12);
    }

    pub fn format(s: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
        w.print("{s: <8} ", .{if (s.present) "present" else "disabled"}) catch unreachable;
        w.print("R{s}{s}{s} ", .{
            if (s.access == .read_write) "W" else "-",
            if (s.no_code) "-" else "X",
            if (s.privilege == .kernel) "P" else "-",
        }) catch unreachable;

        w.print("${X:0>16} ", .{s.get_phys_addr()}) catch unreachable;

        w.print("cache = {s} ", .{switch (s.cache_mode) {
            .uncacheable => "un",
            .write_though => "wt",
            .write_back => "wb",
        }}) catch unreachable;
        w.print("acessed = {: <5} ", .{s.accessed}) catch unreachable;
        w.print("global = {: <5} ", .{s.global}) catch unreachable;
        w.print("pkey = {x:0<4} ", .{s.protection_key}) catch unreachable;
        w.print("atTbl = {: <5}", .{s.attribute_table}) catch unreachable;
    }
};

inline fn Table(Entry: type) type {
    return *[512]Entry;
}

pub const MapPtr = Table(PML45);

// generates a mask to isolate a field of a packed struct while keeping it shifted relative to its bit offset in the struct.
// the field's value is effectively left shifted by its bit offset in the struct and bits outside the field are masked out
fn makeTruncMask(comptime T: type, comptime field: []const u8) @Type(.{ .int = .{ .signedness = .unsigned, .bits = @bitSizeOf(T) } }) {
    const offset = @bitOffsetOf(T, field);
    const size = @bitSizeOf(@TypeOf(@field(@as(T, undefined), field)));

    const size_mask = (1 << size) - 1;
    return size_mask << offset;
}
