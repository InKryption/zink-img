const std = @import("std");

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
pub fn readAllExtra(reader: anytype, buf: []u8) ReadAllExtraResult(@TypeOf(reader).Error) {
    const Result = ReadAllExtraResult(@TypeOf(reader).Error);
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

        pub const Fail = ReadAllExtraResult(ErrorSet).Fail;
    };
}
pub fn readNoEofExtra(reader: anytype, buf: []u8) ReadNoEofExtraResult(@TypeOf(reader).Error) {
    const Result = ReadNoEofExtraResult(@TypeOf(reader).Error);
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
            return Result{ .fail = fail };
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
            bytes: Bytes,
            err: ErrorSet,
            pub const Bytes = std.BoundedArray(u8, @maximum(byte_count, 1) - 1);
        };

        pub fn unwrap(self: @This()) ErrorSet!std.BoundedArray(u8, byte_count) {
            return switch (self) {
                .ok => |value| value,
                .fail => |fail| fail.err,
            };
        }
    };
}
pub fn readBoundedArrayExtra(reader: anytype, comptime byte_count: usize) ReadBoundedArrayExtraResult(@TypeOf(reader).Error, byte_count) {
    const Result = ReadBoundedArrayExtraResult(@TypeOf(reader).Error, byte_count);
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
                .bytes = Result.Fail.Bytes.fromSlice(bounded.constSlice()) catch unreachable,
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
pub fn writeAllExtra(writer: anytype, bytes: []const u8) WriteAllExtraResult(@TypeOf(writer).Error) {
    const Result = WriteAllExtraResult(@TypeOf(writer).Error);
    var index: usize = 0;
    while (index != bytes.len) {
        index += writer.write(bytes[index..]) catch |err| return Result{ .fail = Result.Fail{
            .err = err,
            .bytes_written = index,
        } };
    }
    return .ok;
}

pub fn ReadIntoWriterWithBufferEagerlyResult(
    comptime WriteError: type,
    comptime ReadError: type,
) type {
    return union(enum) {
        /// Read the full number of requested bytes successfully,
        /// and wrote all those bytes successfully.
        ok,
        /// Encountered an error trying to write the successfully read bytes.
        write_fail: WriteFail,
        /// Encountered end of stream before reading the specified number
        /// of bytes, but managed to successfully write those which were acquired.
        read_partial: ReadPartial,
        /// Encountered end of stream before reading the specified number
        /// of bytes, and then failed to fully write those which were acquired.
        read_partial_write_fail: ReadPartialWriteFail,
        /// Encountered error before reading the specified number of bytes,
        /// but managed to successfully write this which were acquired.
        read_fail: ReadFail,
        /// Encountered error before reading the specified number of bytes,
        /// and then failed to fully wrote those which were acquired.
        read_fail_write_fail: ReadFailWriteFail,

        pub const WriteFail = struct {
            bytes_read: usize,
            bytes_written: usize,
            write_err: WriteError,
        };
        pub const ReadPartial = struct {
            bytes_read: usize,
        };
        pub const ReadPartialWriteFail = struct {
            bytes_read: usize,
            bytes_written: usize,
            write_err: WriteError,
        };
        pub const ReadFail = struct {
            bytes_read: usize,
            read_err: ReadError,
        };
        pub const ReadFailWriteFail = struct {
            bytes_read: usize,
            bytes_written: usize,
            read_err: ReadError,
            write_err: WriteError,
        };
    };
}
pub fn readIntoWriterEagerlyWithBuffer(
    writer: anytype,
    reader: anytype,
    byte_count: usize,
    intermediate_buffer: []u8,
) ReadIntoWriterWithBufferEagerlyResult(
    @TypeOf(writer).Error,
    @TypeOf(reader).Error,
) {
    std.debug.assert(intermediate_buffer.len > 0 or byte_count == 0);
    const Result = ReadIntoWriterWithBufferEagerlyResult(
        @TypeOf(writer).Error,
        @TypeOf(reader).Error,
    );

    var count: usize = 0;
    while (count < byte_count) {
        const amt = std.math.min(byte_count - count, intermediate_buffer.len);
        switch (readNoEofExtra(reader, intermediate_buffer[0..amt])) {
            .ok => switch (writeAllExtra(writer, intermediate_buffer[0..amt])) {
                .ok => count += amt,
                .fail => |write_fail| {
                    std.debug.assert(write_fail.bytes_written < amt);
                    return Result{ .write_fail = Result.WriteFail{
                        .bytes_read = count + amt,
                        .bytes_written = count + write_fail.bytes_written,
                        .write_err = write_fail.err,
                    } };
                },
            },
            .partial => |bytes_read| {
                std.debug.assert(bytes_read < amt);
                return switch (writeAllExtra(writer, intermediate_buffer[0..bytes_read])) {
                    .ok => Result{ .read_partial = Result.ReadPartial{
                        .bytes_read = count + bytes_read,
                    } },
                    .fail => |write_fail| Result{ .read_partial_write_fail = Result.ReadPartialWriteFail{
                        .bytes_read = count + bytes_read,
                        .bytes_written = count + write_fail.bytes_written,
                        .write_err = write_fail.err,
                    } },
                };
            },
            .fail => |read_fail| {
                std.debug.assert(read_fail.bytes_read < amt);
                return switch (writeAllExtra(writer, intermediate_buffer[0..read_fail.bytes_read])) {
                    .ok => Result{ .read_fail = Result.ReadFail{
                        .bytes_read = count + read_fail.bytes_read,
                        .read_err = read_fail.err,
                    } },
                    .fail => |write_fail| Result{ .read_fail_write_fail = Result.ReadFailWriteFail{
                        .bytes_read = count + read_fail.bytes_read,
                        .bytes_written = count + write_fail.bytes_written,
                        .read_err = read_fail.err,
                        .write_err = write_fail.err,
                    } },
                };
            },
        }
    }

    return .ok;
}
