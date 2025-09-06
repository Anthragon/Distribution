const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Target = std.Target;
const builtin = @import("builtin");

// imageBuilder dependences references
const imageBuilder = @import("dependencies/image-builder/image-builder/main.zig");
const MiB = imageBuilder.size_constants.MiB;
const GPTr = imageBuilder.size_constants.GPT_reserved_sectors;

const Arch = Target.Cpu.Arch;

const TargetArch = enum { x86_64, aarch64 };
const BiosMode = enum { bios, uefi };
const DiskLayout = enum { MBR, GPT };
const Bootloader = enum { limine };

pub fn build(b: *std.Build) void {
    b.exe_dir = "zig-out/";

    const target_arch = b.option(TargetArch, "tarch", "Target archtecture (Default is host)") orelse switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => std.debug.panic("System not implemented to host archtectore {s}!", .{@tagName(builtin.cpu.arch)}),
    };
    const target_bldr = b.option(Bootloader, "bootloader", "Desired bootloader (Default is Limine)") orelse .limine;

    const target_bios = b.option(BiosMode, "biosMode", "BIOS or UEFI (Default is BIOS)") orelse .bios;
    const disk_layout_temp = b.option(DiskLayout, "diskLayout", "Desired disk layout");

    // qemu options
    const memory = b.option([]const u8, "memory", "How much memory the machine has") orelse "128M";
    const use_gdb = b.option(bool, "useGDB", "use GDB for debugging") orelse false;

    // runtime configuration options
    const systemUsers = b.option([]const u8, "systemUsers", "Default system's users configuration");

    if (target_bios == .uefi and disk_layout_temp == .MBR) @panic("MBR disk layout is not compatible with UEFI!");

    const arch: Arch = switch (target_arch) {
        .aarch64 => .aarch64,
        .x86_64 => .x86_64,
    };
    const disk_layout: DiskLayout = disk_layout_temp orelse switch (target_bios) {
        .bios => .MBR,
        .uefi => .GPT,
    };

    // boot partition
    const bootloader_step = install_bootloader(b, "disk/boot/", arch, target_bios, target_bldr);
    const kernel_step = install_kernel(b, "disk/boot/", arch, target_bios, target_bldr);

    // main partition
    const fs_step = install_fs(
        b,
        "disk/main/",
        arch,
        target_bios,
        target_bldr,
        systemUsers,
    );

    // generate disk image
    const install_disk = addDummyStep(b, "Install Disk Image");
    var disk_step: *Build.Step = undefined;

    // TODO put these in option flags
    const disk_boot_size = 5 * MiB;
    const disk_main_size = 5 * MiB;

    switch (disk_layout) {
        .MBR => {
            const disk_total_size = disk_boot_size + disk_main_size + 65;
            var disk = imageBuilder.addBuildDiskImage(b, .MBR, disk_total_size, null, "Anthragon.img");
            disk.addGap(64); // limine bios-install needs this gap in MBR
            disk.addPartition(.vFAT, "boot", "zig-out/disk/boot", disk_boot_size);
            disk.addPartition(.vFAT, "main", "zig-out/disk/main", disk_main_size);

            const bios_install = b.addSystemCommand(&.{ if (builtin.os.tag == .windows) "limine.exe" else "limine", "bios-install", "zig-out/Anthragon.img" });

            bios_install.step.dependOn(&disk.step);
            install_disk.dependOn(&bios_install.step);
            disk_step = &disk.step;
        },

        .GPT => {
            const total_size = disk_boot_size + disk_main_size + GPTr + 64;
            var disk = imageBuilder.addBuildDiskImage(b, .GPT, total_size, "fadf1974-5373-4ac0-925a-7274169f1117", "Anthragon.img");

            disk.addPartitionWithIdentifier(.vFAT, "boot", "zig-out/disk/boot", disk_boot_size, "2da88725-18ea-4705-ab36-aad1be92e372");
            disk.addPartitionWithIdentifier(.vFAT, "main", "zig-out/disk/main", disk_main_size, "79f1091e-22ed-4be0-8863-a68536572252");
            disk.addPartition(.empty, "limine", "", 64);

            const bios_install = b.addSystemCommand(&.{ if (builtin.os.tag == .windows) "limine.exe" else "limine", "bios-install", "zig-out/Anthragon.img", "3" });

            bios_install.step.dependOn(&disk.step);
            install_disk.dependOn(&bios_install.step);
            disk_step = &disk.step;
        },
    }

    disk_step.dependOn(bootloader_step);
    disk_step.dependOn(kernel_step);
    disk_step.dependOn(fs_step);

    // Generate qemu args and run it
    const Rope = std.ArrayList([]const u8);
    var qemu_args: Rope = .empty;
    const a = b.allocator;
    defer qemu_args.deinit(a);

    switch (target_arch) {
        .aarch64 => {
            qemu_args.append(a, "qemu-system-aarch64") catch @panic("OOM");

            qemu_args.appendSlice(a, &.{ "-cpu", "cortex-a57" }) catch @panic("OOM");
            qemu_args.appendSlice(a, &.{ "-machine", "virt" }) catch @panic("OOM");

            qemu_args.appendSlice(a, &.{ "-device", "virtio-blk-device,drive=hd0,id=blk1" }) catch @panic("OOM");
            qemu_args.appendSlice(a, &.{ "-drive", "id=hd0,file=zig-out/Anthragon.img,format=raw,if=none" }) catch @panic("OOM");

            // for UEFI emulation
            if (target_bios == .uefi) qemu_args.appendSlice(a, &.{ "-bios", "dependencies/debug/aarch64_OVMF.fd" }) catch @panic("OOM");

            // as aarch64 don't have PS/2
            qemu_args.appendSlice(a, &.{ "-device", "qemu-xhci,id=usb" }) catch @panic("OOM");
            qemu_args.appendSlice(a, &.{ "-device", "usb-mouse" }) catch @panic("OOM");
            qemu_args.appendSlice(a, &.{ "-device", "usb-kbd" }) catch @panic("OOM");
            // as aarch64 don't have framebuffer
            qemu_args.appendSlice(a, &.{ "-device", "ramfb" }) catch @panic("OOM");
        },
        .x86_64 => {
            qemu_args.append(a, "qemu-system-x86_64") catch @panic("OOM");

            qemu_args.appendSlice(a, &.{ "-machine", "q35" }) catch @panic("OOM");

            qemu_args.appendSlice(a, &.{ "-device", "ahci,id=ahci" }) catch @panic("OOM");
            qemu_args.appendSlice(a, &.{ "-device", "ide-hd,drive=drive0,bus=ahci.0" }) catch @panic("OOM");
            qemu_args.appendSlice(a, &.{ "-drive", "id=drive0,file=zig-out/Anthragon.img,format=raw,if=none" }) catch @panic("OOM");

            // for UEFI emulation
            if (target_bios == .uefi) qemu_args.appendSlice(a, &.{ "-bios", "dependencies/debug/x86_64_OVMF.fd" }) catch @panic("OOM");
        },
    }

    // general options
    qemu_args.appendSlice(a, &.{ "-m", memory }) catch @panic("OOM");

    qemu_args.appendSlice(a, &.{ "-serial", "file:zig-out/stdout.txt" }) catch @panic("OOM");
    qemu_args.appendSlice(a, &.{ "-serial", "file:zig-out/stderr.txt" }) catch @panic("OOM");

    qemu_args.appendSlice(a, &.{ "-monitor", "mon:stdio" }) catch @panic("OOM");
    qemu_args.appendSlice(a, &.{ "-display", "gtk,zoom-to-fit=on" }) catch @panic("OOM");

    qemu_args.appendSlice(a, &.{ "-D", "zig-out/log.txt" }) catch @panic("OOM");
    qemu_args.appendSlice(a, &.{ "-d", "int,mmu,fpu,cpu_reset,guest_errors,strace" }) catch @panic("OOM");
    qemu_args.appendSlice(a, &.{"--no-reboot"}) catch @panic("OOM");
    qemu_args.appendSlice(a, &.{"--no-shutdown"}) catch @panic("OOM");
    //qemu_args.appendSlice(a, &.{"-trace", "*xhci*"}) catch @panic("OOM");
    if (use_gdb) qemu_args.appendSlice(a, &.{ "-s", "-S" }) catch @panic("OOM");

    qemu_args.appendSlice(a, &.{ "-qmp", "unix:qmp.socket,server,nowait" }) catch @panic("OOM");

    const run_qemu = b.addSystemCommand(qemu_args.items);
    const after_run = b.addSystemCommand(&.{ "bash", "afterrun.sh" });

    // default (only build)
    b.getInstallStep().dependOn(install_disk);

    run_qemu.step.dependOn(b.getInstallStep());
    after_run.step.dependOn(&run_qemu.step);

    // build and run
    const run_step = b.step("run", "Run the OS in qemu");
    run_step.dependOn(&after_run.step);
}

