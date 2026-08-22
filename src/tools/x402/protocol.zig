const std = @import("std");
const crypto = @import("crypto.zig");

const Allocator = std.mem.Allocator;

pub const supported_network = "eip155:8453";
pub const supported_scheme = "exact";
pub const usdc_address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
pub const usdc_decimals: u32 = 6;

pub const SelectedPayment = struct {
    amount_atomic: u256,
    pay_to: [20]u8,
    asset: [20]u8,
    max_timeout_seconds: u64,
    extra_name: []const u8,
    extra_version: []const u8,
    accepted: std.json.Value,
    resource: std.json.Value,
    extensions: ?std.json.Value,
    x402_version: i64,
};

pub fn decodePaymentRequired(alloc: Allocator, header: []const u8) !std.json.Parsed(std.json.Value) {
    const json_bytes = try decodeBase64Json(alloc, header);
    defer alloc.free(json_bytes);
    return std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
}

pub fn selectExactBase(parsed: std.json.Value) !SelectedPayment {
    if (parsed != .object) return error.InvalidPaymentRequired;
    const version = parsed.object.get("x402Version") orelse return error.InvalidPaymentRequired;
    if (version != .integer or version.integer != 2) return error.UnsupportedX402Version;
    const accepts = parsed.object.get("accepts") orelse return error.InvalidPaymentRequired;
    if (accepts != .array) return error.InvalidPaymentRequired;
    const resource = parsed.object.get("resource") orelse return error.InvalidPaymentRequired;

    for (accepts.array.items) |item| {
        if (item != .object) continue;
        const scheme = stringField(item, "scheme") orelse continue;
        const network = stringField(item, "network") orelse continue;
        if (!std.mem.eql(u8, scheme, supported_scheme)) continue;
        if (!std.mem.eql(u8, network, supported_network)) continue;
        const amount_text = stringField(item, "amount") orelse continue;
        const pay_to_text = stringField(item, "payTo") orelse continue;
        const asset_text = stringField(item, "asset") orelse continue;
        const extra = item.object.get("extra") orelse return error.MissingEip712Domain;
        if (extra != .object) return error.MissingEip712Domain;
        const extra_name = stringField(extra, "name") orelse return error.MissingEip712Domain;
        const extra_version = stringField(extra, "version") orelse return error.MissingEip712Domain;
        const timeout_value = item.object.get("maxTimeoutSeconds") orelse return error.InvalidPaymentRequired;
        const timeout: u64 = switch (timeout_value) {
            .integer => |n| if (n < 0) return error.InvalidPaymentRequired else @intCast(n),
            else => return error.InvalidPaymentRequired,
        };
        return .{
            .amount_atomic = parseAtomic(amount_text) catch return error.InvalidPaymentRequired,
            .pay_to = crypto.parseAddress(pay_to_text) catch return error.InvalidPaymentRequired,
            .asset = crypto.parseAddress(asset_text) catch return error.InvalidPaymentRequired,
            .max_timeout_seconds = timeout,
            .extra_name = extra_name,
            .extra_version = extra_version,
            .accepted = item,
            .resource = resource,
            .extensions = parsed.object.get("extensions"),
            .x402_version = 2,
        };
    }
    return error.NoSupportedPaymentOption;
}

pub fn encodePaymentSignature(
    alloc: Allocator,
    selected: SelectedPayment,
    from: [20]u8,
    authorization: crypto.Authorization,
    signature: crypto.Signature,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"x402Version\":2,\"resource\":");
    try std.json.Stringify.value(selected.resource, .{}, writer);
    try writer.writeAll(",\"accepted\":");
    try std.json.Stringify.value(selected.accepted, .{}, writer);
    try writer.writeAll(",\"payload\":{\"signature\":\"");
    try writer.writeAll(&signature.hex());
    try writer.writeAll("\",\"authorization\":{");
    try writeAuthField(writer, "from", &crypto.formatAddress(from));
    try writer.writeAll(",");
    try writeAuthField(writer, "to", &crypto.formatAddress(authorization.to));
    try writer.writeAll(",");
    try writeAuthUint(writer, "value", authorization.value);
    try writer.writeAll(",");
    try writeAuthUint(writer, "validAfter", authorization.valid_after);
    try writer.writeAll(",");
    try writeAuthUint(writer, "validBefore", authorization.valid_before);
    try writer.writeAll(",\"nonce\":\"");
    var nonce_hex: [66]u8 = undefined;
    nonce_hex[0] = '0';
    nonce_hex[1] = 'x';
    const nonce_digits = std.fmt.bytesToHex(authorization.nonce, .lower);
    @memcpy(nonce_hex[2..], &nonce_digits);
    try writer.writeAll(&nonce_hex);
    try writer.writeAll("\"}}");
    if (selected.extensions) |extensions| {
        try writer.writeAll(",\"extensions\":");
        try std.json.Stringify.value(extensions, .{}, writer);
    }
    try writer.writeByte('}');
    const json = try out.toOwnedSlice();
    defer alloc.free(json);
    return encodeBase64(alloc, json);
}

