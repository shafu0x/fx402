const std = @import("std");
const http_fetch = @import("../web/http_fetch.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const protocol = @import("protocol.zig");
const rpc = @import("rpc.zig");
const wallet = @import("wallet.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    pub fn deinit(_: *Input, _: Allocator) void {}
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_balance arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_balance arguments must be an object") };
    }
    if (parsed.value.object.count() != 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "x402_balance does not take fields") };
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{};
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = erased;
    return callWithTransport(ctx, http_fetch.defaultTransport());
}

pub fn callWithTransport(ctx: tool_dispatch.DispatchContext, transport: http_fetch.Transport) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const loaded = wallet.loadOrCreate(ctx.allocator) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_balance could not load the wallet: {s}", .{@errorName(err)}) };
    };
    const amount = rpc.usdcBalance(ctx.allocator, loaded.address, transport) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "x402_balance could not read Base USDC: {s}", .{@errorName(err)}) };
    };
    var price_buf: [32]u8 = undefined;
    const usdc = protocol.formatUsdcSlice(amount, &price_buf);
    const address = loaded.addressHex();
    return .{ .success = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"address\":\"{s}\",\"usdc\":\"{s}\",\"network\":\"{s}\"}}",
        .{ address, usdc, protocol.supported_network },
    ) };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}
