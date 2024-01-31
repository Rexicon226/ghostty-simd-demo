const std = @import("std");
const assert = std.debug.assert;

// The two .so files we generated earlier.
var baseline_so = @embedFile("baseline_path");
var avx2_so = @embedFile("avx2_path");

const proto = *const fn () callconv(.C) void;

var func_ptr: proto = undefined;

const allocator = std.heap.c_allocator;

pub fn main() !void {
    // File path doesn't matter here, just need a virtual fd.
    const fd = try memfd_create("");

    const args = try std.process.argsAlloc(allocator);

    // This is the main point of this POC.
    // we can at runtime dynamically load the library we want.
    // it's lazy so no "invalid instruction" stuff happens.
    _ = try std.os.write(fd, blk: {
        if (std.mem.eql(u8, args[1], "1")) {
            break :blk baseline_so;
        } else {
            break :blk avx2_so;
        }
    });

    // Here we parse the loaded library and look up the symbol we want to use.
    // this process can be easily automated with inline for loop and a struct.
    var handle = try openFD(fd);
    const function = handle.lookup(proto, "hello");

    // This layer of indirection allows Zig to just basically "trust me bro" and assumes that it
    // will be filled in later. The assembly is reduced to just a single mov and call which is really neat.
    func_ptr = function orelse @panic("couldnt find symbol");

    // Call it.
    func_ptr();
}

fn memfd_create(name: []const u8) !std.os.fd_t {
    const shm_fd = try std.os.memfd_create(name, 1);
    if (shm_fd < 0) {
        // Something wrong :(
        @panic("Couldn't open file desc");
    }
    return shm_fd;
}

// TODO: Need to find some way of making this work on macos as well.
// I don't have mac so i'll leave that to mitchell lol.
pub fn openFD(fd: std.os.fd_t) !std.DynLib {
    var path: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const fmt_path = try std.fmt.bufPrintZ(&path, "/proc/self/fd/{d}", .{fd});
    return std.DynLib{
        .handle = std.os.system.dlopen(fmt_path.ptr, std.os.system.RTLD.LAZY) orelse {
            return error.FileNotFound;
        },
    };
}
