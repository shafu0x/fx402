const std = @import("std");
const http_fetch = @import("../web/http_fetch.zig");
const url_policy = @import("../web/url_policy.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const http_util = @import("http_util.zig");
const openapi = @import("openapi.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const whitespace = " \t\r\n";

pub const Input = struct {
    endpoint_url: []u8,
    method: ?[]u8,
    body: ?[]u8,
    headers: []http_fetch.ExtraHeader,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.endpoint_url);
        if (self.method) |method| alloc.free(method);
        if (self.body) |body| alloc.free(body);
        http_util.freeHeaders(alloc, self.headers);
        self.* = .{ .endpoint_url = &.{}, .method = null, .body = null, .headers = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check arguments must be an object") };
    }
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "endpoint_url") or
            std.mem.eql(u8, entry.key_ptr.*, "method") or
            std.mem.eql(u8, entry.key_ptr.*, "body") or
            std.mem.eql(u8, entry.key_ptr.*, "headers")) continue;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_check field \"{s}\" is not allowed", .{entry.key_ptr.*}) };
    }
    const url_value = parsed.value.object.get("endpoint_url") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check field \"endpoint_url\" is required") };
    };
    if (url_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check field \"endpoint_url\" must be a string") };
    }
    var method: ?[]u8 = null;
    errdefer if (method) |owned| ctx.allocator.free(owned);
    if (parsed.value.object.get("method")) |method_value| {
        if (method_value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_check field \"method\" must be a string") };
        }
        method = try ctx.allocator.dupe(u8, method_value.string);
    }
    var body: ?[]u8 = null;
    errdefer if (body) |owned| ctx.allocator.free(owned);
    if (parsed.value.object.get("body")) |body_value| {
        if (body_value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_check field \"body\" must be a string") };
        }
        body = try ctx.allocator.dupe(u8, body_value.string);
    }
    var headers: []http_fetch.ExtraHeader = &.{};
    errdefer if (headers.len != 0) http_util.freeHeaders(ctx.allocator, headers);
    if (parsed.value.object.get("headers")) |headers_value| {
        headers = http_util.headersFromObject(ctx.allocator, headers_value) catch {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_check field \"headers\" must be an object of strings") };
        };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .endpoint_url = try ctx.allocator.dupe(u8, url_value.string),
        .method = method,
        .body = body,
        .headers = headers,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const trimmed = std.mem.trim(u8, input.endpoint_url, whitespace);
    if (!std.mem.eql(u8, input.endpoint_url, trimmed)) {
        const owned = try ctx.allocator.dupe(u8, trimmed);
        ctx.allocator.free(input.endpoint_url);
        input.endpoint_url = owned;
    }
    var normalized = url_policy.normalize(ctx.allocator, input.endpoint_url) catch {
        return try ctx.allocator.dupe(u8, "x402_check endpoint_url must be a public HTTP(S) URL");
    };
    defer normalized.deinit(ctx.allocator);
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
    const origin = http_util.originUrl(ctx.allocator, input.endpoint_url) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check endpoint_url must be a public HTTP(S) URL") };
    };
    defer ctx.allocator.free(origin);

    var target = url_policy.normalize(ctx.allocator, input.endpoint_url) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check endpoint_url must be a public HTTP(S) URL") };
    };
    defer target.deinit(ctx.allocator);
    const path = http_util.pathOnly(target.path_query);

    const spec_text = try http_util.fetchDiscoveryDocument(ctx.allocator, origin, transport) orelse {
        return .{ .success = try std.fmt.allocPrint(
            ctx.allocator,
            "No discovery document at {s}/openapi.json or {s}/.well-known/x402. If you already know the exact URL, call x402_fetch; otherwise pick another origin.",
            .{ origin, origin },
        ) };
    };
    defer ctx.allocator.free(spec_text);

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, spec_text, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check received an unparseable OpenAPI document") };
    };
    defer parsed.deinit();

    const operation = findCheckedOperation(parsed.value, path, input.method) orelse {
        return .{ .failure = try missingOperation(ctx.allocator, parsed.value, path, input.method) };
    };
    const schema = openapi.compactSchema(ctx.allocator, operation) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_check could not compact this operation schema") };
    };
    if (input.body == null) return .{ .success = schema };

    const quote = probeUnpaid(ctx.allocator, input, transport) catch |err| {
        ctx.allocator.free(schema);
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_check unpaid probe failed: {s}", .{@errorName(err)}) };
    };
    defer ctx.allocator.free(quote);
    const combined = std.fmt.allocPrint(ctx.allocator, "{s}\nprobe:\n{s}\n", .{ schema, quote }) catch |err| {
        ctx.allocator.free(schema);
        return err;
    };
    ctx.allocator.free(schema);
    return .{ .success = combined };
}

