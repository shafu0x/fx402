const std = @import("std");
const core_types = @import("../../core/shared/types.zig");
const io_mod = @import("../../core/shared/io.zig");
const http_fetch = @import("../web/http_fetch.zig");
const url_policy = @import("../web/url_policy.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const crypto = @import("crypto.zig");
const http_util = @import("http_util.zig");
const protocol = @import("protocol.zig");
const rpc = @import("rpc.zig");
const wallet = @import("wallet.zig");

const Allocator = std.mem.Allocator;
const whitespace = " \t\r\n";

const pay_label = "Pay";
const cancel_label = "Cancel";
const funded_label = "Funded, retry";
const declined_message = "payment declined";
const noninteractive_message = "x402_fetch cannot pay without an interactive prompt. Run fx in a TTY.";

pub const Input = struct {
    url: []u8,
    method: []u8,
    body: ?[]u8,
    headers: []http_fetch.ExtraHeader,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.method);
        if (self.body) |body| alloc.free(body);
        http_util.freeHeaders(alloc, self.headers);
        self.* = .{ .url = &.{}, .method = &.{}, .body = null, .headers = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch arguments must be an object") };
    }
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "url") or
            std.mem.eql(u8, entry.key_ptr.*, "method") or
            std.mem.eql(u8, entry.key_ptr.*, "body") or
            std.mem.eql(u8, entry.key_ptr.*, "headers")) continue;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch field \"{s}\" is not allowed", .{entry.key_ptr.*}) };
    }
    const url_value = parsed.value.object.get("url") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch field \"url\" is required") };
    };
    if (url_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch field \"url\" must be a string") };
    }
    const method_text = if (parsed.value.object.get("method")) |method_value| blk: {
        if (method_value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch field \"method\" must be a string") };
        }
        break :blk method_value.string;
    } else "GET";
    var body: ?[]u8 = null;
    errdefer if (body) |owned| ctx.allocator.free(owned);
    if (parsed.value.object.get("body")) |body_value| {
        if (body_value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch field \"body\" must be a string") };
        }
        body = try ctx.allocator.dupe(u8, body_value.string);
    }
    var headers: []http_fetch.ExtraHeader = &.{};
    errdefer if (headers.len != 0) http_util.freeHeaders(ctx.allocator, headers);
    if (parsed.value.object.get("headers")) |headers_value| {
        headers = http_util.headersFromObject(ctx.allocator, headers_value) catch {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch field \"headers\" must be an object of strings") };
        };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .url = try ctx.allocator.dupe(u8, url_value.string),
        .method = try ctx.allocator.dupe(u8, method_text),
        .body = body,
        .headers = headers,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const trimmed = std.mem.trim(u8, input.url, whitespace);
    if (!std.mem.eql(u8, input.url, trimmed)) {
        const owned = try ctx.allocator.dupe(u8, trimmed);
        ctx.allocator.free(input.url);
        input.url = owned;
    }
    var normalized = url_policy.normalize(ctx.allocator, input.url) catch {
        return try ctx.allocator.dupe(u8, "x402_fetch url must be a public HTTP(S) URL");
    };
    defer normalized.deinit(ctx.allocator);
    if (!isHttpMethod(input.method)) {
        return try ctx.allocator.dupe(u8, "x402_fetch method must be GET, POST, PUT, DELETE, or PATCH");
    }
    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWithTransport(ctx, erased, http_fetch.defaultTransport());
}

pub fn callWithTransport(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
    transport: http_fetch.Transport,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    var first = http_util.fetchUrl(ctx.allocator, input.url, .{
        .method = input.method,
        .body = input.body,
        .extra_headers = input.headers,
    }, transport) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch transport failed: {s}", .{@errorName(err)}) };
    };
    defer first.deinit(ctx.allocator);

    switch (first) {
        .success => |success| return formatHttpResult(ctx, success.status, success.body),
        .cross_host_redirect => |target| return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "x402_fetch refused a cross-host redirect to {s}. Nothing was paid. Call x402_fetch again with that exact URL if the host is expected.",
            .{target},
        ) },
        .failure => |failure| {
            if (failure.status != .payment_required) {
                return formatNonPaymentFailure(ctx.allocator, failure);
            }
            return payFromRequired(ctx, input, failure, transport);
        },
    }
}

