const std = @import("std");
pub fn writeAllExtra(
    writer: anytype,
    bytes: []const u8,
    /// Assumed to be initialised. Recommended value of 0.
    /// Will have the number of bytes which are ultimately written to the stream
    /// added to it.
    p_count: *usize,
) @TypeOf(writer).Error!void {
    var index: usize = 0;
    defer p_count.* += index;

    while (index != bytes.len) {
        const amt = try writer.write(bytes[index..]);
        std.debug.assert(0 < amt and index + amt <= bytes.len);
        index += amt;
    }
}

pub fn readAllExtra(
    reader: anytype,
    buffer: []u8,
    /// Assumed to be initialised. Recommended value of 0.
    /// Will have the number of bytes which are ultimately read into the buffer
    /// added to it.
    p_count: *usize,
) @TypeOf(reader).Error!void {
    var index: usize = 0;
    defer p_count.* += index;

    while (index != buffer.len) {
        const amt = try reader.read(buffer[index..]);

        if (amt == 0) break;
        index += amt;

        std.debug.assert(index <= buffer.len);
    }
}

/// Asserts `byte_count <= p_bounded_array.capacity()`.
pub fn readBoundedArray(
    reader: anytype,
    /// Must be `*std.BoundedArray(u8, n)`, for any `n`.
    p_bounded_array: anytype,
    /// Number of bytes to read into the bounded array.
    byte_count: usize,
) (@TypeOf(reader).Error!void) {
    comptime {
        const lazy = struct {
            const compile_err = @compileError("Expected a `*std.BoundedArray(u8, n)`, for any `n`, but instead found `" ++ @typeName(@TypeOf(p_bounded_array)) ++ "`.");
        };
        switch (@typeInfo(@TypeOf(p_bounded_array))) {
            .Pointer => |info| switch (info.size) {
                .One => {
                    const buffer_field_index = std.meta.fieldIndex(info.child, .buffer) orelse lazy.compile_err;
                    const capacity = @typeInfo(@typeInfo(info.child).Struct.fields[buffer_field_index].field_type).Array.len;
                    if (info.child != std.BoundedArray(u8, capacity)) lazy.compile_err;
                },
                else => lazy.compile_err,
            },
            else => lazy.compile_err,
        }
    }

    std.debug.assert(byte_count <= p_bounded_array.capacity());
    p_bounded_array.resize(byte_count) catch unreachable;
    try reader.readAll(p_bounded_array.slice());
}

pub const ReadIntoWriterWithBufferOutParam = struct {
    /// Assumed to be initialised. Recommended value of 0.
    /// Will have the number of bytes which are ultimately read from the reader stream
    /// added to it.
    p_count_read: *usize,
    /// Assumed to be initialised. Recommended value of 0.
    /// Will have the number of bytes which are ultimately written to the writer stream
    /// added to it.
    p_count_written: *usize,
};
pub fn readIntoWriterWithBuffer(
    writer: std.io.Writer(),
    reader: std.io.Reader(),
    buffer: []u8,
    byte_count: usize,
    out: ReadIntoWriterWithBufferOutParam,
) @TypeOf(reader).Error!(@TypeOf(writer).Error!void) {
    var index: usize = 0;

    var index_read: usize = 0;
    defer out.p_count_read.* += index_read;

    var index_written: usize = 0;
    defer out.p_count_written.* += index_written;

    while (index != byte_count) {
        const read_amt = std.math.min(buffer.len, byte_count - index);
        const read_start = index_read;

        try readAllExtra(reader, buffer[0..read_amt], &index_read);

        const write_amt = index_read - read_start;
        const write_start = index_written;

        try writeAllExtra(writer, buffer[0..write_amt], &index_written);
        std.debug.assert((index_written - write_start) == write_amt);

        if (write_amt == 0) return;
    }
}

pub fn delimitedReader(reader: anytype, max_bytes: u64) DelimitedReader(@TypeOf(reader)) {
    return .{
        .inner_reader = reader,
        .bytes_left = max_bytes,
    };
}
/// Returns 'error.EndOfStream' after having read out 'max_bytes' bytes.
pub fn DelimitedReader(comptime InnerReader: type) type {
    return struct {
        const Self = @This();
        inner_reader: InnerReader,
        bytes_left: u64,

        pub const Reader = std.io.Reader(*Self, Error || InnerReader.Error, Self.read);
        pub const Error = error{EndOfStream};

        pub fn read(self: *Self, buffer: []u8) (Error || InnerReader.Error)!usize {
            if (self.bytes_left == 0) return Error.EndOfStream;
            const max_read = std.math.min(self.bytes_left, buffer.len);
            const amt = try self.inner_reader.read(buffer[0..max_read]);
            self.bytes_left -= amt;
            return amt;
        }
        pub fn reader(self: *Self) Reader {
            return Reader{ .context = self };
        }
    };
}

/// Ugly work around for the fact that you can't coerce to `A!B!T` from `B` or `B!T` in-place (using `@as`),
/// e.g. `@as(A!B!T, @as(B!T, B.B))` fails to compile, but succeeds if the coercion to `B!T` is moved out into a separate identifier,
/// and then coerced to `A!B!T`.
pub inline fn as(comptime T: type, value: T) T {
    return value;
}