fn install_bootloader(
    b: *std.Build,
    path: []const u8,
    arch: Arch,
    bios: BiosMode,
    bldr: Bootloader,
) *Step {
    _ = bios;
    _ = bldr;

    var arena = std.heap.ArenaAllocator.init(b.allocator);
    const alloc = arena.allocator();
    defer arena.deinit();

    var install_bootloader_step = addDummyStep(b, "Install Bootloader");

    // limine files
    const bootloader = brk: switch (arch) {
        .aarch64 => {
            const dest = std.fs.path.join(alloc, &.{ path, "EFI/BOOT/BOOTAA64.EFI" }) catch @panic("OOM");
            break :brk b.addInstallFile(b.path("dependencies/limine/BOOTAA64.EFI"), dest);
        },
        .x86_64 => {
            const dest = std.fs.path.join(alloc, &.{ path, "EFI/BOOT/BOOTX64.EFI" }) catch @panic("OOM");
            break :brk b.addInstallFile(b.path("dependencies/limine/BOOTX64.EFI"), dest);
        },
        else => unreachable,
    };

    const limine_bios = brk: {
        const dest = std.fs.path.join(alloc, &.{ path, "boot/limine/limine-bios.sys" }) catch @panic("OOM");
        break :brk b.addInstallFile(b.path("dependencies/limine/limine-bios.sys"), dest);
    };
    const limine_config = brk: {
        const dest = std.fs.path.join(alloc, &.{ path, "boot/limine/limine.conf" }) catch @panic("OOM");
        break :brk b.addInstallFile(b.path("dependencies/limine/config.txt"), dest);
    };

    // OS files
    const kernel_config = brk: {
        const dest = std.fs.path.join(alloc, &.{ path, "setup.toml" }) catch @panic("OOM");
        break :brk b.addInstallFile(b.path("fs_config/setup.toml"), dest);
    };

    install_bootloader_step.dependOn(&bootloader.step);
    install_bootloader_step.dependOn(&limine_bios.step);
    install_bootloader_step.dependOn(&limine_config.step);

    install_bootloader_step.dependOn(&kernel_config.step);

    return install_bootloader_step;
}
fn install_kernel(
    b: *std.Build,
    path: []const u8,
    arch: Arch,
    bios: BiosMode,
    bldr: Bootloader,
) *Step {
    _ = bios;
    _ = bldr;

    const install_path = std.fs.path.join(b.allocator, &.{ path, "/kernel" }) catch @panic("OOM");
    defer b.allocator.free(install_path);

    const kernel_dep = b.dependency("kernel", .{ .tarch = arch });
    const kernel = kernel_dep.artifact("kernel");
    const kernel_install = b.addInstallFile(kernel.getEmittedBin(), install_path);

    return &kernel_install.step;
}
fn install_fs(
    b: *std.Build,
    comptime path: []const u8,
    arch: Arch,
    bios: BiosMode,
    bldr: Bootloader,
    system_users_nullable: ?[]const u8,
) *Step {
    _ = arch;
    _ = bios;
    _ = bldr;

    const install_fs_step = addDummyStep(b, "Install File System Root");

    install_fs_step.dependOn(addInstalDir(b, path ++ "/sys"));
    install_fs_step.dependOn(addInstalDir(b, path ++ "/bin"));
    install_fs_step.dependOn(addInstalDir(b, path ++ "/users"));

    var files_to_write = b.addWriteFiles();
    install_fs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = files_to_write.getDirectory(),
        .install_dir = .{ .custom = path },
        .install_subdir = "",
    }).step);

    if (system_users_nullable) |system_users| {
        const User = struct {
            name: []const u8,
            guid: []const u8,
            perm: []const u8,
        };
        var users = std.ArrayList(User).empty;

        var iterator = std.mem.splitScalar(u8, system_users, ',');
        while (iterator.peek()) |_| {
            const username = iterator.next() orelse @panic("Invalid user string!");
            const userguid = iterator.next() orelse @panic("Invalid user string!");
            const userperm = iterator.next() orelse @panic("Invalid user string!");
            users.append(b.allocator, .{
                .name = username,
                .guid = userguid,
                .perm = userperm,
            }) catch unreachable;
        }

        var filebuf = std.ArrayList(u8).empty;
        const w = filebuf.writer(b.allocator);

        for (users.items) |i| {
            w.writeAll("[[user]]\n") catch unreachable;
            w.print("name = '{s}'\n", .{i.name}) catch unreachable;
            w.print("uuid = '{s}'\n", .{i.guid}) catch unreachable;
            w.print("perm = '{s}'\n", .{i.perm}) catch unreachable;
            w.writeByte('\n') catch unreachable;
        }

        users.deinit(b.allocator);
        _ = files_to_write.add("sys/users.toml", filebuf.items);
    }

    return install_fs_step;
}

fn addDummyStep(b: *Build, name: []const u8) *Step {
    const step = b.allocator.create(Step) catch unreachable;
    step.* = Step.init(.{ .id = .custom, .name = name, .owner = b });
    return step;
}
fn addInstalDir(b: *Build, path: []const u8) *Step {
    const dest = std.fs.path.join(b.allocator, &.{ b.install_path, path }) catch @panic("OOM");
    return &b.addSystemCommand(&.{ "mkdir", "-p", dest }).step;
}
