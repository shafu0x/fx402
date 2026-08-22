const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");

const Keccak256 = std.crypto.hash.sha3.Keccak256;
const Secp256k1 = std.crypto.ecc.Secp256k1;

const field_order: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
const half_order: u256 = field_order / 2;

pub const eip712_domain_typehash = comptimeKeccak("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
pub const transfer_with_authorization_typehash = comptimeKeccak("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

pub const Signature = struct {
    bytes: [65]u8,

    pub fn hex(self: Signature) [132]u8 {
        var out: [132]u8 = undefined;
        out[0] = '0';
        out[1] = 'x';
        const encoded = std.fmt.bytesToHex(self.bytes, .lower);
        @memcpy(out[2..], &encoded);
        return out;
    }
};

pub fn keccak256(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Keccak256.hash(bytes, &out, .{});
    return out;
}

pub fn generateSecret() [32]u8 {
    var secret: [32]u8 = undefined;
    while (true) {
        io_mod.getIo().random(&secret);
        const value = intFromBytes(secret);
        if (value != 0 and value < field_order) return secret;
    }
}

pub fn addressFromSecret(secret: [32]u8) ![20]u8 {
    const point = try Secp256k1.basePoint.mul(secret, .big);
    const uncompressed = point.toUncompressedSec1();
    const hash = keccak256(uncompressed[1..]);
    var address: [20]u8 = undefined;
    @memcpy(&address, hash[12..]);
    return address;
}

pub fn formatAddress(address: [20]u8) [42]u8 {
    var out: [42]u8 = undefined;
    out[0] = '0';
    out[1] = 'x';
    const encoded = std.fmt.bytesToHex(address, .lower);
    @memcpy(out[2..], &encoded);
    return out;
}

pub fn parseAddress(text: []const u8) ![20]u8 {
    const hex_text = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        text[2..]
    else
        text;
    if (hex_text.len != 40) return error.InvalidAddress;
    var address: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&address, hex_text) catch return error.InvalidAddress;
    return address;
}

pub fn parseHex32(text: []const u8) ![32]u8 {
    const hex_text = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        text[2..]
    else
        text;
    if (hex_text.len != 64) return error.InvalidHex;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex_text) catch return error.InvalidHex;
    return out;
}

pub const Authorization = struct {
    from: [20]u8,
    to: [20]u8,
    value: u256,
    valid_after: u256,
    valid_before: u256,
    nonce: [32]u8,
};

pub fn signTransferWithAuthorization(
    secret: [32]u8,
    name: []const u8,
    version: []const u8,
    chain_id: u256,
    verifying_contract: [20]u8,
    authorization: Authorization,
) !Signature {
    const digest = transferWithAuthorizationDigest(name, version, chain_id, verifying_contract, authorization);
    return signDigest(secret, digest);
}

pub fn transferWithAuthorizationDigest(
    name: []const u8,
    version: []const u8,
    chain_id: u256,
    verifying_contract: [20]u8,
    authorization: Authorization,
) [32]u8 {
    const domain = domainSeparator(name, version, chain_id, verifying_contract);
    const struct_hash = structHash(authorization);
    var encoded: [66]u8 = undefined;
    encoded[0] = 0x19;
    encoded[1] = 0x01;
    @memcpy(encoded[2..34], &domain);
    @memcpy(encoded[34..66], &struct_hash);
    return keccak256(&encoded);
}

fn domainSeparator(name: []const u8, version: []const u8, chain_id: u256, verifying_contract: [20]u8) [32]u8 {
    var encoded: [160]u8 = undefined;
    @memcpy(encoded[0..32], &eip712_domain_typehash);
    @memcpy(encoded[32..64], &keccak256(name));
    @memcpy(encoded[64..96], &keccak256(version));
    writeU256(encoded[96..128], chain_id);
    writeAddress(encoded[128..160], verifying_contract);
    return keccak256(&encoded);
}

fn structHash(authorization: Authorization) [32]u8 {
    var encoded: [224]u8 = undefined;
    @memcpy(encoded[0..32], &transfer_with_authorization_typehash);
    writeAddress(encoded[32..64], authorization.from);
    writeAddress(encoded[64..96], authorization.to);
    writeU256(encoded[96..128], authorization.value);
    writeU256(encoded[128..160], authorization.valid_after);
    writeU256(encoded[160..192], authorization.valid_before);
    @memcpy(encoded[192..224], &authorization.nonce);
    return keccak256(&encoded);
}

