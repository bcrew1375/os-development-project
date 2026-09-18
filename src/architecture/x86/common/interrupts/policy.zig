pub const MASTER_VECTOR_OFFSET: usize = 0x20;
pub const SLAVE_VECTOR_OFFSET: usize = 0x28;

pub fn isHardwareInterrupt(vector: usize) bool {
    return vector >= MASTER_VECTOR_OFFSET and vector < SLAVE_VECTOR_OFFSET + 8;
}
