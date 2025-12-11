const std = @import("std");
const root = @import("root");
const io = @import("../io/ports.zig");

pub fn setup() void {
    io.outb(0x20, 0x11); // Send 0x11 (ICW1) to master PIC (port 0x20)
    io.outb(0xA0, 0x11); // Send 0x11 (ICW1) to slave  PIC (port 0xA0)

    io.outb(0x21, 0x20); // Configurate the master PIC interruption vector base (0x20)
    io.outb(0xA1, 0x28); // Configurate the slave  PIC interruption vector base (0x28)

    io.outb(0x21, 0x04); // Configurate the comunication line betwen master - slave PIC (IR2)
    io.outb(0xA1, 0x02); // PIC is on line 2

    io.outb(0x21, 0x01); // Enables 8086/88 (ICW4) in master PIC
    io.outb(0xA1, 0x01); // Enables 8086/88 (ICW4) in slave  PIC

    io.outb(0x21, 0xff); // Disables all interrupts from master PIC
    io.outb(0xA1, 0xff); // Disables all interrupts from slave  PIC
}

pub fn pic_disable(irq: u8) void {
    var port: u16 = undefined;
    var irq_bit: u8 = undefined;

    if (irq < 8) {
        port = 0x21;
        irq_bit = irq;
    } else {
        port = 0xA1;
        irq_bit = irq - 8;
    }

    var mask: u8 = io.inb(port);
    mask |= std.math.shl(u8, 1, irq_bit);
    io.outb(port, mask);
}
pub fn pic_enable(irq: u8) void {
    var port: u16 = undefined;
    var irq_bit: u8 = undefined;

    if (irq < 8) {
        port = 0x21;
        irq_bit = irq;
    } else {
        port = 0xA1;
        irq_bit = irq - 8;
    }

    var mask: u8 = io.inb(port);
    mask &= ~std.math.shl(u8, 1, irq_bit);
    io.outb(port, mask);
}
