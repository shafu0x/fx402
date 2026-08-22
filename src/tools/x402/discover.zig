const std = @import("std");
const http_fetch = @import("../web/http_fetch.zig");
const url_policy = @import("../web/url_policy.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const http_util = @import("http_util.zig");
const openapi = @import("openapi.zig");

const Allocator = std.mem.Allocator;
const whitespace = " \t\r\n";

pub const Input = struct {
    origin_url: []u8,
    include_guidance: bool,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.origin_url);
        self.* = .{ .origin_url = &.{}, .include_guidance = false };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover arguments must be an object") };
    }
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "origin_url") or std.mem.eql(u8, entry.key_ptr.*, "include_guidance")) continue;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_discover field \"{s}\" is not allowed", .{entry.key_ptr.*}) };
    }
    const url_value = parsed.value.object.get("origin_url") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover field \"origin_url\" is required") };
    };
    if (url_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover field \"origin_url\" must be a string") };
    }
    var include_guidance = false;
    if (parsed.value.object.get("include_guidance")) |flag| {
        if (flag != .bool) {
            return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover field \"include_guidance\" must be a boolean") };
        }
        include_guidance = flag.bool;
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .origin_url = try ctx.allocator.dupe(u8, url_value.string),
        .include_guidance = include_guidance,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const trimmed = std.mem.trim(u8, input.origin_url, whitespace);
    if (!std.mem.eql(u8, input.origin_url, trimmed)) {
        const owned = try ctx.allocator.dupe(u8, trimmed);
        ctx.allocator.free(input.origin_url);
        input.origin_url = owned;
    }
    var normalized = url_policy.normalize(ctx.allocator, input.origin_url) catch {
        return try ctx.allocator.dupe(u8, "x402_discover origin_url must be a public HTTP(S) URL");
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
    const origin = http_util.originUrl(ctx.allocator, input.origin_url) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover origin_url must be a public HTTP(S) URL") };
    };
    defer ctx.allocator.free(origin);

    const spec_text = try http_util.fetchDiscoveryDocument(ctx.allocator, origin, transport) orelse {
        return .{ .success = try std.fmt.allocPrint(
            ctx.allocator,
            "No discovery document at {s}/openapi.json or {s}/.well-known/x402. If you already know the exact URL, call x402_fetch; otherwise pick another origin.",
            .{ origin, origin },
        ) };
    };
    defer ctx.allocator.free(spec_text);

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, spec_text, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover received an unparseable OpenAPI document") };
    };
    defer parsed.deinit();

    const view = openapi.collectEndpoints(ctx.allocator, parsed.value, origin, input.include_guidance) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover could not read paths from the OpenAPI document") };
    };
    defer {
        for (view.endpoints) |endpoint| {
            ctx.allocator.free(endpoint.method);
            ctx.allocator.free(endpoint.path);
            ctx.allocator.free(endpoint.summary);
            ctx.allocator.free(endpoint.price_usdc);
        }
        ctx.allocator.free(view.endpoints);
        if (view.guidance) |guidance| ctx.allocator.free(guidance);
    }

    const rendered = renderDiscover(ctx.allocator, view) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "x402_discover could not render the endpoint list") },
    };
    return .{ .success = rendered };
}

fn renderDiscover(alloc: Allocator, view: openapi.DiscoverView) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("origin: {s}\nendpoints:\n", .{view.origin});
    for (view.endpoints) |endpoint| {
        try writer.print("- {s} {s}  {s}  {s}\n", .{ endpoint.method, endpoint.path, endpoint.price_usdc, endpoint.summary });
    }
    if (view.truncated) {
        try writer.writeAll("list truncated after 40 endpoints; call x402_check on a specific path\n");
    }
    if (view.guidance) |guidance| {
        try writer.writeAll("guidance:\n");
        try writer.writeAll(guidance);
        try writer.writeByte('\n');
    }
    try writer.writeAll("Next: x402_check on one endpoint_url, then x402_fetch. Skipping check is why 400s happen.\n");
    return out.toOwnedSlice();
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}