fn findCheckedOperation(spec: std.json.Value, path: []const u8, method: ?[]const u8) ?openapi.Operation {
    if (openapi.findOperation(spec, path, method)) |operation| return operation;
    if (path.len > 1 and path[path.len - 1] == '/') {
        return openapi.findOperation(spec, path[0 .. path.len - 1], method);
    }
    return null;
}

fn missingOperation(alloc: Allocator, spec: std.json.Value, path: []const u8, method: ?[]const u8) Allocator.Error![]u8 {
    const candidates = openapi.candidatePaths(alloc, spec, path, 5) catch &.{};
    defer alloc.free(candidates);
    const verb = method orelse "any";
    if (candidates.len == 0) {
        return std.fmt.allocPrint(
            alloc,
            "No operation for {s} {s} at this origin. Call x402_discover first.",
            .{ verb, path },
        );
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.print(
        "No operation for {s} {s} at this origin. Closest documented paths (a placeholder segment is written literally in this spec, substitute your value):",
        .{ verb, path },
    ) catch return error.OutOfMemory;
    for (candidates) |candidate| {
        out.writer.print("\n  {s}", .{candidate}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

fn probeUnpaid(alloc: Allocator, input: *Input, transport: http_fetch.Transport) ![]u8 {
    var result = try http_util.fetchUrl(alloc, input.endpoint_url, .{
        .method = input.method orelse "GET",
        .body = input.body,
        .extra_headers = input.headers,
    }, transport);
    defer result.deinit(alloc);
    switch (result) {
        .success => |success| return std.fmt.allocPrint(
            alloc,
            "HTTP {d} (no payment required)\n{s}",
            .{ @intFromEnum(success.status), success.body },
        ),
        .failure => |failure| {
            if (failure.status == .payment_required) {
                if (failure.payment_required) |header| {
                    var parsed = protocol.decodePaymentRequired(alloc, header) catch {
                        return alloc.dupe(u8, "HTTP 402 quote could not be decoded. Call x402_fetch only if you already know the price.");
                    };
                    defer parsed.deinit();
                    const selected = protocol.selectExactBase(parsed.value) catch {
                        return alloc.dupe(u8, "This endpoint has no eip155:8453 exact option. x402_fetch only pays Base USDC.");
                    };
                    var price_buf: [32]u8 = undefined;
                    const price = protocol.formatUsdcSlice(selected.amount_atomic, &price_buf);
                    return std.fmt.allocPrint(alloc, "HTTP 402 quote: {s} USDC on {s}. Next: x402_fetch.", .{ price, protocol.supported_network });
                }
                return alloc.dupe(u8, "HTTP 402 without PAYMENT-REQUIRED. Cannot quote.");
            }
            const preview_len = @min(failure.body.len, 512);
            return std.fmt.allocPrint(
                alloc,
                "HTTP {d}. {s} Call x402_check on this URL before retrying.",
                .{ if (failure.status) |status| @intFromEnum(status) else 0, failure.body[0..preview_len] },
            );
        },
        .cross_host_redirect => |target| return std.fmt.allocPrint(
            alloc,
            "This URL redirects to another host: {s}. Call x402_check and x402_fetch on that URL instead.",
            .{target},
        ),
    }
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}
