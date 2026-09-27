const builtin = @import("builtin");

pub const is_wasm = builtin.os.tag == .wasi;
pub const is_windows = builtin.os.tag == .windows;
