const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Features
    const baseline_target = std.Target.Query{
        .abi = .gnu,
        .cpu_arch = .x86_64,
    };

    var avx2_feature = std.Target.Cpu.Feature.Set.empty;
    const avx2: std.Target.x86.Feature = .avx2;
    avx2_feature.addFeature(@intFromEnum(avx2));

    const avx2_target = std.Target.Query{
        .abi = .gnu,
        .cpu_arch = .x86_64,
        .cpu_features_add = avx2_feature,
    };

    const targets = &.{
        .{ "baseline", baseline_target },
        .{ "avx2", avx2_target },
    };

    const exe = b.addExecutable(.{
        .name = "poc",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.resolveTargetQuery(baseline_target),
        .optimize = optimize,
    });

    exe.linkLibC();

    // Libs
    const setup_step = b.step("setup", "");
    inline for (targets) |target| {
        const lib = b.addSharedLibrary(.{
            .name = target[0],
            .root_source_file = .{ .path = "src/lib.zig" },
            .target = b.resolveTargetQuery(target[1]),
            .optimize = optimize,
        });
        setup_step.dependOn(&lib.step);
        exe.root_module.addAnonymousImport(b.fmt("{s}_path", .{target[0]}), .{
            .root_source_file = lib.getEmittedBin(),
        });
    }

    exe.step.dependOn(setup_step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
