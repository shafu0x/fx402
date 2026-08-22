const std = @import("std");
const http_fetch = @import("../web/http_fetch.zig");
const url_policy = @import("../web/url_policy.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    method: []const u8 = "GET",
    body: ?[]const u8 = null,
    extra_headers: []const http_fetch.ExtraHeader = &.{},
};

pub fn fetchUrl(
    alloc: Allocator,
    url: []const u8,
    request: Request,
    transport: http_fetch.Transport,
) !http_fetch.Result {
    var target = try url_policy.normalize(alloc, url);
    defer target.deinit(alloc);
    return http_fetch.fetch(alloc, target, .{
        .method = request.method,
        .body = request.body,
        .extra_headers = request.extra_headers,
    }, transport);
}

pub fn originUrl(alloc: Allocator, url: []const u8) ![]u8 {
    var target = try url_policy.normalize(alloc, url);
    defer target.deinit(alloc);
    const scheme = switch (target.scheme) {
        .http => "http",
        .https => "https",
    };
    if (target.explicit_port) |port| {
        return std.fmt.allocPrint(alloc, "{s}://{s}:{d}", .{ scheme, target.canonical_host, port });
    }
    return std.fmt.allocPrint(alloc, "{s}://{s}", .{ scheme, target.canonical_host });
}

pub fn fetchDiscoveryDocument(alloc: Allocator, origin: []const u8, transport: http_fetch.Transport) !?[]u8 {
    const paths = [_][]const u8{ "/openapi.json", "/.well-known/x402" };
    for (paths) |path| {
        const url = try joinUrl(alloc, origin, path);
        defer alloc.free(url);
        var result = fetchUrl(alloc, url, .{}, transport) catch continue;
        defer result.deinit(alloc);
        switch (result) {
            .success => |success| {
                if (success.status.class() == .success and success.body.len > 0) {
                    return try alloc.dupe(u8, success.body);
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn pathOnly(path_query: []const u8) []const u8 {
    if (std.mem.findScalar(u8, path_query, '?')) |index| return path_query[0..index];
    return path_query;
}

pub fn headersFromObject(alloc: Allocator, value: std.json.Value) ![]http_fetch.ExtraHeader {
    if (value != .object) return error.InvalidHeaders;
    var list: std.ArrayList(http_fetch.ExtraHeader) = .empty;
    errdefer {
        for (list.items) |header| {
            alloc.free(header.name);
            alloc.free(header.value);
        }
        list.deinit(alloc);
    }
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidHeaders;
        try list.append(alloc, .{
            .name = try alloc.dupe(u8, entry.key_ptr.*),
            .value = try alloc.dupe(u8, entry.value_ptr.string),
        });
    }
    return list.toOwnedSlice(alloc);
}

pub fn freeHeaders(alloc: Allocator, headers: []http_fetch.ExtraHeader) void {
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    alloc.free(headers);
}

pub fn joinUrl(alloc: Allocator, origin: []const u8, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, origin, "/");
    if (path.len == 0 or path[0] == '/') {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ trimmed, path });
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimmed, path });
}
