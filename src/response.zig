const std = @import("std");

pub const WebsocketTokenResponse = struct {
    token: ?[]const u8 = null,
};

const Word = struct {
    start: i64,
    end: i64,
    confidence: f64,
    text: []const u8,
};

pub const Message = struct {
    message_type: []const u8,

    pub fn fromJson(json_string: []const u8, allocator: std.mem.Allocator) !Message {
        const parsed = try std.json.parseFromSlice(
            Message,
            allocator,
            json_string,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        return parsed.value;
    }
};

pub const SessionBeginsMessage = struct {
    message_type: []const u8,
    session_id: []const u8,
    expires_at: []const u8,

    pub fn fromJson(json_string: []const u8, allocator: std.mem.Allocator) !SessionBeginsMessage {
        const parsed = try std.json.parseFromSlice(
            SessionBeginsMessage,
            allocator,
            json_string,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        return parsed.value;
    }
};

pub const PartialTranscript = struct {
    message_type: []const u8,
    created: []const u8,
    audio_start: i64,
    audio_end: i64,
    confidence: f64,
    text: []const u8,
    words: ?[]Word,

    pub fn fromJson(json_string: []const u8, allocator: std.mem.Allocator) !PartialTranscript {
        const parsed = try std.json.parseFromSlice(
            PartialTranscript,
            allocator,
            json_string,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();

        return parsed.value;
    }
};

pub const FinalTranscript = struct {
    message_type: []const u8,
    created: []const u8,
    audio_start: i64,
    audio_end: i64,
    confidence: f64,
    text: []const u8,
    words: ?[]Word,
    punctuated: ?bool,
    text_formatted: ?bool,

    pub fn fromJson(json_string: []const u8, allocator: std.mem.Allocator) !FinalTranscript {
        const parsed = try std.json.parseFromSlice(
            FinalTranscript,
            allocator,
            json_string,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();

        return parsed.value;
    }
};

const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
};

pub const SummarizeResponse = struct {
    request_id: []const u8,
    response: []const u8,
    usage: Usage,
};
