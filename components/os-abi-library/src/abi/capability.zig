//! Capability ABI types shared across protection domains.

const std = @import("std");
const abi_error_bit: u32 = 1 << 31;

/// Opaque capability table handle.
pub const CapabilityHandle = u32;
/// Reserved invalid capability handle value.
pub const INVALID_CAPABILITY: CapabilityHandle = 0;

/// Number of low-order bits used to encode a capability slot index.
pub const CAPABILITY_SLOT_BITS: u32 = 7;
/// Number of high-order bits used to encode a capability generation.
pub const CAPABILITY_GENERATION_BITS = @bitSizeOf(CapabilityHandle) - CAPABILITY_SLOT_BITS - 1;
/// Maximum capability-table slot index representable by a handle.
pub const MAX_CAPABILITY_SLOT_INDEX: u32 = (@as(u32, 1) << CAPABILITY_SLOT_BITS) - 1;
/// Maximum generation representable by a capability handle.
pub const MAX_CAPABILITY_GENERATION: u32 = (@as(u32, 1) << CAPABILITY_GENERATION_BITS) - 1;

pub const CapabilityHandleParts = struct {
    slot_index: u32,
    generation: u32,
};

/// Encodes a slot index and nonzero generation into an architecture-independent handle.
pub fn makeCapabilityHandle(slot_index: u32, generation: u32) CapabilityHandle {
    std.debug.assert(slot_index <= MAX_CAPABILITY_SLOT_INDEX);
    std.debug.assert(generation > 0 and generation <= MAX_CAPABILITY_GENERATION);
    return (generation << CAPABILITY_SLOT_BITS) | slot_index;
}

/// Extracts the slot index from an encoded capability handle.
pub fn capabilitySlotIndex(handle: CapabilityHandle) u32 {
    return handle & MAX_CAPABILITY_SLOT_INDEX;
}

/// Extracts the generation from an encoded capability handle.
pub fn capabilityGeneration(handle: CapabilityHandle) u32 {
    return handle >> CAPABILITY_SLOT_BITS;
}

/// Decodes a capability handle into its slot and generation fields.
pub fn decodeCapabilityHandle(handle: CapabilityHandle) ?CapabilityHandleParts {
    if (handle == INVALID_CAPABILITY) return null;
    const generation = capabilityGeneration(handle);
    if (generation == 0) return null;
    return .{
        .slot_index = capabilitySlotIndex(handle),
        .generation = generation,
    };
}

/// Kernel object categories that may be referenced by capabilities.
pub const ObjectType = enum(u32) {
    /// Empty or invalid object slot.
    null = 0,
    /// Address-space object.
    address_space = 1,
    /// Memory-object object.
    memory_object = 2,
    /// Authority over an immutable physical-memory range.
    untyped_memory = 3,
    /// Typed authority over immutable physical frames.
    physical_frame = 4,
    /// Schedulable userspace thread object.
    thread = 5,
    /// Bounded namespace containing capability slots.
    capability_space = 6,
    _,
};

/// Access rights associated with a capability.
pub const Rights = packed struct(u32) {
    /// Allows read access to the object.
    read: bool = false,
    /// Allows write or mutation access to the object.
    write: bool = false,
    /// Allows executable mappings or execute authority where applicable.
    execute: bool = false,
    /// Allows management operations such as deriving or mapping.
    manage: bool = false,
    /// Allows binding a thread to execution resources.
    configure: bool = false,
    /// Allows making a configured thread runnable for the first time.
    start: bool = false,
    /// Allows stopping a runnable thread without terminating it.
    suspend_thread: bool = false,
    /// Allows returning a suspended thread to the ready queue.
    resume_thread: bool = false,
    /// Allows recording normal termination for a thread.
    terminate: bool = false,
    _reserved: u23 = 0,

    /// Returns true when `self` grants every right requested by `required`.
    pub fn contains(self: Rights, required: Rights) bool {
        return (!required.read or self.read) and
            (!required.write or self.write) and
            (!required.execute or self.execute) and
            (!required.manage or self.manage) and
            (!required.configure or self.configure) and
            (!required.start or self.start) and
            (!required.suspend_thread or self.suspend_thread) and
            (!required.resume_thread or self.resume_thread) and
            (!required.terminate or self.terminate);
    }
};

/// Rights bits accepted by capability-management ABI requests.
pub const KNOWN_RIGHTS_MASK: u32 = 0x01ff;

/// Encodes capability rights into their stable ABI representation.
pub fn rightsBits(rights: Rights) u32 {
    return @bitCast(rights);
}

/// Decodes rights after rejecting reserved bits.
pub fn rightsFromBits(bits: u32) ?Rights {
    if ((bits & ~KNOWN_RIGHTS_MASK) != 0) return null;
    return @bitCast(bits);
}

comptime {
    std.debug.assert(@bitSizeOf(CapabilityHandle) == 32);
    std.debug.assert(CAPABILITY_SLOT_BITS + CAPABILITY_GENERATION_BITS + 1 == @bitSizeOf(CapabilityHandle));
    std.debug.assert(INVALID_CAPABILITY == 0);
    std.debug.assert(makeCapabilityHandle(0, 1) != INVALID_CAPABILITY);
    std.debug.assert((makeCapabilityHandle(MAX_CAPABILITY_SLOT_INDEX, MAX_CAPABILITY_GENERATION) & abi_error_bit) == 0);
}
