const std = @import("std");
const assert = std.debug.assert;

const build_options = @import("options");

var baseline_so align(std.mem.page_size) = @embedFile("baseline_path").*;
var avx2_so align(std.mem.page_size) = @embedFile("avx2_path").*;

const proto = *const fn ([*]const u8, [*]const u8, usize) callconv(.C) bool;

var func_ptr: proto = undefined;

const allocator = std.heap.c_allocator;

pub fn main() !void {
    const temp_fd = try memfd_create("/dev/shm/ghostty");

    const args = try std.process.argsAlloc(allocator);

    if (std.mem.eql(u8, args[1], "1")) {
        std.debug.print("Using Baseline\n", .{});
        _ = try std.os.write(temp_fd, &baseline_so);
    } else {
        std.debug.print("Using AVX2\n", .{});
        _ = try std.os.write(temp_fd, &avx2_so);
    }

    var handle = try openFD(temp_fd);
    const function = handle.lookup(proto, "eqlBytes");

    if (function) |func| {
        std.debug.print("Switching function\n", .{});

        func_ptr = func;
    } else {
        @panic("couldnt find symbol");
    }

    const ty = u8;
    const max_bytes = 10000;
    const iterations_per_byte = 1000;
    const warmup_iterations = 10;

    const stdout = std.io.getStdOut();

    for (1..max_bytes) |index| {
        const buffer_a = try allocator.alloc(ty, index);
        @memset(buffer_a, 0);

        buffer_a[index / 2] = 1;

        const buffer_b = try allocator.alloc(ty, index);
        @memset(buffer_b, 0);

        var cycles: u64 = 0;

        var i: u32 = 0;
        while (i < iterations_per_byte + warmup_iterations) : (i += 1) {
            const new_start = rdtsc();
            std.mem.doNotOptimizeAway(func_ptr(buffer_a.ptr, buffer_b.ptr, buffer_a.len));
            const new_end = rdtsc();
            if (i > warmup_iterations) cycles += (new_end - new_start);
        }

        const cycles_per_byte = cycles / iterations_per_byte;

        try stdout.writer().print("{},{d}\n", .{
            index,
            cycles_per_byte,
        });
    }
}

fn memfd_create(name: []const u8) !std.os.fd_t {
    const shm_fd = try std.os.memfd_create(name, 1);
    if (shm_fd < 0) {
        // Something wrong :(
        @panic("Couldn't open file desc");
    }
    return shm_fd;
}

const builtin = @import("builtin");
const x86_64 = @import("x86_64.zig");

/// Raw comptime entry of poissible ISA. The arch is the arch that the
/// ISA is even possible on (e.g. neon is only possible on aarch64) but
/// the actual ISA may not be available at runtime.
const Entry = struct {
    name: [:0]const u8,
    arch: []const std.Target.Cpu.Arch = &.{},
};

const entries: []const Entry = &.{
    .{ .name = "scalar" },
    .{ .name = "neon", .arch = &.{.aarch64} },
    .{ .name = "avx2", .arch = &.{ .x86, .x86_64 } },
};

