const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const crypto = @import("crypto.zig");

const Allocator = std.mem.Allocator;

const wallet_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const Wallet = struct {
    secret: [32]u8,
    address: [20]u8,

    pub fn addressHex(self: Wallet) [42]u8 {
        return crypto.formatAddress(self.address);
    }
};

pub fn ensureWallet(alloc: Allocator, home: []const u8) !Wallet {
    const path = try profile_paths.walletPath(alloc, home);
    defer alloc.free(path);
    if (loadWalletFile(alloc, path)) |wallet| {
        return wallet;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    return createWalletFile(alloc, home, path);
}

pub var test_home: ?[]const u8 = null;

pub fn loadOrCreate(alloc: Allocator) !Wallet {
    const home = blk: {
        if (comptime builtin.is_test) {
            if (test_home) |override| break :blk override;
        }
        break :blk io_mod.getenv("HOME") orelse return error.HomeNotSet;
    };
    return ensureWallet(alloc, home);
}

fn loadWalletFile(alloc: Allocator, path: []const u8) !Wallet {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(text);
    return parseWalletJson(alloc, text);
}

fn parseWalletJson(alloc: Allocator, text: []const u8) !Wallet {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return error.InvalidWallet;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWallet;
    const key_value = parsed.value.object.get("privateKey") orelse return error.InvalidWallet;
    if (key_value != .string) return error.InvalidWallet;
    const secret = crypto.parseHex32(key_value.string) catch return error.InvalidWallet;
    const address = crypto.addressFromSecret(secret) catch return error.InvalidWallet;
    return .{ .secret = secret, .address = address };
}

fn createWalletFile(alloc: Allocator, home: []const u8, path: []const u8) !Wallet {
    const fx_dir = try profile_paths.rootDir(alloc, home);
    defer alloc.free(fx_dir);
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), fx_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const secret = crypto.generateSecret();
    const address = try crypto.addressFromSecret(secret);
    const address_hex = crypto.formatAddress(address);

    var secret_text: [66]u8 = undefined;
    secret_text[0] = '0';
    secret_text[1] = 'x';
    const encoded = std.fmt.bytesToHex(secret, .lower);
    @memcpy(secret_text[2..], &encoded);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"privateKey\":\"");
    try out.writer.writeAll(&secret_text);
    try out.writer.writeAll("\",\"address\":\"");
    try out.writer.writeAll(&address_hex);
    try out.writer.writeAll("\",\"createdAt\":");
    try out.writer.print("{d}", .{@divTrunc(@max(io_mod.milliTimestamp(), 0), 1000)});
    try out.writer.writeAll("}\n");
    const json = out.written();

    var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .exclusive = true,
        .permissions = wallet_file_permissions,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return loadWalletFile(alloc, path),
        else => return err,
    };
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), json);
    try file.sync(io_mod.getIo());
    return .{ .secret = secret, .address = address };
}

test "ensureWallet creates once and never overwrites" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const first = try ensureWallet(alloc, home);
    const second = try ensureWallet(alloc, home);
    try std.testing.expectEqual(first.secret, second.secret);
    try std.testing.expectEqual(first.address, second.address);

    const path = try profile_paths.walletPath(alloc, home);
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u64, 0o600), stat.permissions.toMode() & 0o777);
}
