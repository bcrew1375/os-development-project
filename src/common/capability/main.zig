//! Public facade for bounded capability spaces and protected kernel-object access.

const derivation = @import("derivation.zig");
const errors = @import("errors.zig");
const ipc_capabilities = @import("ipc_capabilities.zig");
const memory_capabilities = @import("memory_capabilities.zig");
const process_capabilities = @import("process_capabilities.zig");
const storage = @import("storage.zig");

pub const space = @import("space.zig");
pub const CapabilityError = errors.CapabilityError;
pub const MAX_CAPABILITIES = storage.MAX_CAPABILITIES;
pub const PreparedInstall = derivation.PreparedInstall;

pub const createAddressSpaceCapability = memory_capabilities.createAddressSpaceCapability;
pub const registerAddressSpaceRootCapability =
    memory_capabilities.registerAddressSpaceRootCapability;
pub const findAddressSpaceCapability = memory_capabilities.findAddressSpaceCapability;
pub const destroyAddressSpaceCapability = memory_capabilities.destroyAddressSpaceCapability;
pub const createMemoryObjectCapability = memory_capabilities.createMemoryObjectCapability;
pub const destroyMemoryObjectCapability = memory_capabilities.destroyMemoryObjectCapability;
pub const createUntypedMemoryCapability = memory_capabilities.createUntypedMemoryCapability;
pub const retypeUntypedMemoryCapability = memory_capabilities.retypeUntypedMemoryCapability;
pub const resolveAddressSpace = memory_capabilities.resolveAddressSpace;
pub const resolveMemoryObject = memory_capabilities.resolveMemoryObject;
pub const resolveUntypedMemory = memory_capabilities.resolveUntypedMemory;
pub const resolvePhysicalFrame = memory_capabilities.resolvePhysicalFrame;
pub const destroyUntypedMemoryCapability = memory_capabilities.destroyUntypedMemoryCapability;
pub const deletePhysicalMemoryCapability = memory_capabilities.deletePhysicalMemoryCapability;
pub const revokePhysicalMemoryCapability = memory_capabilities.revokePhysicalMemoryCapability;

pub const createCapabilitySpaceCapability = process_capabilities.createCapabilitySpaceCapability;
pub const createThreadCapability = process_capabilities.createThreadCapability;
pub const resolveCapabilitySpace = process_capabilities.resolveCapabilitySpace;
pub const resolveThread = process_capabilities.resolveThread;
pub const destroyThreadCapability = process_capabilities.destroyThreadCapability;
pub const destroyCapabilitySpaceCapability = process_capabilities.destroyCapabilitySpaceCapability;

pub const createEndpointCapability = ipc_capabilities.createEndpointCapability;
pub const createNotificationCapability = ipc_capabilities.createNotificationCapability;
pub const createInterruptSourceCapability = ipc_capabilities.createInterruptSourceCapability;
pub const resolveEndpoint = ipc_capabilities.resolveEndpoint;
pub const resolveNotification = ipc_capabilities.resolveNotification;
pub const resolveInterruptSource = ipc_capabilities.resolveInterruptSource;
pub const sendEndpointMessage = ipc_capabilities.sendEndpointMessage;
pub const receiveEndpointMessage = ipc_capabilities.receiveEndpointMessage;
pub const destroyEndpointCapability = ipc_capabilities.destroyEndpointCapability;
pub const destroyNotificationCapability = ipc_capabilities.destroyNotificationCapability;
pub const destroyInterruptSourceCapability = ipc_capabilities.destroyInterruptSourceCapability;

pub const installCapability = derivation.installCapability;
pub const prepareExactInstall = derivation.prepareExactInstall;
pub const validateTransferSource = derivation.validateTransferSource;
pub const validateExactDestination = derivation.validateExactDestination;
pub const commitExactInstall = derivation.commitExactInstall;
pub const rollbackExactInstall = derivation.rollbackExactInstall;
pub const deleteCapabilityFromSpace = derivation.deleteCapabilityFromSpace;
pub const deleteCapability = derivation.deleteCapability;

pub const availableCount = storage.availableCount;
pub const availableCountIn = storage.availableCountIn;
pub const activeCount = storage.activeCount;
pub const activeCountIn = storage.activeCountIn;

pub fn resetForTest() void {
    storage.resetForTest();
    ipc_capabilities.resetForTest();
}
