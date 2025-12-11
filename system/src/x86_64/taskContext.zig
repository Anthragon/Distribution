const std = @import("std");
const root = @import("root");
const gdt = @import("tables/globalDescriptorTable.zig");
const idt = @import("tables/interruptDescriptorTable.zig");

pub const TaskContext = extern struct {

    // Extra control registers
    cr2: u64,
    es: u64,
    ds: u64,

    // SIMD registers
    simd: extern struct {
        // FPU control registers
        fcw: u16,
        fsw: u16,
        ftw: u8,
        _rsvd_0: u8,
        fop: u16,

        // FPU instruction and data pointers
        fip: u32,
        fcs: u16,
        _rsvd_1: u16,
        fdp: u32,
        fds: u16,
        _rsvd_2: u16,

        mxcsr: u32,
        mxcsr_mask: u32,

        // 8 x87/MMX registers (each 10 bytes, padded to 16 bytes)
        st_mm: [8]u128,

        // 16 XMM registers (128 bits = 16 bytes each)
        xmm: [16]u128,

        // Reserved space (for future extensions)
        reserved4: [96]u8,

        /// Ensure 16-byte alignment (needed by fxsave/fxrstor)
        _align: u0 align(16),
    },

    // General purpose registers
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    /// Interrupt number
    intnum: u64,

    // Fetched by the cpu
    error_code: u64,
    rip: u64,
    cs: u64,
    eflags: Flags,
    rsp: u64,
    ss: u64,

    pub inline fn set_instruction_ptr(s: *@This(), value: usize) void {
        s.rip = @as(u64, value);
    }
    pub inline fn get_instruction_ptr(s: *@This()) usize {
        return s.rip;
    }

    pub inline fn set_stack_ptr(s: *@This(), value: usize) void {
        s.rsp = @as(u64, value);
        s.rbp = @as(u64, value);
    }
    pub inline fn get_stack_ptr(s: *@This()) usize {
        return s.rsp;
    }

    pub inline fn set_frame_base(s: *@This(), value: usize) void {
        s.rbp = value;
    }
    pub inline fn get_frame_base(s: *@This()) usize {
        return s.rbp;
    }

    pub fn set_arg(s: *@This(), value: usize, arg: usize) void {
        switch (arg) {
            0 => s.rdi = @as(u64, value),
            1 => s.rsi = @as(u64, value),
            2 => s.rdx = @as(u64, value),
            3 => s.rcx = @as(u64, value),
            4 => s.r8 = @as(u64, value),
            5 => s.r9 = @as(u64, value),
            else => unreachable, // Implement it if needed
        }
    }
    pub fn get_arg(s: *@This(), arg: usize) usize {
        return switch (arg) {
            0 => s.rdi,
            1 => s.rsi,
            2 => s.rdx,
            3 => s.rcx,
            4 => s.r8,
            5 => s.r9,
            else => unreachable, // Implement it if needed
        };
    }

    pub inline fn get_return(s: *@This()) usize {
        return s.rax;
    }

    pub fn set_flags(s: *@This(), flags: root.lib.common.TaskGeneralFlags) void {
        s.eflags.carry = flags.carry;
        s.eflags.interrupt = flags.interrupt;
        s.eflags.overflow = flags.overflow;
        s.eflags.sign = flags.sign;
        s.eflags.zero = flags.zero;
    }
    pub fn get_flags(s: *@This()) root.system.TaskGeneralFlags {
        return .{
            .carry = s.eflags.carry,
            .zero = s.eflags.zero,
            .sign = s.eflags.sign,
            .overflow = s.eflags.overflow,
            .interrupt = s.eflags.interrupt,
        };
    }
    pub fn set_privilege(s: *@This(), p: root.lib.Privilege) void {
        if (p == .kernel) {
            s.cs = gdt.selector.code64;
            s.ss = gdt.selector.data64;
            s.es = gdt.selector.data64;
            s.ds = gdt.selector.data64;
        } else if (p == .user) {
            s.cs = gdt.selector.usercode64;
            s.ss = gdt.selector.userdata64;
            s.es = gdt.selector.userdata64;
            s.ds = gdt.selector.userdata64;
        } else {
            @panic("Invalid privilege level");
        }
    }

    pub fn format(self: *const @This(), fmt: anytype) !void {

        // General purpose registers
        try fmt.print("RAX={x:0>16} RBX={x:0>16} RCX={x:0>16} RDX={x:0>16}\n", .{ self.rax, self.rbx, self.rcx, self.rdx });
        try fmt.print("RSI={x:0>16} RDI={x:0>16} RBP={x:0>16} RSP={x:0>16}\n", .{ self.rsi, self.rdi, self.rbp, self.rsp });
        try fmt.print("R8 ={x:0>16} R9 ={x:0>16} R10={x:0>16} R11={x:0>16}\n", .{ self.r8, self.r9, self.r10, self.r11 });
        try fmt.print("R12={x:0>16} R13={x:0>16} R14={x:0>16} R15={x:0>16}\n", .{ self.r12, self.r13, self.r14, self.r15 });

        // SIMD registers
        try fmt.print("FCW={x:0>4} FSW={x:0>4} FTW={x:0>2} FOP={x:0>4}\n", .{ self.simd.fcw, self.simd.fsw, self.simd.ftw, self.simd.fop });
        try fmt.print("FIP={x:0>8} FCS={x:0>4} FDP={x:0>4} FDS={x:0>2}\n", .{ self.simd.fip, self.simd.fcs, self.simd.fdp, self.simd.fds });

        try fmt.print("MM0={x:0>20} MM1={x:0>20} MM2={x:0>20}\n", .{ self.simd.st_mm[0], self.simd.st_mm[1], self.simd.st_mm[2] });
        try fmt.print("MM3={x:0>20} MM4={x:0>20} MM5={x:0>20}\n", .{ self.simd.st_mm[3], self.simd.st_mm[4], self.simd.st_mm[5] });
        try fmt.print("MM6={x:0>20} MM7={x:0>20}\n", .{ self.simd.st_mm[6], self.simd.st_mm[7] });

        try fmt.print("XMM0 ={x:0>32} XMM1 ={x:0>32}\n", .{ self.simd.xmm[0], self.simd.xmm[1] });
        try fmt.print("XMM2 ={x:0>32} XMM3 ={x:0>32}\n", .{ self.simd.xmm[2], self.simd.xmm[3] });
        try fmt.print("XMM4 ={x:0>32} XMM5 ={x:0>32}\n", .{ self.simd.xmm[4], self.simd.xmm[5] });
        try fmt.print("XMM6 ={x:0>32} XMM7 ={x:0>32}\n", .{ self.simd.xmm[6], self.simd.xmm[7] });
        try fmt.print("XMM8 ={x:0>32} XMM9 ={x:0>32}\n", .{ self.simd.xmm[8], self.simd.xmm[9] });
        try fmt.print("XMM10={x:0>32} XMM11={x:0>32}\n", .{ self.simd.xmm[10], self.simd.xmm[11] });
        try fmt.print("XMM12={x:0>32} XMM13={x:0>32}\n", .{ self.simd.xmm[12], self.simd.xmm[13] });
        try fmt.print("XMM14={x:0>32} XMM15={x:0>32}\n", .{ self.simd.xmm[14], self.simd.xmm[15] });

        // rip, flags, privilege level
        try fmt.print("rip={x:0>16} ", .{self.rip});
        try fmt.print("FLG={X:7} [{c}{c}{c}{c}{c}{c}{c}{c}] CPL={} INT={X:0>8} ERR={X:0>16}\n", .{
            @as(u64, @bitCast(self.eflags)) & 0xffffffff,
            @as(u8, if (self.eflags.overflow) 'O' else '-'), // OF: Overflow Flag
            @as(u8, if (self.eflags.interrupt) 'I' else '-'), // IF: Interrupt Flag
            @as(u8, if (self.eflags.trap) 'T' else '-'), // TF: Trap Flag
            @as(u8, if (self.eflags.sign) 'S' else '-'), // SF: Sign Flag
            @as(u8, if (self.eflags.zero) 'Z' else '-'), // ZF: Zero Flag
            @as(u8, if (self.eflags.auxiliary) 'A' else '-'), // AF: Auxiliary Carry
            @as(u8, if (self.eflags.parity) 'P' else '-'), // PF: Parity Flag
            @as(u8, if (self.eflags.carry) 'C' else '-'), // CF: Carry Flag

            self.cs & 0b11,
            self.intnum,
            self.error_code,
        });

        // Segment selectors
        try write_segment(fmt, "ES", self.es);
        try write_segment(fmt, "CS", self.cs);
        try write_segment(fmt, "SS", self.ss);
        try write_segment(fmt, "DS", self.ds);

        try fmt.print("GDT=     {X:0>16} {X:0>8}\n", .{ gdt.get_ptr().base, gdt.get_ptr().limit });
        try fmt.print("IDT=     {X:0>16} {X:0>8}\n", .{ idt.get_ptr().base, idt.get_ptr().limit });

        try fmt.print("CR2={x:0>16} INT={x:0>8}\n", .{ self.cr2, self.intnum });
    }
    fn write_segment(writer: anytype, reg: *const [2:0]u8, selector: usize) !void {
        const index = selector >> 3;
        const entry = gdt.tables[index];

        try writer.print("{s}= {X:0>4} {X:0>16} {X:0>8} {X:0>8} DPL={} {s: <8} [{c}{c}{c}]\n", .{
            reg,
            index,

            (@as(u32, @intCast(entry.base_high)) << 16) | (@as(u32, @intCast(entry.base_middle)) << 8) | @as(u32, @intCast(entry.base_low)),
            (@as(u32, @intCast(entry.limit_high)) << 16) | @as(u32, @intCast(entry.limit_low)),

            (@as(u32, @intCast(@as(u8, @bitCast(entry.access)))) << 24) | (@as(u32, @intCast(@as(u4, @bitCast(entry.flags)))) << 20) | (@as(u32, @intCast(@as(u4, @truncate(entry.limit_high)))) << 16) | (@as(u32, @intCast(@as(u4, @truncate(entry.base_high)))) << 8),

            entry.access.privilege,
            ststr(@intFromEnum(entry.access.segment_type), @truncate(@as(u8, @bitCast(entry.access)) & 0x0f)),

            @as(u8, if (entry.access.executable) 'X' else '-'),
            @as(u8, if (entry.access.readable_writeable) 'W' else 'R'),
            @as(u8, if (entry.access.acessed) 'A' else '-'),
        });
    }
    /// Descriptor Type String
    fn ststr(s: u1, typ: u4) []const u8 {
        if (s == 1) return switch (typ) {
            0x0 => "DataRO",
            0x1 => "DROAcc",
            0x2 => "DataRW",
            0x3 => "DRWAcc",
            0x4 => "DRODown",
            0x5 => "DRDAcc",
            0x6 => "DRWDown",
            0x7 => "DWDAcc",
            0x8 => "CodeX",
            0x9 => "CXAcc",
            0xA => "CodeXR",
            0xB => "CXRAcc",
            0xC => "CXConf",
            0xD => "CXCAcc",
            0xE => "CXRCnf",
            0xF => "CXRAcC",
        } else return switch (typ) {
            0x1 => "TSSAv16",
            0x2 => "LDT",
            0x3 => "TSSBs16",
            0x4 => "Call16",
            0x5 => "TaskGt",
            0x6 => "Int16",
            0x7 => "Trap16",
            0x9 => "TSSAv32",
            0xB => "TSSBs32",
            0xC => "Call32",
            0xE => "Int32",
            0xF => "Trap32",
            else => "SysResv",
        };
    }
};

