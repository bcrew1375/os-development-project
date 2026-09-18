const port_io = @import("../platform/io/port_io.zig");
const policy = @import("policy.zig");

pub const MASTER_VECTOR_OFFSET: u8 = 0x20;
pub const SLAVE_VECTOR_OFFSET: u8 = 0x28;

pub const TIMER_IRQ: u8 = 0;
pub const KEYBOARD_IRQ: u8 = 1;
pub const CASCADE_IRQ: u8 = 2;

const MASTER_COMMAND_PORT: u16 = 0x20;
const MASTER_DATA_PORT: u16 = 0x21;
const SLAVE_COMMAND_PORT: u16 = 0xA0;
const SLAVE_DATA_PORT: u16 = 0xA1;

const END_OF_INTERRUPT: u8 = 0x20;

const ICW1_INITIALIZE: u8 = 0x10;
const ICW1_EXPECT_ICW4: u8 = 0x01;
const ICW4_8086_MODE: u8 = 0x01;

const MASTER_HAS_SLAVE_ON_IRQ2: u8 = 0x04;
const SLAVE_CASCADE_IDENTITY: u8 = 0x02;

const TOTAL_IRQS: u8 = 16;

/// Remaps the legacy 8259 PIC pair while preserving interrupt masks.
pub fn remap(master_vector_offset: u8, slave_vector_offset: u8) void {
    const master_mask = port_io.in8(MASTER_DATA_PORT);
    const slave_mask = port_io.in8(SLAVE_DATA_PORT);

    port_io.out8(MASTER_COMMAND_PORT, ICW1_INITIALIZE | ICW1_EXPECT_ICW4);
    ioWait();
    port_io.out8(SLAVE_COMMAND_PORT, ICW1_INITIALIZE | ICW1_EXPECT_ICW4);
    ioWait();

    port_io.out8(MASTER_DATA_PORT, master_vector_offset);
    ioWait();
    port_io.out8(SLAVE_DATA_PORT, slave_vector_offset);
    ioWait();

    port_io.out8(MASTER_DATA_PORT, MASTER_HAS_SLAVE_ON_IRQ2);
    ioWait();
    port_io.out8(SLAVE_DATA_PORT, SLAVE_CASCADE_IDENTITY);
    ioWait();

    port_io.out8(MASTER_DATA_PORT, ICW4_8086_MODE);
    ioWait();
    port_io.out8(SLAVE_DATA_PORT, ICW4_8086_MODE);
    ioWait();

    port_io.out8(MASTER_DATA_PORT, master_mask);
    port_io.out8(SLAVE_DATA_PORT, slave_mask);
}

pub fn maskAll() void {
    port_io.out8(MASTER_DATA_PORT, 0xFF);
    port_io.out8(SLAVE_DATA_PORT, 0xFF);
}

pub fn setMask(irq: u8) void {
    if (irq >= TOTAL_IRQS) return;

    const mask = irqMask(irq);
    const data_port = dataPortForIrq(irq);
    port_io.out8(data_port, port_io.in8(data_port) | mask);
}

pub fn clearMask(irq: u8) void {
    if (irq >= TOTAL_IRQS) return;

    if (irq >= 8) {
        clearMask(CASCADE_IRQ);
    }

    const mask = irqMask(irq);
    const data_port = dataPortForIrq(irq);
    port_io.out8(data_port, port_io.in8(data_port) & ~mask);
}

pub fn sendEndOfInterrupt(vector: usize) void {
    if (!isHardwareInterrupt(vector)) return;

    const irq = vector - MASTER_VECTOR_OFFSET;
    if (irq >= 8) {
        port_io.out8(SLAVE_COMMAND_PORT, END_OF_INTERRUPT);
    }
    port_io.out8(MASTER_COMMAND_PORT, END_OF_INTERRUPT);
}

pub fn isHardwareInterrupt(vector: usize) bool {
    return policy.isHardwareInterrupt(vector);
}

fn dataPortForIrq(irq: u8) u16 {
    return if (irq < 8) MASTER_DATA_PORT else SLAVE_DATA_PORT;
}

fn irqMask(irq: u8) u8 {
    return @as(u8, 1) << @intCast(irq % 8);
}

fn ioWait() void {
    port_io.out8(0x80, 0);
}
