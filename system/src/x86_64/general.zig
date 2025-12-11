const std = @import("std");

const serial = @import("io/serial.zig");
const gdt = @import("tables/globalDescriptorTable.zig");
const idt = @import("tables/interruptDescriptorTable.zig");
const pmm = @import("mem/pmm.zig");
const pic = @import("hardware/pic.zig");
const ports = @import("io/ports.zig");
const cpuid = @import("asm/cpuid.zig");

const root = @import("root");
const debug = root.debug;

const log = std.log.scoped(.x86_64);

pub fn pre_init() !void {
    try serial.init();
    log.debug("Serial initialized", .{});

    log_cpu_features();

    log.debug("Installing GDT...", .{});
    gdt.install();
    log.debug("Installing IDT...", .{});
    idt.install();

    log.debug("Setting up Physical Memory Management...", .{});
    pmm.setup();
}

pub fn post_init() !void {
    log.debug("Setting up Programable Interrupt Controller...", .{});
    pic.setup();

    log.debug("Setting up Programable Interval Timer...", .{});
    setup_timer_interval();
}

fn log_cpu_features() void {
    // Cpu features
    const cpu_features = cpuid.cpuid(.type_fam_model_stepping_features, undefined);
    const features_set_1 = cpu_features.features;
    const features_set_2 = cpu_features.features2;

    log.debug(
        \\
        \\ CPU Features Set 1:
        \\    fpu:     {: <5}  vme:    {: <5}  dbg:     {: <5}  pse:     {: <5}
        \\    tsc:     {: <5}  msr:    {: <5}  pae:     {: <5}  mce:     {: <5}
        \\    cx8:     {: <5}  apic:   {: <5}  sep:     {: <5}  mtrr:    {: <5}
        \\    pge:     {: <5}  mca:    {: <5}  cmov:    {: <5}  pat:     {: <5}
        \\    pse36:   {: <5}  psn:    {: <5}  cflush:  {: <5}  dtes:    {: <5}
        \\    acpi:    {: <5}  mmx:    {: <5}  fxsr:    {: <5}  sse:     {: <5}
        \\    sse2:    {: <5}  ss:     {: <5}  htt:     {: <5}  tm1:     {: <5}
        \\    ia64:    {: <5}  pbe:    {: <5}
        \\
    , .{
        features_set_1.fpu,   features_set_1.vme,  features_set_1.dbg,    features_set_1.pse,
        features_set_1.tsc,   features_set_1.msr,  features_set_1.pae,    features_set_1.mce,
        features_set_1.cx8,   features_set_1.apic, features_set_1.sep,    features_set_1.mtrr,
        features_set_1.pge,   features_set_1.mca,  features_set_1.cmov,   features_set_1.pat,
        features_set_1.pse36, features_set_1.psn,  features_set_1.cflush, features_set_1.dtes,
        features_set_1.acpi,  features_set_1.mmx,  features_set_1.fxsr,   features_set_1.sse,
        features_set_1.sse2,  features_set_1.ss,   features_set_1.htt,    features_set_1.tm1,
        features_set_1.ia64,  features_set_1.pbe,
    });
    log.debug(
        \\ CPU Features Set 2:
        \\    sse3:    {: <5}  pclmul: {: <5}  dtes64:  {: <5}  mon:    {: <5}
        \\    dscpl:   {: <5}  vmx:    {: <5}  smx:     {: <5}  est:    {: <5}
        \\    tm2:     {: <5}  ssse3:  {: <5}  cid:     {: <5}  sdbg:   {: <5}
        \\    fma:     {: <5}  cx16:   {: <5}  etprd:   {: <5}  pdcm:   {: <5}
        \\    pcid:    {: <5}  dca:    {: <5}  sse41:   {: <5}  sse42:  {: <5}
        \\    x2apic:  {: <5}  movbe:  {: <5}  popcnt:  {: <5}  tscd:   {: <5}
        \\    aes:     {: <5}  xsave:  {: <5}  osxsave: {: <5}  avx:    {: <5}
        \\    f16c:    {: <5}  rdrand: {: <5}  hv:      {: <5}
        \\
    , .{
        features_set_2.sse3,   features_set_2.pclmul, features_set_2.dtes64,  features_set_2.mon,
        features_set_2.dscpl,  features_set_2.vmx,    features_set_2.smx,     features_set_2.est,
        features_set_2.tm2,    features_set_2.sse3,   features_set_2.cid,     features_set_2.sdbg,
        features_set_2.fma,    features_set_2.cx16,   features_set_2.etprd,   features_set_2.pdcm,
        features_set_2.pcid,   features_set_2.dca,    features_set_2.sse41,   features_set_2.sse42,
        features_set_2.x2apic, features_set_2.movbe,  features_set_2.popcnt,  features_set_2.tscd,
        features_set_2.aes,    features_set_2.xsave,  features_set_2.osxsave, features_set_2.avx,
        features_set_2.f16c,   features_set_2.rdrand, features_set_2.hv,
    });
}

fn setup_timer_interval() void {
    const frquency = 1000; // ms
    const divisor: u16 = 1_193_182 / frquency;

    ports.outb(0x43, 0x36);
    ports.outb(0x40, @intCast(divisor & 0xFF));
    ports.outb(0x40, @intCast((divisor >> 8) & 0xFF));

    pic.pic_enable(0);
}
