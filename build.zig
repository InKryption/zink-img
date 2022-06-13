const std = @import("std");

const this_dir: [:0]const u8 = struct {
    fn thisDir() [:0]const u8 {
        const dirname = comptime std.fs.path.dirname(@src().file).?;
        std.debug.assert(std.fs.path.isAbsolute(dirname));
        return dirname ++ "";
    }
}.thisDir();

pub fn getPackage(b: *std.build.Builder, name: []const u8) std.build.Pkg {
    return b.dupePkg(std.build.Pkg{
        .name = name,
        .source = std.build.FileSource{ .path = b.pathJoin(&.{ this_dir, "src/main.zig" }) },
    });
}

pub fn build(b: *std.build.Builder) void {
    std.debug.assert(blk: {
        const cd_this_dir = std.fs.realpathAlloc(b.allocator, this_dir) catch unreachable;
        defer b.allocator.free(cd_this_dir);

        const cd_build_root = std.fs.realpathAlloc(b.allocator, b.build_root) catch unreachable;
        defer b.allocator.free(cd_build_root);

        break :blk std.mem.eql(u8, cd_this_dir, cd_build_root);
    });
    const mode = b.standardReleaseOptions();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
