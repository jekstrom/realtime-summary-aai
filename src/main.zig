const std = @import("std");
const websocket = @import("websocket");
const Mutex = std.Thread.Mutex;
const fs = std.fs;
const io = std.io;
const AnyWriter = io.AnyWriter;
const Audio = @import("audio.zig").Audio;
const WebsocketTokenResponse = @import("response.zig").WebsocketTokenResponse;
const FinalTranscript = @import("response.zig").FinalTranscript;
const PartialTranscript = @import("response.zig").PartialTranscript;
const SessionBeginsMessage = @import("response.zig").SessionBeginsMessage;
const Message = @import("response.zig").Message;
const SummarizeResponse = @import("response.zig").SummarizeResponse;

const http = std.http;
const heap = std.heap;
const json = std.json;

const Client = std.http.Client;
const Header = std.http.Header;
const Uri = std.Uri;

// wss://api.assemblyai.com/v2/realtime/ws
const wsHost = "api.assemblyai.com";
const wsUri = "wss://" ++ wsHost;
const wsPort = 443;

const Handler = struct {
    client: websocket.Client,
    allocator: std.mem.Allocator,
    transcriptWriter: std.ArrayList(u8).Writer,
    mutex: *Mutex,
    wsHost: []const u8,
    apiKey: []const u8,
    token: WebsocketTokenResponse,

    fn init(
        allocator: std.mem.Allocator,
        token: WebsocketTokenResponse,
        apiKey: []const u8,
        transcriptWriter: std.ArrayList(u8).Writer,
        mutex: *Mutex,
    ) !Handler {
        const client = try websocket.Client.init(allocator, .{
            .port = wsPort,
            .host = wsHost,
            .tls = true,
        });

        var handler: Handler = .{
            .client = client,
            .allocator = allocator,
            .transcriptWriter = transcriptWriter,
            .mutex = mutex,
            .wsHost = wsHost,
            .apiKey = apiKey,
            .token = token,
        };
        try handler.handshake();
        return handler;
    }

    fn handshake(self: *@This()) !void {
        const headerString = try std.fmt.allocPrint(self.allocator, "Host: {s}\r\nAuthorization: {s}", .{ self.wsHost, self.apiKey });
        defer self.allocator.free(headerString);

        const pathString = try std.fmt.allocPrint(self.allocator, "/v2/realtime/ws?sample_rate=16000&disable_partial_transcripts=true&token={s}", .{self.token.token.?});
        defer self.allocator.free(pathString);

        try self.client.handshake(pathString, .{
            .timeout_ms = 3000,
            .headers = headerString,
        });
    }

    pub fn deinit(self: *Handler) void {
        self.client.deinit();
    }

    pub fn startLoop(self: *Handler) !std.Thread {
        std.debug.print("Start loop\n", .{});
        return try self.client.readLoopInNewThread(self);
    }

    pub fn serverMessage(self: *Handler, data: []u8) !void {
        const msg: Message = try Message.fromJson(data, self.allocator);

        if (std.mem.eql(u8, msg.message_type, "SessionBegins")) {
            _ = try SessionBeginsMessage.fromJson(data, self.allocator);
        } else if (std.mem.eql(u8, msg.message_type, "PartialTranscript")) {
            _ = try PartialTranscript.fromJson(data, self.allocator);
        } else if (std.mem.eql(u8, msg.message_type, "FinalTranscript")) {
            const transcript: FinalTranscript = try FinalTranscript.fromJson(data, self.allocator);
            // std.debug.print("{s}\n", .{transcript.text});
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock();
                try self.transcriptWriter.writeAll(transcript.text);
            }
        } else {
            std.debug.print("Unrecognized message type '{s}'.\n", .{msg.message_type});
        }
    }

    pub fn send(self: *Handler, data: []u8, size: u32) !void {
        try self.client.writeBin(data[0..size]);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ringBuffer = try std.RingBuffer.init(allocator, 31200 * 10);
    defer ringBuffer.deinit(allocator);

    var httpClient = Client{ .allocator = allocator };
    defer httpClient.deinit();

    var tokenRes: ?WebsocketTokenResponse = null;
    const apiKey = std.posix.getenv("AAI_API_KEY") orelse "";
    if (apiKey.len == 0) {
        std.debug.print("No API Key found.\n", .{});
        return;
    }

    const headers: Client.Request.Headers = .{
        .authorization = .{ .override = apiKey },
        .content_type = .{ .override = "application/json" },
        .host = .{ .override = "api.assemblyai.com" },
    };

    tokenRes = try getAuthToken(allocator, headers);
    if (tokenRes == null) {
        std.debug.print("Could not get token.\n", .{});
        return;
    }

    var fullTranscript = std.ArrayList(u8).init(std.heap.page_allocator);
    defer fullTranscript.deinit();
    try fullTranscript.append('b');
    _ = fullTranscript.pop();

    var mutex = Mutex{};

    var handler: Handler = try Handler.init(allocator, tokenRes.?, apiKey, fullTranscript.writer(), &mutex);
    defer handler.deinit();

    const thread = try handler.startLoop();
    thread.detach();

    var audio = try Audio.init(allocator);
    defer audio.close();

    std.debug.print("Recording...\n", .{});
    var i: u8 = 0;

    while (true) {
        const audioSize = try audio.getAudio(&ringBuffer);

        const buf = try allocator.alloc(u8, audioSize);
        try ringBuffer.readLast(buf, audioSize);
        try handler.send(buf, audioSize);

        if (fullTranscript.items.len > 100 and @mod(i, 5) == 0) {
            if (mutex.tryLock()) {
                defer mutex.unlock();
                const summaryThread = try std.Thread.spawn(
                    .{},
                    summarizeText,
                    .{
                        allocator,
                        headers,
                        fullTranscript.items,
                    },
                );
                summaryThread.detach();
            }
        }
        i += 1;

        allocator.free(buf);
    }

    std.Thread.sleep(std.time.ns_per_s * 3);
}

