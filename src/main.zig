const std = @import("std");
pub const png = @import("png.zig");

comptime {
    _ = png;
}

const HalfUsize = std.meta.Int(
    .unsigned,
    @divExact(@typeInfo(usize).Int.bits, 2),
);
const FullUsize = std.meta.Int(
    .unsigned,
    @typeInfo(HalfUsize).Int.bits * 2,
);
fn mulHalfUsize(a: HalfUsize, b: HalfUsize) FullUsize {
    return std.math.mulWide(HalfUsize, a, b);
}

pub const Image = struct {
    /// Prefer calling the `bytes` method, as opposed to accessing this field directly.
    p_bytes: [*]u8,
    width: HalfUsize,
    height: HalfUsize,
    channels: u2,

    pub fn initBuffer(buffer: []u8, width: HalfUsize, height: HalfUsize, channels: u2) Image {
        const result = Image{
            .p_bytes = buffer.ptr,
            .width = width,
            .height = height,
            .channels = channels,
        };
        std.debug.assert(result.len() <= buffer.len);
        return result;
    }

    /// Caller owns memory; should call `Image.free` on the return value.
    pub fn dupe(image: Image, allocator: std.mem.Allocator) std.mem.Allocator.Error!Image {
        const duped_bytes = try allocator.dupe(u8, image.bytes());
        errdefer allocator.free(duped_bytes);

        return Image{
            .p_bytes = duped_bytes.ptr,
            .width = image.width,
            .height = image.height,
            .channels = image.channels,
        };
    }

    pub fn free(image: Image, allocator: std.mem.Allocator) void {
        allocator.free(image.bytes());
    }

    pub fn len(image: Image) FullUsize {
        return mulHalfUsize(image.width, image.height);
    }

    pub fn bytes(image: Image) []u8 {
        return image.p_bytes[0..image.len()];
    }

    pub fn scanline(image: Image, y: HalfUsize) []u8 {
        const start_index = xyToScalar(0, y, .{ .w = image.width });
        return image.bytes()[start_index..][0..image.width];
    }

    fn xyToScalar(
        x: HalfUsize,
        y: HalfUsize,
        img: struct {
            w: HalfUsize,
            h: HalfUsize = std.math.maxInt(HalfUsize),
        },
    ) FullUsize {
        std.debug.assert( // Simple Sanity Check
            (x < img.w or (x == img.w and y < img.h)) and
            (y < img.h or (y == img.h and x < img.w)));
        return @as(FullUsize, x) + mulHalfUsize(img.w, y);
    }
};

pub fn loadPngBuffered(
    allocator: std.mem.Allocator,
    reader: anytype,
    intermediate_buf: []u8,
) !Image {
    _ = allocator;
    std.debug.assert(intermediate_buf.len > 0);

    var chunk_stream = png.chunkDataStream(reader);
    try chunk_stream.start().unwrap();

    const ihdr: png.ChunkIHDR = ihdr: {
        const header = try (chunk_stream.nextHeader() orelse return error.NoData).unwrap();
        if (header.type != .IHDR) {
            return error.MissingIHDRChunk;
        }

        var ihdr_buf: [@sizeOf(png.ChunkIHDR)]u8 = undefined;
        var ihdr_buf_stream = std.io.fixedBufferStream(&ihdr_buf);
        const crc = try chunk_stream.streamDataWithBuffer(ihdr_buf_stream.writer(), intermediate_buf).unwrap();

        var crc_hasher = std.hash.Crc32.init();
        crc_hasher.update(&std.mem.toBytes(header.type.intBig()));
        crc_hasher.update(&ihdr_buf);
        if (crc_hasher.final() != crc) {
            return error.CrcMismatch;
        }

        break :ihdr png.ChunkIHDR.parseBytes(&ihdr_buf);
    };
    _ = ihdr;

    while (chunk_stream.nextHeader()) |maybe_header| {
        const header = try maybe_header.unwrap();
        switch (header.type) {
            .IEND => {
                var empty_buf: [1]u8 = undefined;
                var empty_stream = std.io.fixedBufferStream(empty_buf[0..0]);
                const crc = chunk_stream.streamDataWithBuffer(empty_stream.writer(), &empty_buf);
                if (crc != std.hash.Crc32.hash(&std.mem.toBytes(header.type.intBig()))) {
                    return error.CrcMismatch;
                }
                break;
            },
        }
    }

    return std.debug.todo("");
}
