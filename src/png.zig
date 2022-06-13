const std = @import("std");
const util = @import("util.zig");

pub const signature: [8]u8 = .{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub const ChunkType = enum(u32) {
    pub const Tag = @typeInfo(ChunkType).Enum.tag_type;
    // Standard Critical Chunk Types
    IHDR = std.mem.readIntBig(u32, "IHDR"),
    PLTE = std.mem.readIntBig(u32, "PLTE"),
    IDAT = std.mem.readIntBig(u32, "IDAT"),
    IEND = std.mem.readIntBig(u32, "IEND"),

    // Standard Ancillary Chunk Types
    bKGD = std.mem.readIntBig(u32, "bKGD"),
    cHRM = std.mem.readIntBig(u32, "cHRM"),
    gAMA = std.mem.readIntBig(u32, "gAMA"),
    hIST = std.mem.readIntBig(u32, "hIST"),
    pHYs = std.mem.readIntBig(u32, "pHYs"),
    sBIT = std.mem.readIntBig(u32, "sBIT"),
    tEXt = std.mem.readIntBig(u32, "tEXt"),
    tIME = std.mem.readIntBig(u32, "tIME"),
    tRNS = std.mem.readIntBig(u32, "tRNS"),
    zTXt = std.mem.readIntBig(u32, "zTXt"),

    // Non-Standard Chunk Types
    _,

    /// Reads bytes as a big endian integer.
    pub fn from(bytes: *const [4]u8) ChunkType {
        return @intToEnum(ChunkType, std.mem.readIntBig(u32, bytes));
    }

    pub fn str(self: ChunkType) [4]u8 {
        return std.mem.toBytes(self.int());
    }

    pub fn isValid(self: ChunkType) bool {
        for (self.str()) |byte| {
            if (!std.ascii.isAlpha(byte)) return false;
        }
        return true;
    }

    pub fn int(self: ChunkType) Tag {
        return @enumToInt(self);
    }
    pub fn intBig(self: ChunkType) Tag {
        return std.mem.nativeToBig(Tag, self.int());
    }
    pub fn intLittle(self: ChunkType) Tag {
        return std.mem.nativeToLittle(Tag, self.int());
    }

    pub fn property(self: ChunkType, byte_index: u2) bool {
        return (self.str()[byte_index] & 32) != 0;
    }
};

pub const ChunkHeader = struct {
    length: u31,
    type: ChunkType,

    pub fn parseBuffer(bytes: *const [8]u8) error{InvalidLength}!ChunkHeader {
        return ChunkHeader{
            .length = std.math.cast(u31, std.mem.readIntBig(u32, bytes[0..4])) orelse return error.InvalidLength,
            .type = ChunkType.from(bytes[4..]),
        };
    }

    pub fn parseVarBuffer(buffer: []const u8) error{ NoLength, InvalidLength, NoType }!ChunkHeader {
        var fbs = std.io.fixedBufferStream(buffer);
        return switch (ChunkHeader.parseReader(fbs.reader())) {
            .ok => |value| value,
            .no_type_err => unreachable,
            .no_type_eos => error.NoType,
            .invalid_length => error.InvalidLength,
            .no_length_err => unreachable,
            .no_length_eos => error.NoLength,
        };
    }

    const ParseReaderResultTag = enum {
        /// success
        ok,
        /// encountered error while trying to read type
        no_type_err,
        /// encountered end of stream while trying to read type
        no_type_eos,
        /// the bytes read formed an invalid length value
        invalid_length,
        /// encountered error while trying to read length
        no_length_err,
        /// encountered end of stream while trying to read length
        no_length_eos,
    };
    pub fn ParseReaderResult(comptime ReaderError: type) type {
        return union(ParseReaderResultTag) {
            const Self = @This();
            ok: ChunkHeader,
            no_type_err: NoTypeErr,
            no_type_eos: NoTypeEos,
            invalid_length: InvalidLength,
            no_length_err: NoLengthErr,
            no_length_eos: NoLengthEos,

            pub const ReadError = ReaderError;
            pub const NoTypeErr = struct { length: u31, err: ReadError };
            pub const NoTypeEos = struct { length: u31 };
            pub const InvalidLength = struct { invalid_value: u32 };
            pub const NoLengthErr = struct { err: ReadError };
            pub const NoLengthEos = void;
        };
    }
    /// Returns null if the stream ends before returning the required number of bytes for a chunk header.
    pub fn parseReader(reader: anytype) ParseReaderResult(@TypeOf(reader).Error) {
        const Result = ParseReaderResult(@TypeOf(reader).Error);

        const length: u31 = length: {
            const length_bytes: [4]u8 = switch (util.readBoundedArrayExtra(reader, 4)) {
                .ok => |bytes| blk: {
                    if (bytes.len < 4) return .no_length_eos;
                    break :blk bytes.slice()[0..4].*;
                },
                .fail => |fail| return Result{ .no_length_err = Result.NoLengthErr{ .err = fail.err } },
            };

            const naive_value = std.mem.readIntBig(u32, &length_bytes);
            if (std.math.cast(u31, naive_value)) |casted| break :length casted;
            return Result{ .invalid_length = Result.InvalidLength{ .value = naive_value } };
        };

        const @"type": ChunkType = @"type": {
            const type_bytes: [4]u8 = switch (util.readBoundedArrayExtra(reader, 4)) {
                .ok => |bytes| blk: {
                    if (bytes.len < 4) {
                        return Result{ .no_type_eos = Result.NoTypeEos{ .length = length } };
                    }
                    break :blk bytes.slice()[0..4].*;
                },
                .fail => |fail| return Result{ .no_type_err = Result.NoTypeErr{
                    .length = length,
                    .err = fail.err,
                } },
            };

            break :@"type" ChunkType.from(&type_bytes);
        };

        return Result{ .ok = ChunkHeader{
            .length = length,
            .type = @"type",
        } };
    }
};

pub const ChunkMetadata = struct {
    header: ChunkHeader,
    crc: u32,
};

pub fn ChunkRawDataStream(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        reader: ReaderType,
        state: State,

        const State = enum { begin, in_progress, end };

        pub fn init(reader: ReaderType) Self {
            return Self{ .reader = reader, .state = .begin };
        }

        pub const StartResult = union(enum) {
            /// Acquired all `signature.len` bytes successfully, and all compared equal
            /// to the bytes in `signature`.
            ok,
            /// Stream supplied bytes which did not match the PNG signature.
            /// The invalid bytes are attached.
            invalid_signature: [signature.len]u8,
            /// Stream ended before supplying enough bytes for the PNG signature.
            /// The read bytes are attached.
            early_eos: std.BoundedArray(u8, signature.len),
            /// The reader issued an error whilst supplying the bytes for the PNG signature.
            /// The bytes read up until the point the error was issued are attached, alongside
            /// the aforementioned error.
            read_fail: ReadErr,

            pub const ReadErr = struct {
                err: ReaderType.Error,
                bytes: std.BoundedArray(u8, signature.len),
            };

            pub const BadSignatureError = error{ EarlyEndOfStream, InvalidPngSignature };
            pub fn unwrap(result: StartResult) (BadSignatureError || ReaderType.Error)!void {
                return switch (result) {
                    .ok => {},
                    .invalid_signature => error.InvalidPngSignature,
                    .early_eos => error.EarlyEndOfStream,
                    .read_fail => |fail| fail.err,
                };
            }
        };
        pub fn start(self: *Self) StartResult {
            switch (self.state) {
                .begin => {},
                .in_progress => unreachable,
                .end => unreachable,
            }

            self.state = .end;

            var actual_bytes_buf: [signature.len]u8 = undefined;
            switch (util.readAllExtra(self.reader, &actual_bytes_buf)) {
                .fail => |fail| return StartResult{ .read_fail = StartResult.ReadErr{
                    .err = fail.err,
                    .bytes = std.BoundedArray(u8, signature.len).fromSlice(actual_bytes_buf[0..fail.bytes_read]),
                } },
                .ok => |bytes_read| {
                    const actual_bytes = actual_bytes_buf[0..bytes_read];
                    if (actual_bytes.len < signature.len) {
                        return StartResult{ .early_eos = std.BoundedArray(u8, signature.len).fromSlice(actual_bytes) catch unreachable };
                    }
                    if (!std.mem.eql(u8, actual_bytes, &signature)) {
                        return StartResult{ .invalid_signature = actual_bytes[0..signature.len].* };
                    }
                },
            }

            self.state = .in_progress;
            return .ok;
        }

        pub fn NextWithBufferResult(comptime WriteError: type) type {
            return union(enum) {
                ok: ChunkMetadata,

                // Forwarded Chunk Parsing Errors.
                no_type_eos: ChunkHeader.ParseReaderResult(ReaderType.Error).NoTypeEos,
                no_type_err: ChunkHeader.ParseReaderResult(ReaderType.Error).NoTypeErr,
                no_length_err: ChunkHeader.ParseReaderResult(ReaderType.Error).NoLengthErr,

                invalid_length: InvalidLength,
                /// Returned only if the supplied intermediate buffer is empty (.len == 0),
                /// and the incoming data is non-empty.
                empty_intermediate_buffer: EmptyIntermediateBuffer,

                data_write_err: DataWriteErr,
                data_read_partial: DataReadPartial,
                data_read_partial_write_err: DataReadPartialWriteErr,
                data_read_err: DataReadErr,
                data_read_err_write_err: DataReadErrWriteErr,

                no_crc_eos: NoCrcEos,
                no_crc_err: NoCrcErr,

                pub const InvalidLength = struct { header: ChunkHeader };
                pub const EmptyIntermediateBuffer = struct { header: ChunkHeader };
                pub const DataWriteErr = struct {
                    header: ChunkHeader,
                    bytes_written: u31,
                    write_err: WriteError,
                };
                pub const DataReadPartial = struct {
                    header: ChunkHeader,
                    bytes_read: u31,
                };
                pub const DataReadPartialWriteErr = struct {
                    header: ChunkHeader,
                    bytes_read: u31,
                    bytes_written: u31,
                    write_err: WriteError,
                };
                pub const DataReadErr = struct {
                    header: ChunkHeader,
                    bytes_read: u31,
                    read_err: ReaderType.Error,
                };
                pub const DataReadErrWriteErr = struct {
                    header: ChunkHeader,
                    bytes_read: u31,
                    bytes_written: u31,
                    read_err: ReaderType.Error,
                    write_err: WriteError,
                };
                pub const NoCrcEos = struct {
                    header: ChunkHeader,
                    bytes_read: u2,
                };
                pub const NoCrcErr = struct {
                    header: ChunkHeader,
                    bytes_read: u2,
                    read_err: ReaderType.Error,
                };
            };
        }
        pub fn nextWithBuffer(
            self: *Self,
            writer: anytype,
            intermediate_buffer: []u8,
        ) ?NextWithBufferResult(util.MemoizeErrorSet(@TypeOf(writer).Error)) {
            const Result = NextWithBufferResult(util.MemoizeErrorSet(@TypeOf(writer).Error));

            switch (self.state) {
                .begin => unreachable,
                .in_progress => {},
                .end => return null,
            }

            self.state = .end;

            const header: ChunkHeader = switch (ChunkHeader.parseReader(self.reader)) {
                .ok => |header| header,
                .no_type_eos => |info| return Result{ .no_type_eos = info },
                .no_type_err => |info| return Result{ .no_type_err = info },
                .no_length_eos => return null,
                .no_length_err => |info| return Result{ .no_length_err = info },
            };

            if (header.length > std.math.maxInt(u31)) {
                return Result{ .invalid_length = Result.InvalidLength{ .header = header } };
            }
            if (header.length != 0 and intermediate_buffer.len == 0) {
                return Result{ .empty_intermediate_buffer = .{ .header = header } };
            }

            {
                var remaining: u31 = @intCast(u31, header.length);
                while (remaining > 0) {
                    const amt = std.math.min(remaining, intermediate_buffer.len);
                    switch (util.readNoEofExtra(self.reader, intermediate_buffer[0..amt])) {
                        .ok => {
                            remaining -= amt;
                            switch (util.writeAllExtra(writer, intermediate_buffer[0..amt])) {
                                .ok => {},
                                .fail => |write_fail| return Result{ .data_write_err = Result.DataWriteErr{
                                    .header = header,
                                    .bytes_written = (header.length - remaining) + write_fail.bytes_written,
                                    .err = write_fail.err,
                                } },
                            }
                        },
                        .partial => |bytes_read| {
                            remaining -= @intCast(u31, bytes_read);
                            return switch (util.writeAllExtra(writer, intermediate_buffer[0..bytes_read])) {
                                .ok => Result{ .data_read_partial = Result.DataReadPartial{
                                    .header = header,
                                    .bytes_read = header.length - remaining,
                                } },
                                .fail => |write_fail| Result{ .data_read_partial_write_err = Result.DataReadPartialWriteErr{
                                    .header = header,
                                    .bytes_read = header.length - remaining,
                                    .bytes_written = (header.length - remaining) + write_fail.bytes_written,
                                    .write_err = write_fail.err,
                                } },
                            };
                        },
                        .fail => |read_fail| {
                            remaining -= @intCast(u31, read_fail.bytes_read);
                            return switch (util.writeAllExtra(writer, intermediate_buffer[0..read_fail.bytes_read])) {
                                .ok => Result{ .data_read_err = Result.DataReadErr{
                                    .header = header,
                                    .bytes_read = header.length - remaining,
                                    .err = read_fail.err,
                                } },
                                .fail => |write_fail| Result{ .data_read_err_write_err = Result.DataReadErrWriteErr{
                                    .header = header,
                                    .bytes_read = header.length - remaining,
                                    .bytes_written = (header.length - remaining) + write_fail.bytes_written,
                                    .read_err = read_fail.err,
                                    .write_err = write_fail.err,
                                } },
                            };
                        },
                    }
                }
            }

            const crc: u32 = crc: {
                const crc_bytes: [4]u8 = switch (util.readBoundedArrayExtra(self.reader, 4)) {
                    .ok => |bytes| if (bytes.len < 4) {
                        return Result{ .no_crc_eos = Result.NoCrcEos{
                            .header = header,
                            .bytes_read = @intCast(u2, bytes.len),
                        } };
                    } else bytes.constSlice()[0..4].*,
                    .fail => |fail| return Result{ .no_crc_err = Result.NoCrcErr{
                        .header = header,
                        .bytes_read = @intCast(u2, fail.bytes.len),
                        .err = fail.err,
                    } },
                };
                break :crc std.mem.readIntBig(u32, &crc_bytes);
            };

            self.state = .in_progress;
            return Result{ .ok = ChunkMetadata{
                .header = header,
                .crc = crc,
            } };
        }
    };
}
