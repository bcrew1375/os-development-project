//! Capability ABI types shared across protection domains.

/// Opaque capability table handle.
pub const CapabilityHandle = u32;
/// Reserved invalid capability handle value.
pub const INVALID_CAPABILITY: CapabilityHandle = 0;

/// Kernel object categories that may be referenced by capabilities.
pub const ObjectType = enum(u32) {
    /// Empty or invalid object slot.
    null = 0,
    /// Address-space object.
    address_space = 1,
    /// Memory-object object.
    memory_object = 2,
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
    _reserved: u28 = 0,

    /// Returns true when `self` grants every right requested by `required`.
    pub fn contains(self: Rights, required: Rights) bool {
        return (!required.read or self.read) and
            (!required.write or self.write) and
            (!required.execute or self.execute) and
            (!required.manage or self.manage);
    }
};
