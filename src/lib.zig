//! Into this file we put any functions that we want to compile to all of the targets.
//! Does need to be callconv(.C)

const std = @import("std");
const builtin = @import("builtin");

export fn hello() callconv(.C) void {
    const has_avx2 = blk: {
        const features = builtin.cpu.features;
        const avx2: std.Target.x86.Feature = .avx2;
        break :blk features.isEnabled(@intFromEnum(avx2));
    };

    std.debug.print("Has AVX2 enabled: {}\n", .{has_avx2});
}