/// Keeps every significant digit down to the 1e-6 USDC floor so sub-cent
/// prices stay distinguishable in spend prompts.
pub fn formatUsdcSlice(amount_atomic: u256, buf: *[32]u8) []const u8 {
    const whole = amount_atomic / 1_000_000;
    const frac: u32 = @intCast(amount_atomic % 1_000_000);
    var digits: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{frac}) catch return "$?";
    var len: usize = digits.len;
    while (len > 2 and digits[len - 1] == '0') len -= 1;
    return std.fmt.bufPrint(buf, "${d}.{s}", .{ whole, digits[0..len] }) catch "$?";
}

pub fn paymentRequiredHint(alloc: Allocator, header: []const u8) ![]u8 {
    var parsed = decodePaymentRequired(alloc, header) catch {
        return alloc.dupe(u8, "web_fetch received HTTP 402. Retry with x402_fetch (do not retry web_fetch).");
    };
    defer parsed.deinit();
    const selected = selectExactBase(parsed.value) catch {
        return alloc.dupe(
            u8,
            "web_fetch received HTTP 402. This endpoint has no eip155:8453 exact option. x402_fetch only pays Base USDC.",
        );
    };
    var price_buf: [32]u8 = undefined;
    const price = formatUsdcSlice(selected.amount_atomic, &price_buf);
    return std.fmt.allocPrint(
        alloc,
        "web_fetch received HTTP 402 Payment Required ({s} USDC on {s}). Retry with x402_fetch (do not retry web_fetch).",
        .{ price, supported_network },
    );
}

fn writeAuthField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print("\"{s}\":\"{s}\"", .{ name, value });
}

fn writeAuthUint(writer: *std.Io.Writer, name: []const u8, value: u256) !void {
    try writer.print("\"{s}\":\"{d}\"", .{ name, value });
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn parseAtomic(text: []const u8) !u256 {
    var value: u256 = 0;
    if (text.len == 0) return error.InvalidAmount;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidAmount;
        value = value * 10 + (byte - '0');
    }
    return value;
}

fn decodeBase64Json(alloc: Allocator, header: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(header) catch return error.InvalidPaymentRequired;
    const out = try alloc.alloc(u8, size);
    errdefer alloc.free(out);
    decoder.decode(out, header) catch return error.InvalidPaymentRequired;
    return out;
}

fn encodeBase64(alloc: Allocator, json: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, encoder.calcSize(json.len));
    _ = encoder.encode(out, json);
    return out;
}

test "selectExactBase ignores solana accepts" {
    const alloc = std.testing.allocator;
    const json =
        \\{"x402Version":2,"resource":{"url":"https://example.com/x","description":"d","mimeType":"application/json"},"accepts":[{"scheme":"exact","network":"solana:mainnet","asset":"usdc","amount":"1","payTo":"So111","maxTimeoutSeconds":60,"extra":{"name":"USDC","version":"2"}},{"scheme":"exact","network":"eip155:8453","asset":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","amount":"10000","payTo":"0x1111111111111111111111111111111111111111","maxTimeoutSeconds":60,"extra":{"name":"USD Coin","version":"2"}}]}
    ;
    const encoded = try encodeBase64(alloc, json);
    defer alloc.free(encoded);
    var parsed = try decodePaymentRequired(alloc, encoded);
    defer parsed.deinit();
    const selected = try selectExactBase(parsed.value);
    try std.testing.expectEqual(@as(u256, 10000), selected.amount_atomic);
    try std.testing.expectEqualStrings("USD Coin", selected.extra_name);
}

test "formatUsdcSlice keeps sub-cent prices visible" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.006", formatUsdcSlice(6000, &buf));
    try std.testing.expectEqualStrings("$0.004", formatUsdcSlice(4000, &buf));
    try std.testing.expectEqualStrings("$0.000001", formatUsdcSlice(1, &buf));
    try std.testing.expectEqualStrings("$0.01", formatUsdcSlice(10000, &buf));
    try std.testing.expectEqualStrings("$2.00", formatUsdcSlice(2_000_000, &buf));
    try std.testing.expectEqualStrings("$0.00", formatUsdcSlice(0, &buf));
    try std.testing.expectEqualStrings("$1.2345", formatUsdcSlice(1_234_500, &buf));
}

test "selectExactBase fails when only solana is offered" {
    const alloc = std.testing.allocator;
    const json =
        \\{"x402Version":2,"resource":{"url":"https://example.com/x","description":"d","mimeType":"application/json"},"accepts":[{"scheme":"exact","network":"solana:mainnet","asset":"usdc","amount":"1","payTo":"So111","maxTimeoutSeconds":60,"extra":{"name":"USDC","version":"2"}}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.NoSupportedPaymentOption, selectExactBase(parsed.value));
}
