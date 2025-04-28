const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const AnyWriter = io.AnyWriter;
const c = @cImport({
    @cInclude("alsa/asoundlib.h");
});

// Helper function to check ALSA return codes and print errors
fn checkAlsa(ret: c_int, comptime func_name: []const u8) !void {
    if (ret < 0) {
        const err_str = c.snd_strerror(ret);
        std.debug.print("ALSA Error in {s}: {s} (code: {d})\n", .{ func_name, std.mem.sliceTo(err_str, 0), ret });
        return error.AlsaError;
    }
}

pub const Audio = struct {
    pcm_handle: ?*c.snd_pcm_t = null,
    hw_params: ?*c.snd_pcm_hw_params_t = null,
    buffer: []u8 = undefined,
    period_size_frames: c.snd_pcm_uframes_t = 0,
    bytes_per_frame: usize = 0,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) !Audio {
        // --- ALSA Variables ---
        var pcm_handle: ?*c.snd_pcm_t = null;
        var hw_params: ?*c.snd_pcm_hw_params_t = null;
        var buffer: []u8 = undefined;

        // --- Configuration ---
        const device_name = "default";
        const desired_rate: c_uint = 16000;
        const desired_channels: c_uint = 1; // Mono
        const desired_format = c.SND_PCM_FORMAT_S16_LE; // Signed 16-bit Little Endian
        const buffer_time_us: c_uint = 100000; // 100ms
        const period_time_us: c_uint = 25000; // 25ms

        var actual_rate = desired_rate;
        var actual_channels = desired_channels;
        var actual_format = desired_format;
        var actual_buffer_time = buffer_time_us;
        var actual_period_time = period_time_us;
        var dir: c_int = 0;

        var period_size_frames: c.snd_pcm_uframes_t = 0;
        var bits_per_sample: u16 = 0;
        var bytes_per_frame: usize = 0;
        var buffer_size_bytes: usize = 0;

        // --- Open and Configure ALSA Device ---
        std.debug.print("Attempting to open ALSA device: {s} for capture\n", .{device_name});
        try checkAlsa(c.snd_pcm_open(&pcm_handle, device_name.ptr, c.SND_PCM_STREAM_CAPTURE, 0), "snd_pcm_open");

        try checkAlsa(c.snd_pcm_hw_params_malloc(&hw_params), "snd_pcm_hw_params_malloc");

        try checkAlsa(c.snd_pcm_hw_params_any(pcm_handle.?, hw_params.?), "snd_pcm_hw_params_any");

        std.debug.print("Setting hardware parameters...\n", .{});
        try checkAlsa(c.snd_pcm_hw_params_set_access(pcm_handle.?, hw_params.?, c.SND_PCM_ACCESS_RW_INTERLEAVED), "snd_pcm_hw_params_set_access");
        try checkAlsa(c.snd_pcm_hw_params_set_format(pcm_handle.?, hw_params.?, desired_format), "snd_pcm_hw_params_set_format");
        try checkAlsa(c.snd_pcm_hw_params_get_format(hw_params.?, &actual_format), "snd_pcm_hw_params_get_format");
        if (actual_format != desired_format) {
            std.debug.print("Error: Unsupported format {s}\n", .{mem.sliceTo(c.snd_pcm_format_name(actual_format), 0)});
            return error.UnsupportedFormat;
        }
        bits_per_sample = @intCast(c.snd_pcm_format_width(actual_format));
        if (bits_per_sample == 0) {
            return error.InvalidFormatWidth;
        }

        actual_rate = desired_rate;
        try checkAlsa(c.snd_pcm_hw_params_set_rate_near(pcm_handle.?, hw_params.?, &actual_rate, &dir), "snd_pcm_hw_params_set_rate_near");

        try checkAlsa(c.snd_pcm_hw_params_set_channels(pcm_handle.?, hw_params.?, desired_channels), "snd_pcm_hw_params_set_channels");
        try checkAlsa(c.snd_pcm_hw_params_get_channels(hw_params.?, &actual_channels), "snd_pcm_hw_params_get_channels");
        if (actual_channels != desired_channels) {
            std.debug.print("Error: Unsupported channel count {d}\n", .{actual_channels});
            return error.UnsupportedChannels;
        }

        actual_buffer_time = buffer_time_us;
        try checkAlsa(c.snd_pcm_hw_params_set_buffer_time_near(pcm_handle.?, hw_params.?, &actual_buffer_time, &dir), "snd_pcm_hw_params_set_buffer_time_near");

        actual_period_time = period_time_us;
        try checkAlsa(c.snd_pcm_hw_params_set_period_time_near(pcm_handle.?, hw_params.?, &actual_period_time, &dir), "snd_pcm_hw_params_set_period_time_near");

        try checkAlsa(c.snd_pcm_hw_params(pcm_handle.?, hw_params.?), "snd_pcm_hw_params");
        std.debug.print("Hardware parameters applied:\n", .{});
        std.debug.print("- Format: {s} ({d} bits)\n", .{ mem.sliceTo(c.snd_pcm_format_name(actual_format), 0), bits_per_sample });
        std.debug.print("- Rate: {d} Hz\n", .{actual_rate});
        std.debug.print("- Channels: {d}\n", .{actual_channels});
        std.debug.print("- Buffer Time: {d} us\n", .{actual_buffer_time});
        std.debug.print("- Period Time: {d} us\n", .{actual_period_time});

        // --- Get Period Size and Allocate Buffer ---
        try checkAlsa(c.snd_pcm_hw_params_get_period_size(hw_params.?, &period_size_frames, &dir), "snd_pcm_hw_params_get_period_size");
        std.debug.print("Period size: {d} frames\n", .{period_size_frames});

        bytes_per_frame = @as(usize, @intCast(actual_channels)) * (@as(usize, @intCast(bits_per_sample)) / 8);
        buffer_size_bytes = @as(usize, @intCast(period_size_frames)) * bytes_per_frame;
        buffer = try allocator.alloc(u8, buffer_size_bytes);

        std.debug.print("Read buffer size: {d} bytes\n", .{buffer_size_bytes});

        // --- Prepare PCM Device ---
        try checkAlsa(c.snd_pcm_prepare(pcm_handle.?), "snd_pcm_prepare");
        std.debug.print("ALSA device prepared. Recording for ~5 seconds...\n", .{});

        return .{
            .pcm_handle = pcm_handle,
            .hw_params = hw_params,
            .buffer = buffer,
            .period_size_frames = period_size_frames,
            .bytes_per_frame = bytes_per_frame,
            .allocator = allocator,
        };
    }

    pub fn close(self: *@This()) void {
        defer if (self.pcm_handle) |h| {
            std.debug.print("Closing ALSA device...\n", .{});
            _ = c.snd_pcm_close(h);
        };
        defer if (self.hw_params) |p| c.snd_pcm_hw_params_free(p);
        defer self.allocator.free(self.buffer);
    }

    pub fn getAudio(
        self: *@This(),
        ring_buffer: *std.RingBuffer,
    ) !u32 {
        var total_bytes_written: u32 = 0;

        // --- Recording Loop ---
        var timer = try std.time.Timer.start();
        const duration_ns = 3 * std.time.ns_per_s;

        while (timer.read() < duration_ns) {
            const ret = c.snd_pcm_readi(self.pcm_handle.?, self.buffer.ptr, self.period_size_frames);

            if (ret == -c.EPIPE) {
                std.debug.print("XRUN (overrun) occurred! Attempting recovery...\n", .{});
                try checkAlsa(c.snd_pcm_prepare(self.pcm_handle.?), "snd_pcm_prepare after XRUN");
                continue;
            } else if (ret < 0) {
                const err_str = c.snd_strerror(@as(c_int, @intCast(ret)));
                std.debug.print("\nError reading from PCM device: {s} (code: {d})\n", .{ mem.sliceTo(err_str, 0), ret });
                return error.AlsaReadError;
            } else if (@as(c.snd_pcm_uframes_t, @intCast(ret)) != self.period_size_frames) {
                std.debug.print("\nShort read: got {d} frames, expected {d}\n", .{ ret, self.period_size_frames });
                // Process the frames we did get
            }

            const bytes_to_write = @as(usize, @intCast(ret)) * self.bytes_per_frame;
            if (bytes_to_write > 0) {
                try ring_buffer.writeSlice(self.buffer[0..bytes_to_write]);
                total_bytes_written += @intCast(bytes_to_write);
            }
        }
        return total_bytes_written;
    }
};