fn payFromRequired(
    ctx: tool_dispatch.DispatchContext,
    input: *Input,
    failure: http_fetch.Failure,
    transport: http_fetch.Transport,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const header = failure.payment_required orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "HTTP 402 without PAYMENT-REQUIRED. Cannot pay.") };
    };
    var parsed = protocol.decodePaymentRequired(ctx.allocator, header) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch could not decode PAYMENT-REQUIRED") };
    };
    defer parsed.deinit();
    const selected = protocol.selectExactBase(parsed.value) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "This endpoint has no eip155:8453 exact option. x402_fetch only pays Base USDC.") };
    };

    const ask = ctx.ask_question_batch orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, noninteractive_message) };
    };

    const loaded = wallet.loadOrCreate(ctx.allocator) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch could not load the wallet: {s}", .{@errorName(err)}) };
    };

    var amount = rpc.usdcBalance(ctx.allocator, loaded.address, transport) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch could not read Base USDC: {s}", .{@errorName(err)}) };
    };
    var attempts: u8 = 0;
    while (amount < selected.amount_atomic) : (attempts += 1) {
        if (attempts >= 5) {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_fetch still has insufficient Base USDC after funding retries.") };
        }
        const funded = askFund(ctx, ask, loaded, selected, amount) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch funding prompt failed: {s}", .{@errorName(err)}) },
        };
        if (!funded) return .{ .failure = try ctx.allocator.dupe(u8, declined_message) };
        amount = rpc.usdcBalance(ctx.allocator, loaded.address, transport) catch |err| {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch could not re-read Base USDC: {s}", .{@errorName(err)}) };
        };
    }

    const approved = askPay(ctx, ask, input.url, selected, amount) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch payment prompt failed: {s}", .{@errorName(err)}) },
    };
    if (!approved) return .{ .failure = try ctx.allocator.dupe(u8, declined_message) };

    const signature_header = signPayment(ctx.allocator, loaded, selected) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch could not sign the payment: {s}", .{@errorName(err)}) };
    };
    defer ctx.allocator.free(signature_header);

    const retry_headers = try signedHeaders(ctx.allocator, input.headers, signature_header);
    defer ctx.allocator.free(retry_headers);

    var retry = http_util.fetchUrl(ctx.allocator, input.url, .{
        .method = input.method,
        .body = input.body,
        .extra_headers = retry_headers,
    }, transport) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_fetch paid retry failed: {s}", .{@errorName(err)}) };
    };
    defer retry.deinit(ctx.allocator);
    return switch (retry) {
        .success => |success| formatHttpResult(ctx, success.status, success.body),
        .cross_host_redirect => |target| .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "x402_fetch signed a payment but the origin redirected to {s}, which never received it. Call x402_fetch with that exact URL.",
            .{target},
        ) },
        .failure => |paid_failure| formatPaidFailure(ctx.allocator, paid_failure),
    };
}

fn signPayment(alloc: Allocator, loaded: wallet.Wallet, selected: protocol.SelectedPayment) ![]u8 {
    var nonce: [32]u8 = undefined;
    io_mod.getIo().random(&nonce);
    const now_ms = io_mod.milliTimestamp();
    const now: u64 = if (now_ms <= 0) 0 else @intCast(@divTrunc(now_ms, 1000));
    const valid_after: u256 = if (now > 600) now - 600 else 0;
    const authorization = crypto.Authorization{
        .from = loaded.address,
        .to = selected.pay_to,
        .value = selected.amount_atomic,
        .valid_after = valid_after,
        .valid_before = @as(u256, now) + selected.max_timeout_seconds,
        .nonce = nonce,
    };
    const signature = try crypto.signTransferWithAuthorization(
        loaded.secret,
        selected.extra_name,
        selected.extra_version,
        8453,
        selected.asset,
        authorization,
    );
    return protocol.encodePaymentSignature(alloc, selected, loaded.address, authorization, signature);
}