fn getAuthToken(allocator: std.mem.Allocator, headers: Client.Request.Headers) !WebsocketTokenResponse {
    const uriString = "https://api.assemblyai.com/v2/realtime/token";

    const getUri = try Uri.parse(uriString);

    var getBuffer: [4096]u8 = undefined;

    var httpClient = Client{ .allocator = allocator };
    defer httpClient.deinit();

    var req = try httpClient.open(
        http.Method.POST,
        getUri,
        .{
            .server_header_buffer = &getBuffer,
            .headers = headers,
        },
    );
    defer req.deinit();

    const data: []const u8 = "{\"expires_in\": 480}";

    req.transfer_encoding = .{ .content_length = data.len };

    try req.send();
    try req.writeAll(data);

    try req.finish();

    try req.wait();

    const res = try req.reader().readAllAlloc(
        allocator,
        1024 * 1, // 1kb
    );
    defer allocator.free(res);

    std.debug.print("get response - {s}\n", .{res});

    const parsed = try json.parseFromSlice(
        WebsocketTokenResponse,
        allocator,
        res,
        .{ .allocate = .alloc_always },
    );

    return parsed.value;
}

fn summarizeText(allocator: std.mem.Allocator, headers: Client.Request.Headers, text: []const u8) !void {
    const uriString = "https://api.assemblyai.com/lemur/v3/generate/summary";

    const getUri = try Uri.parse(uriString);

    var getBuffer: [4096]u8 = undefined;

    var httpClient = Client{ .allocator = allocator };
    defer httpClient.deinit();

    var req = try httpClient.open(
        http.Method.POST,
        getUri,
        .{
            .server_header_buffer = &getBuffer,
            .headers = headers,
        },
    );
    defer req.deinit();

    const data = try std.fmt.allocPrint(
        allocator,
        "{{\"final_model\": \"anthropic/claude-3-5-sonnet\", \"input_text\": \"{s}\"}}",
        .{text},
    );
    defer allocator.free(data);

    req.transfer_encoding = .{ .content_length = data.len };

    try req.send();
    try req.writeAll(data);

    try req.finish();

    try req.wait();

    const res = try req.reader().readAllAlloc(
        allocator,
        1024 * 10, // 10kb
    );
    defer allocator.free(res);

    // Parse json
    const parsed = try json.parseFromSlice(
        SummarizeResponse,
        allocator,
        res,
        .{ .allocate = .alloc_always },
    );

    std.debug.print("Summary: {s}\n", .{parsed.value.response});
    parsed.deinit();
}