fn signDigest(secret: [32]u8, digest: [32]u8) !Signature {
    const z = intFromBytes(digest);
    const d = intFromBytes(secret);
    if (d == 0 or d >= field_order) return error.InvalidSecret;

    var k_bytes: [32]u8 = undefined;
    var r_bytes: [32]u8 = undefined;
    var rec_id: u8 = 0;
    var s_value: u256 = 0;
    while (true) {
        io_mod.getIo().random(&k_bytes);
        const k = intFromBytes(k_bytes);
        if (k == 0 or k >= field_order) continue;

        const point = Secp256k1.basePoint.mul(k_bytes, .big) catch continue;
        const affine = point.affineCoordinates();
        const rx = intFromBytes(affine.x.toBytes(.big));
        if (rx == 0 or rx >= field_order) continue;

        const s = mulMod(invMod(k), addMod(z, mulMod(rx, d)));
        if (s == 0) continue;

        s_value = if (s > half_order) field_order - s else s;
        rec_id = @intFromBool(affine.y.isOdd());
        if (s > half_order) rec_id ^= 1;
        writeU256(&r_bytes, rx);
        break;
    }

    var signature: Signature = .{ .bytes = undefined };
    @memcpy(signature.bytes[0..32], &r_bytes);
    writeU256(signature.bytes[32..64], s_value);
    signature.bytes[64] = 27 + rec_id;
    return signature;
}

fn writeAddress(out: []u8, address: [20]u8) void {
    @memset(out[0..12], 0);
    @memcpy(out[12..32], &address);
}

fn writeU256(out: []u8, value: u256) void {
    std.mem.writeInt(u256, out[0..32], value, .big);
}

fn intFromBytes(bytes: [32]u8) u256 {
    return std.mem.readInt(u256, &bytes, .big);
}

fn addMod(a: u256, b: u256) u256 {
    return @intCast((@as(u512, a) + b) % field_order);
}

fn mulMod(a: u256, b: u256) u256 {
    return @intCast((@as(u512, a) * b) % field_order);
}

fn invMod(a: u256) u256 {
    return powMod(a, field_order - 2);
}

fn powMod(base: u256, exp: u256) u256 {
    var result: u256 = 1;
    var b = base % field_order;
    var e = exp;
    while (e != 0) {
        if (e & 1 == 1) result = mulMod(result, b);
        b = mulMod(b, b);
        e >>= 1;
    }
    return result;
}

fn comptimeKeccak(text: []const u8) [32]u8 {
    @setEvalBranchQuota(10000);
    var out: [32]u8 = undefined;
    Keccak256.hash(text, &out, .{});
    return out;
}

test "anvil zero key derives the documented address" {
    const secret = try parseHex32("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
    const address = try addressFromSecret(secret);
    try std.testing.expectEqualStrings(
        "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
        &formatAddress(address),
    );
}

test "eip712 typehashes match keccak of canonical type strings" {
    try std.testing.expectEqual(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        eip712_domain_typehash,
    );
    try std.testing.expectEqual(
        keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"),
        transfer_with_authorization_typehash,
    );
}

test "eip712 transfer digest is stable for a fixture vector" {
    const secret = try parseHex32("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
    const from = try addressFromSecret(secret);
    const to = try parseAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
    var nonce: [32]u8 = undefined;
    @memset(&nonce, 7);
    const digest = transferWithAuthorizationDigest(
        "USD Coin",
        "2",
        8453,
        to,
        .{
            .from = from,
            .to = to,
            .value = 10000,
            .valid_after = 1,
            .valid_before = 2,
            .nonce = nonce,
        },
    );
    try std.testing.expectEqualStrings(
        "1dab455d36b4e7a68d5308917ee3025029ad69f382ea61ca7e78e5ae8206da19",
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "signTransferWithAuthorization produces a 65-byte recoverable signature" {
    const secret = try parseHex32("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
    const from = try addressFromSecret(secret);
    const to = try parseAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
    var nonce: [32]u8 = undefined;
    @memset(&nonce, 7);
    const signature = try signTransferWithAuthorization(
        secret,
        "USD Coin",
        "2",
        8453,
        to,
        .{
            .from = from,
            .to = to,
            .value = 10000,
            .valid_after = 1,
            .valid_before = 2,
            .nonce = nonce,
        },
    );
    try std.testing.expect(signature.bytes[64] == 27 or signature.bytes[64] == 28);
}