fn signedHeaders(
    alloc: Allocator,
    existing: []const http_fetch.ExtraHeader,
    signature: []const u8,
) ![]http_fetch.ExtraHeader {
    const headers = try alloc.alloc(http_fetch.ExtraHeader, existing.len + 1);
    @memcpy(headers[0..existing.len], existing);
    headers[existing.len] = .{ .name = "PAYMENT-SIGNATURE", .value = signature };
    return headers;
}

fn askFund(
    ctx: tool_dispatch.DispatchContext,
    ask: tool_dispatch.AskQuestionBatchFn,
    loaded: wallet.Wallet,
    selected: protocol.SelectedPayment,
    amount: u256,
) !bool {
    var price_buf: [32]u8 = undefined;
    var balance_buf: [32]u8 = undefined;
    var shortfall_buf: [32]u8 = undefined;
    const price = protocol.formatUsdcSlice(selected.amount_atomic, &price_buf);
    const balance = protocol.formatUsdcSlice(amount, &balance_buf);
    const shortfall = protocol.formatUsdcSlice(selected.amount_atomic - amount, &shortfall_buf);
    const address = loaded.addressHex();
    const question = try std.fmt.allocPrint(
        ctx.allocator,
        "Insufficient Base USDC for {s}. Address {s} has {s} and needs {s} more. Fund then retry, or cancel.",
        .{ price, address, balance, shortfall },
    );
    defer ctx.allocator.free(question);
    return askChoice(ctx, ask, question, &.{
        .{ .label = funded_label, .description = "Recheck the Base USDC balance after funding" },
        .{ .label = cancel_label, .description = "Do not pay" },
    }, funded_label);
}

fn askPay(
    ctx: tool_dispatch.DispatchContext,
    ask: tool_dispatch.AskQuestionBatchFn,
    url: []const u8,
    selected: protocol.SelectedPayment,
    amount: u256,
) !bool {
    var price_buf: [32]u8 = undefined;
    var balance_buf: [32]u8 = undefined;
    const price = protocol.formatUsdcSlice(selected.amount_atomic, &price_buf);
    const balance = protocol.formatUsdcSlice(amount, &balance_buf);
    const pay_to = crypto.formatAddress(selected.pay_to);
    const question = try std.fmt.allocPrint(
        ctx.allocator,
        "Pay {s} USDC on {s} to {s} for {s}? Wallet balance {s}.",
        .{ price, protocol.supported_network, pay_to, url, balance },
    );
    defer ctx.allocator.free(question);
    return askChoice(ctx, ask, question, &.{
        .{ .label = pay_label, .description = "Sign and retry with PAYMENT-SIGNATURE" },
        .{ .label = cancel_label, .description = "Do not pay" },
    }, pay_label);
}

fn askChoice(
    ctx: tool_dispatch.DispatchContext,
    ask: tool_dispatch.AskQuestionBatchFn,
    question: []const u8,
    options: []const core_types.QuestionOption,
    accept: []const u8,
) !bool {
    const entries = [_]core_types.QuestionBatchEntry{.{
        .question = question,
        .options = options,
    }};
    const answers = try ask(ctx.ask_question_ctx, ctx.allocator, &entries) orelse return false;
    defer {
        for (answers) |answer| ctx.allocator.free(answer);
        ctx.allocator.free(answers);
    }
    return answers.len > 0 and std.mem.eql(u8, answers[0], accept);
}

fn formatHttpResult(ctx: tool_dispatch.DispatchContext, status: std.http.Status, body: []const u8) !tool_dispatch.ToolResult {
    const reserve = 64;
    const budget = if (ctx.max_tool_result_bytes > reserve) ctx.max_tool_result_bytes - reserve else ctx.max_tool_result_bytes;
    const clipped = @min(body.len, budget);
    if (body.len > clipped) {
        return .{ .success = try std.fmt.allocPrint(
            ctx.allocator,
            "HTTP {d}\n{s}\n[truncated; body was {d} bytes]",
            .{ @intFromEnum(status), body[0..clipped], body.len },
        ) };
    }
    return .{ .success = try std.fmt.allocPrint(
        ctx.allocator,
        "HTTP {d}\n{s}",
        .{ @intFromEnum(status), body[0..clipped] },
    ) };
}