const Flags = packed struct(u64) {
    carry: bool, // Bit 0: CF - Carry Flag
    reserved_1: u1, // Bit 1: Reserved (always 1 in EFLAGS), ignored in RFLAGS
    parity: bool, // Bit 2: PF - Parity Flag
    reserved_3: u1, // Bit 3: Reserved
    auxiliary: bool, // Bit 4: AF - Auxiliary Carry Flag
    reserved_5: u1, // Bit 5: Reserved
    zero: bool, // Bit 6: ZF - Zero Flag
    sign: bool, // Bit 7: SF - Sign Flag
    trap: bool, // Bit 8: TF - Trap Flag
    interrupt: bool, // Bit 9: IF - Interrupt Enable Flag
    direction: bool, // Bit 10: DF - Direction Flag
    overflow: bool, // Bit 11: OF - Overflow Flag
    io_privilege: u2, // Bits 12–13: IOPL - I/O Privilege Level
    nested_task: bool, // Bit 14: NT - Nested Task
    reserved_15: u1, // Bit 15: Reserved (was RF in EFLAGS, now in DR6)
    @"resume": bool, // Bit 16: RF - Resume Flag
    virtual_8086: bool, // Bit 17: VM - Virtual 8086 Mode
    alignment_check: bool, // Bit 18: AC - Alignment Check
    virtual_interrupt: bool, // Bit 19: VIF - Virtual Interrupt Flag
    virtual_interrupt_pending: bool, // Bit 20: VIP - Virtual Interrupt Pending
    id: bool, // Bit 21: ID - ID Flag (CPUID enable)
    reserved_high: u42, // Bits 22–63: Reserved
};
