/// Runs the active kernel initialization policy up to, but not including, the
/// non-returning transition to the root process.
pub fn initialize(comptime Services: type, root_address_space: anytype) !Services.PreparedRootProcess {
    Services.initializeTerminal();
    Services.writeMessage("Preparing first user process...\n");

    const prepared_root_process = Services.prepareRootProcess(root_address_space) catch |err| {
        Services.setErrorColor();
        Services.writePreparationFailure(err);
        return err;
    };

    Services.finishBoot();
    Services.initializeInterrupts();
    Services.enableInterrupts();
    Services.writeMessage("Launching first user process...\n");
    return prepared_root_process;
}