/// Enum of possible ISAs for our SIMD operations. Note that these are
/// coarse-grained because they match possible implementations rather than
/// a fine-grained packed struct of available CPU features.
pub const ISA = isa: {
    const EnumField = std.builtin.Type.EnumField;
    var fields: [entries.len]EnumField = undefined;
    for (entries, 0..) |entry, i| {
        fields[i] = .{ .name = entry.name, .value = i };
    }

    break :isa @Type(.{ .Enum = .{
        .tag_type = std.math.IntFittingRange(0, entries.len - 1),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

/// A set of ISAs.
pub const Set = std.EnumSet(ISA);

/// Check if the given ISA is possible on the current target. This is
/// available at comptime to help prevent invalid architectures from
/// being used.
pub fn possible(comptime isa: ISA) bool {
    inline for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, @tagName(isa))) {
            for (entry.arch) |arch| {
                if (arch == builtin.cpu.arch) return true;
            }

            // If we have no valid archs then its always valid.
            return entry.arch.len == 0;
        }
    }

    unreachable;
}

/// Detect all possible ISAs at runtime.
pub fn detect() Set {
    var set: Set = .{};
    set.insert(.scalar);
    switch (builtin.cpu.arch) {
        // Neon is mandatory on aarch64. No runtime checks necessary.
        .aarch64 => set.insert(.neon),
        .x86_64 => detectX86(&set),
        else => {},
    }

    return set;
}

/// Returns the preferred ISA to use that is available.
pub fn preferred(set: Set) ISA {
    const order: []const ISA = &.{ .avx2, .neon, .scalar };

    // We should have all of our ISAs present in order
    comptime {
        for (@typeInfo(ISA).Enum.fields) |field| {
            const v = @field(ISA, field.name);
            assert(std.mem.indexOfScalar(ISA, order, v) != null);
        }
    }

    inline for (order) |isa| {
        if (comptime possible(isa)) {
            if (set.contains(isa)) return isa;
        }
    }

    return .scalar;
}

fn detectX86(set: *Set) void {
    // NOTE: this is just some boilerplate to detect AVX2. We
    // can probably support earlier forms of SIMD such as plain
    // SSE, and we can definitely take advtange of later forms. This
    // is just some boilerplate to ONLY detect AVX2 right now.

    // If we support less than 7 for the maximum leaf level then we
    // don't support any AVX instructions.
    var leaf = x86_64.cpuid(0, 0);
    if (leaf.eax < 7) return;

    // If we don't have xsave or avx, then we don't support anything.
    leaf = x86_64.cpuid(1, 0);
    const has_xsave = hasBit(leaf.ecx, 27);
    const has_avx = hasBit(leaf.ecx, 28);
    if (!has_xsave or !has_avx) return;

    // We require AVX save state in order to use AVX instructions.
    const xcr0_eax = x86_64.getXCR0(); // requires xsave+avx
    const has_avx_save = hasMask(xcr0_eax, x86_64.XCR0_XMM | x86_64.XCR0_YMM);
    if (!has_avx_save) return;

    // Check for AVX2.
    leaf = x86_64.cpuid(7, 0);
    const has_avx2 = hasBit(leaf.ebx, 5);
    if (has_avx2) set.insert(.avx2);
}

/// Check if a bit is set at the given offset
inline fn hasBit(input: u32, offset: u5) bool {
    return (input >> offset) & 1 != 0;
}

/// Checks if a mask exactly matches the input
inline fn hasMask(input: u32, mask: u32) bool {
    return (input & mask) == mask;
}

/// This is a helper to provide a runtime lookup map for the ISA to
/// the proper function implementation. Func is the function type,
/// and map is an array of tuples of the form (ISA, Struct) where
/// Struct has a decl named `name` that is a Func.
///
/// The slightly awkward parameters are to ensure that functions
/// are only analyzed for possible ISAs for the target.
///
/// This will ensure that impossible ISAs for the build target are
/// not included so they're not analyzed. For example, a NEON implementation
/// will not be included on x86_64.
pub fn funcMap(
    comptime Func: type,
    v: ISA,
    comptime map: anytype,
) *const Func {
    switch (v) {
        inline else => |tag| {
            // If this tag isn't possible, compile no code for this case.
            if (comptime !possible(tag)) unreachable;

            // Find the entry for this tag and return the function.
            inline for (map) |entry| {
                if (entry[0] == tag) {
                    // If we return &entry[1] directly the compiler crashes:
                    // https://github.com/ziglang/zig/issues/18754
                    const func = entry[1];
                    return &func;
                }
            } else unreachable;
        },
    }
}

/// X86 cycle counter
inline fn rdtsc() usize {
    var a: u32 = undefined;
    var b: u32 = undefined;
    asm volatile ("rdtsc"
        : [a] "={edx}" (a),
          [b] "={eax}" (b),
    );
    return (@as(u64, a) << 32) | b;
}

pub fn openFD(fd: std.os.fd_t) !std.DynLib {
    var path: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const fmt_path = try std.fmt.bufPrintZ(&path, "/proc/self/fd/{d}", .{fd});
    return std.DynLib{
        .handle = std.os.system.dlopen(fmt_path.ptr, std.os.system.RTLD.LAZY) orelse {
            return error.FileNotFound;
        },
    };
}
