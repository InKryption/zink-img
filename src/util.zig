const std = @import("std");

pub const ErrorSetFromValue = @import("util/error_memoization.zig").ErrorSetFromValue;
pub const ErrorSetFromValues = @import("util/error_memoization.zig").ErrorSetFromValues;
pub const MemoizeErrorSet = @import("util/error_memoization.zig").MemoizeErrorSet;

const ReadAllExtraResultTag = enum { ok, fail };
pub fn ReadAllExtraResult(comptime ErrorSet: type) type {
    return union(ReadAllExtraResultTag) {
        ok: usize,
        fail: Fail,

        pub const Fail = struct {
            err: ErrorSet,
            /// always less than the length of the output buffer.
            bytes_read: usize,
        };

        pub fn unwrap(result: @This()) ErrorSet!usize {
            return switch (result) {
                .ok => |bytes_read| bytes_read,
                .fail => |fail| fail.err,
            };
        }
    };
}
pub fn readAllExtra(reader: anytype, buf: []u8) ReadAllExtraResult(MemoizeErrorSet(@TypeOf(reader).Error)) {
    const Result = ReadAllExtraResult(MemoizeErrorSet(@TypeOf(reader).Error));
    var index: usize = 0;
    while (index != buf.len) {
        const amt = reader.read(buf[index..]) catch |err| return Result{
            .fail = Result.Fail{ .err = err, .bytes_read = index },
        };
        if (amt == 0) break;
        index += amt;
    }
    return Result{ .ok = index };
}

const ReadNoEofExtraResultTag = enum { ok, partial, fail };
pub fn ReadNoEofExtraResult(comptime ErrorSet: type) type {
    return union(ReadNoEofExtraResultTag) {
        ok,
        partial: usize,
        fail: Fail,

        pub const Fail = ReadAllExtraResult(MemoizeErrorSet(ErrorSet)).Fail;
    };
}
pub fn readNoEofExtra(reader: anytype, buf: []u8) ReadNoEofExtraResult(MemoizeErrorSet(@TypeOf(reader).Error)) {
    const Result = ReadNoEofExtraResult(MemoizeErrorSet(@TypeOf(reader).Error));
    switch (readAllExtra(reader, buf)) {
        .ok => |bytes_read| {
            if (bytes_read < buf.len) {
                return Result{ .partial = bytes_read };
            }
            std.debug.assert(bytes_read == buf.len);
            return .ok;
        },
        .fail => |fail| {
            std.debug.assert(fail.bytes_read < buf.len);
            return Result{ .fail = Result.Fail{
                .err = fail.err,
            } };
        },
    }
    const amt_read = try reader.readAll(buf);
    if (amt_read < buf.len) return error.EndOfStream;
}

const ReadBoundedArrayExtraResultTag = enum { ok, fail };
pub fn ReadBoundedArrayExtraResult(comptime ErrorSet: type, comptime byte_count: usize) type {
    return union(ReadBoundedArrayExtraResultTag) {
        ok: std.BoundedArray(u8, byte_count),
        fail: Fail,

        pub const Fail = struct {
            bytes: std.BoundedArray(u8, @maximum(byte_count, 1) - 1),
            err: ErrorSet,
        };

        pub fn unwrap(self: @This()) ErrorSet!std.BoundedArray(u8, byte_count) {
            return switch (self) {
                .ok => |value| value,
                .fail => |fail| fail.err,
            };
        }
    };
}
pub fn readBoundedArrayExtra(reader: anytype, comptime byte_count: usize) ReadBoundedArrayExtraResult(MemoizeErrorSet(@TypeOf(reader).Error), byte_count) {
    const Result = ReadBoundedArrayExtraResult(MemoizeErrorSet(@TypeOf(reader).Error), byte_count);
    var bounded = std.BoundedArray(u8, byte_count).init(byte_count) catch unreachable;

    return switch (readAllExtra(reader, bounded.slice())) {
        .ok => |bytes_read| blk: {
            std.debug.assert(bytes_read <= byte_count);
            bounded.resize(bytes_read) catch unreachable;
            break :blk Result{ .ok = bounded };
        },
        .fail => |fail| blk: {
            std.debug.assert(fail.bytes_read < byte_count);
            bounded.resize(fail.bytes_read) catch unreachable;
            break :blk Result{ .fail = Result.Fail{
                .bytes = bounded,
                .err = fail.err,
            } };
        },
    };
}

const WriteAllExtraResultTag = enum { ok, fail };
pub fn WriteAllExtraResult(comptime ErrorSet: type) type {
    return union(WriteAllExtraResultTag) {
        ok,
        fail: Fail,

        pub const Fail = struct {
            err: ErrorSet,
            /// always less than the length of the input buffer.
            bytes_written: usize,
        };

        pub fn unwrap(result: @This()) ErrorSet!void {
            return switch (result) {
                .ok => {},
                .fail => |fail| fail.err,
            };
        }
    };
}
pub fn writeAllExtra(writer: anytype, bytes: []const u8) WriteAllExtraResult(MemoizeErrorSet(@TypeOf(writer).Error)) {
    const Result = WriteAllExtraResult(MemoizeErrorSet(@TypeOf(writer).Error));
    var index: usize = 0;
    while (index != bytes.len) {
        index += writer.write(bytes[index..]) catch |err| return Result{ .fail = Result.Fail{
            .err = err,
            .bytes_written = index,
        } };
    }
    return .ok;
}
