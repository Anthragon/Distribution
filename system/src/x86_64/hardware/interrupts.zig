const root = @import("root");
const sys = @import("system");
const idt = @import("../tables/interruptDescriptorTable.zig");
const pic = @import("pic.zig");

pub const set_privilege = idt.set_privilege;
pub const mask_irq = pic.pic_disable;
pub const unmask_irq = pic.pic_enable;
