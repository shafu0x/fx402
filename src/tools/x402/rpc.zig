const std = @import("std");
const http_fetch = @import("../web/http_fetch.zig");
const http_util = @import("http_util.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const base_rpc_url = "https://mainnet.base.org";

pub fn usdcBalance(
    alloc: Allocator,
    address: [20]u8,
    transport: http_fetch.Transport,
) !u256 {
    var data: [74]u8 = undefined;
    @memcpy(data[0..10], "0x70a08231");
    @memset(data[10..34], '0');
    const addr_hex = std.fmt.bytesToHex(address, .lower);
    @memcpy(data[34..74], &addr_hex);

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"");
    try body.writer.writeAll(protocol.usdc_address);
    try body.writer.writeAll("\",\"data\":\"");
    try body.writer.writeAll(&data);
    try body.writer.writeAll("\"},\"latest\"]}");

    var result = try http_util.fetchUrl(alloc, base_rpc_url, .{
        .method = "POST",
        .body = body.written(),
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
    }, transport);
    defer result.deinit(alloc);
    const success = switch (result) {
        .success => |s| s,
        else => return error.RpcFailed,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, success.body, .{}) catch return error.RpcFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.RpcFailed;
    const value = parsed.value.object.get("result") orelse return error.RpcFailed;
    if (value != .string) return error.RpcFailed;
    return parseHexU256(value.string);
}

fn parseHexU256(text: []const u8) !u256 {
    const hex_text = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        text[2..]
    else
        text;
    if (hex_text.len == 0 or hex_text.len > 64) return error.RpcFailed;
    var padded: [64]u8 = undefined;
    @memset(&padded, '0');
    @memcpy(padded[64 - hex_text.len ..], hex_text);
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, &padded) catch return error.RpcFailed;
    return std.mem.readInt(u256, &bytes, .big);
}

test "parseHexU256 reads atomic USDC amounts" {
    try std.testing.expectEqual(@as(u256, 10000), try parseHexU256("0x2710"));
    try std.testing.expectEqual(@as(u256, 0), try parseHexU256("0x0"));
}
