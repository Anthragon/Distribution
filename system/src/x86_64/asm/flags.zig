pub inline fn set_interrupt() void {
    asm volatile ("sti");
}
pub inline fn clear_interrupt() void {
    asm volatile ("cli");
}
