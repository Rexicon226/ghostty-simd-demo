const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Just mock up a couple of targets to try.

    // This is just a baseline x86_64.
    const baseline_target = std.Target.Query{
        .abi = .gnu,
        .cpu_arch = .x86_64,
    };

    var avx2_feature = std.Target.Cpu.Feature.Set.empty;
    const avx2: std.Target.x86.Feature = .avx2;
    avx2_feature.addFeature(@intFromEnum(avx2));

    // baseline+avx2
    const avx2_target = std.Target.Query{
        .abi = .gnu,
        .cpu_arch = .x86_64,
        .cpu_features_add = avx2_feature,
    };

    const targets = &.{
        .{ "baseline", baseline_target },
        .{ "avx2", avx2_target },
    };

    // This is in baseline, because avx2 is added later.
    const exe = b.addExecutable(.{
        .name = "poc",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.resolveTargetQuery(baseline_target),
        .optimize = optimize,
    });

    // Ghostty links libc which causes it to use DlDynLib, which we will emulate here.
    exe.linkLibC();

    // Libs
    inline for (targets) |target| {
        const lib = b.addSharedLibrary(.{
            .name = target[0],
            .root_source_file = .{ .path = "src/lib.zig" },
            .target = b.resolveTargetQuery(target[1]),
            .optimize = optimize,
        });

        // Could probably improve naming.
        // This causes `lib` to become a dependency of exe just saying.
        exe.root_module.addAnonymousImport(b.fmt("{s}_path", .{target[0]}), .{
            .root_source_file = lib.getEmittedBin(),
        });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
