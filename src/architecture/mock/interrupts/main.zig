const MAX_INSTALLED_VECTORS = 256;
const MAX_ACKNOWLEDGEMENTS = 256;

pub const InstalledVector = struct {
    interrupt_vector: usize,
    address: usize,
    type_attribute: usize,
};

pub const State = struct {
    initialization_count: usize = 0,
    installed_vectors: [MAX_INSTALLED_VECTORS]InstalledVector = undefined,
    installed_vector_count: usize = 0,
    enabled: bool = false,
    enable_count: usize = 0,
    disable_count: usize = 0,
    acknowledgements: [MAX_ACKNOWLEDGEMENTS]usize = undefined,
    acknowledgement_count: usize = 0,
};

var state = State{};

pub fn initialize() void {
    state.initialization_count += 1;
}

pub fn set(interruptVector: usize, address: usize, typeAttribute: usize) void {
    if (state.installed_vector_count >= state.installed_vectors.len) {
        @panic("mock interrupt vector observation capacity exceeded");
    }
    state.installed_vectors[state.installed_vector_count] = .{
        .interrupt_vector = interruptVector,
        .address = address,
        .type_attribute = typeAttribute,
    };
    state.installed_vector_count += 1;
}

pub fn enableInterrupts() void {
    state.enabled = true;
    state.enable_count += 1;
}

pub fn disableInterrupts() void {
    state.enabled = false;
    state.disable_count += 1;
}

pub fn acknowledgeInterrupt(vector: usize) void {
    if (state.acknowledgement_count >= state.acknowledgements.len) {
        @panic("mock interrupt acknowledgement observation capacity exceeded");
    }
    state.acknowledgements[state.acknowledgement_count] = vector;
    state.acknowledgement_count += 1;
}

pub fn resetForTest() void {
    state = State{};
}

pub fn getStateForTest() *const State {
    return &state;
}

pub fn getInstalledVectorsForTest() []const InstalledVector {
    return state.installed_vectors[0..state.installed_vector_count];
}

pub fn getAcknowledgementsForTest() []const usize {
    return state.acknowledgements[0..state.acknowledgement_count];
}