fn formatNonPaymentFailure(alloc: Allocator, failure: http_fetch.Failure) !tool_dispatch.ToolResult {
    const status = if (failure.status) |value| @intFromEnum(value) else 0;
    const preview_len = @min(failure.body.len, 512);
    const suffix = if (status == 400) " Call x402_check on this URL before retrying." else "";
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "HTTP {d}. {s}{s}",
        .{ status, failure.body[0..preview_len], suffix },
    ) };
}

fn formatPaidFailure(alloc: Allocator, failure: http_fetch.Failure) !tool_dispatch.ToolResult {
    const status = if (failure.status) |value| @intFromEnum(value) else 0;
    const preview_len = @min(failure.body.len, 512);
    if (status == 400) {
        return .{ .failure = try std.fmt.allocPrint(
            alloc,
            "HTTP 400 after payment. {s} Call x402_check on this URL before retrying.",
            .{failure.body[0..preview_len]},
        ) };
    }
    if (status == 402) {
        return .{ .failure = try alloc.dupe(u8, "payment was rejected; check balance and x402_check") };
    }
    return .{ .failure = try std.fmt.allocPrint(alloc, "HTTP {d} after payment. {s}", .{ status, failure.body[0..preview_len] }) };
}

fn isHttpMethod(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "GET") or
        std.ascii.eqlIgnoreCase(name, "POST") or
        std.ascii.eqlIgnoreCase(name, "PUT") or
        std.ascii.eqlIgnoreCase(name, "DELETE") or
        std.ascii.eqlIgnoreCase(name, "PATCH");
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

const payment_required_json =
    \\{"x402Version":2,"resource":{"url":"https://example.com/pay","description":"d","mimeType":"application/json"},"accepts":[{"scheme":"exact","network":"eip155:8453","asset":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","amount":"10000","payTo":"0x1111111111111111111111111111111111111111","maxTimeoutSeconds":60,"extra":{"name":"USD Coin","version":"2"}}]}
;

const MockTransport = struct {
    origin_calls: usize = 0,
    rpc_calls: usize = 0,
    signed_retry: bool = false,
    payment_header: []const u8,
    balance_hex: []const u8 = "0x1e8480",
    paid_body: []const u8 = "{\"ok\":true}",
    unpaid_body: []const u8 = "payment required",

    fn transport(self: *@This()) http_fetch.Transport {
        return .{
            .resolver = .{ .ctx = @ptrCast(self), .resolve = resolve },
            .connector = .{ .ctx = @ptrCast(self), .get = get },
        };
    }

    fn resolve(_: *anyopaque, alloc: Allocator, _: []const u8, port: u16, _: http_fetch.FetchOptions) anyerror![]std.Io.net.IpAddress {
        const out = try alloc.alloc(std.Io.net.IpAddress, 1);
        out[0] = try std.Io.net.IpAddress.parse("93.184.216.34", port);
        return out;
    }

    fn get(raw: *anyopaque, alloc: Allocator, target: http_fetch.PinnedTarget, options: http_fetch.FetchOptions) anyerror!http_fetch.ConnectorResponse {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (std.mem.find(u8, target.url.retrieval_url, "mainnet.base.org") != null) {
            self.rpc_calls += 1;
            const body = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"{s}\"}}", .{self.balance_hex});
            return .{ .status = .ok, .body = body, .content_type = try alloc.dupe(u8, "application/json") };
        }
        self.origin_calls += 1;
        if (hasPaymentSignature(options.extra_headers)) {
            self.signed_retry = true;
            return .{
                .status = .ok,
                .body = try alloc.dupe(u8, self.paid_body),
                .content_type = try alloc.dupe(u8, "application/json"),
            };
        }
        return .{
            .status = .payment_required,
            .body = try alloc.dupe(u8, self.unpaid_body),
            .payment_required = try alloc.dupe(u8, self.payment_header),
        };
    }
};

fn hasPaymentSignature(headers: []const http_fetch.ExtraHeader) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "PAYMENT-SIGNATURE") and header.value.len > 0) return true;
    }
    return false;
}

fn encodeFixtureHeader(alloc: Allocator) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, encoder.calcSize(payment_required_json.len));
    _ = encoder.encode(out, payment_required_json);
    return out;
}

fn approvePay(_: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
    _ = entries;
    const answers = try alloc.alloc([]u8, 1);
    answers[0] = try alloc.dupe(u8, pay_label);
    return answers;
}

fn cancelPay(_: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
    _ = entries;
    _ = alloc;
    return null;
}

fn decodeInput(alloc: Allocator, json: []const u8) !tool_dispatch.ToolInput {
    const decoded = try decode(.{ .allocator = alloc }, json);
    return switch (decoded) {
        .input => |input| input,
        .failure => |body| {
            alloc.free(body);
            return error.TestExpectedEqual;
        },
    };
}

test "x402_fetch approves 402 then sends a signed retry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    wallet.test_home = home;
    defer wallet.test_home = null;

    const header = try encodeFixtureHeader(alloc);
    defer alloc.free(header);
    var mock = MockTransport{ .payment_header = header };
    var input_value = try decodeInput(alloc, "{\"url\":\"https://example.com/pay\",\"method\":\"POST\",\"body\":\"{}\"}");
    defer input_value.deinit(alloc);
    if (validate(.{ .allocator = alloc }, input_value)) |maybe_err| {
        if (maybe_err) |reason| {
            alloc.free(reason);
            return error.TestExpectedEqual;
        }
    } else |_| return error.TestExpectedEqual;

    var result = try callWithTransport(.{
        .allocator = alloc,
        .ask_question_batch = approvePay,
    }, input_value, mock.transport());
    defer result.deinit(alloc);
    const body = switch (result) {
        .success => |text| text,
        .failure => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 2), mock.origin_calls);
    try std.testing.expect(mock.signed_retry);
    try std.testing.expect(mock.rpc_calls >= 1);
    try std.testing.expect(std.mem.find(u8, body, "HTTP 200") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"ok\":true}") != null);
}

test "x402_fetch fails closed without ask_question_batch and does not retry" {
    const alloc = std.testing.allocator;
    const header = try encodeFixtureHeader(alloc);
    defer alloc.free(header);
    var mock = MockTransport{ .payment_header = header };
    var input_value = try decodeInput(alloc, "{\"url\":\"https://example.com/pay\"}");
    defer input_value.deinit(alloc);
    if (validate(.{ .allocator = alloc }, input_value)) |maybe_err| {
        if (maybe_err) |reason| {
            alloc.free(reason);
            return error.TestExpectedEqual;
        }
    } else |_| return error.TestExpectedEqual;

    var result = try callWithTransport(.{ .allocator = alloc }, input_value, mock.transport());
    defer result.deinit(alloc);
    const body = switch (result) {
        .success => return error.TestExpectedEqual,
        .failure => |text| text,
    };
    try std.testing.expectEqual(@as(usize, 1), mock.origin_calls);
    try std.testing.expectEqual(@as(usize, 0), mock.rpc_calls);
    try std.testing.expect(!mock.signed_retry);
    try std.testing.expect(std.mem.find(u8, body, "cannot pay without an interactive prompt") != null);
}

test "x402_fetch cancel is payment declined with no signed retry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    wallet.test_home = home;
    defer wallet.test_home = null;

    const header = try encodeFixtureHeader(alloc);
    defer alloc.free(header);
    var mock = MockTransport{ .payment_header = header };
    var input_value = try decodeInput(alloc, "{\"url\":\"https://example.com/pay\"}");
    defer input_value.deinit(alloc);
    if (validate(.{ .allocator = alloc }, input_value)) |maybe_err| {
        if (maybe_err) |reason| {
            alloc.free(reason);
            return error.TestExpectedEqual;
        }
    } else |_| return error.TestExpectedEqual;

    var result = try callWithTransport(.{
        .allocator = alloc,
        .ask_question_batch = cancelPay,
    }, input_value, mock.transport());
    defer result.deinit(alloc);
    const body = switch (result) {
        .success => return error.TestExpectedEqual,
        .failure => |text| text,
    };
    try std.testing.expectEqual(@as(usize, 1), mock.origin_calls);
    try std.testing.expect(!mock.signed_retry);
    try std.testing.expectEqualStrings(declined_message, body);
}
