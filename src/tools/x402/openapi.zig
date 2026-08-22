const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_discover_endpoints: usize = 40;
pub const max_guidance_bytes: usize = 2000;

pub const Endpoint = struct {
    method: []const u8,
    path: []const u8,
    summary: []const u8,
    price_usdc: []const u8,
};

pub const DiscoverView = struct {
    origin: []const u8,
    endpoints: []Endpoint,
    truncated: bool,
    guidance: ?[]const u8,
};

pub fn collectEndpoints(alloc: Allocator, spec: std.json.Value, origin: []const u8, include_guidance: bool) !DiscoverView {
    if (spec != .object) return error.InvalidOpenApi;
    const paths = spec.object.get("paths") orelse return error.InvalidOpenApi;
    if (paths != .object) return error.InvalidOpenApi;

    var list: std.ArrayList(Endpoint) = .empty;
    errdefer list.deinit(alloc);
    var truncated = false;
    var it = paths.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        var methods = entry.value_ptr.object.iterator();
        while (methods.next()) |method_entry| {
            if (!isHttpMethod(method_entry.key_ptr.*)) continue;
            if (list.items.len >= max_discover_endpoints) {
                truncated = true;
                break;
            }
            const summary = operationSummary(method_entry.value_ptr.*);
            const price = operationPrice(alloc, method_entry.value_ptr.*) catch try alloc.dupe(u8, "unknown");
            try list.append(alloc, .{
                .method = try alloc.dupe(u8, upperMethod(method_entry.key_ptr.*)),
                .path = try alloc.dupe(u8, entry.key_ptr.*),
                .summary = try alloc.dupe(u8, summary),
                .price_usdc = price,
            });
        }
        if (truncated) break;
    }

    var guidance: ?[]const u8 = null;
    if (include_guidance) {
        if (spec.object.get("info")) |info| {
            if (info == .object) {
                const text = stringField(info, "x-guidance") orelse stringField(info, "guidance");
                if (text) |value| {
                    const clipped = if (value.len > max_guidance_bytes) value[0..max_guidance_bytes] else value;
                    guidance = try alloc.dupe(u8, clipped);
                }
            }
        }
    }

    return .{
        .origin = origin,
        .endpoints = try list.toOwnedSlice(alloc),
        .truncated = truncated,
        .guidance = guidance,
    };
}

/// A located operation plus the context needed to resolve local `$ref`
/// pointers and path-item level parameters.
pub const Operation = struct {
    root: std.json.Value,
    path_item: std.json.Value,
    value: std.json.Value,
    path: []const u8,
    method: []const u8,
};

pub fn findOperation(spec: std.json.Value, path: []const u8, method: ?[]const u8) ?Operation {
    if (spec != .object) return null;
    const paths = spec.object.get("paths") orelse return null;
    if (paths != .object) return null;

    if (paths.object.getEntry(path)) |entry| {
        if (operationIn(spec, entry.key_ptr.*, entry.value_ptr.*, method)) |found| return found;
    }
    var it = paths.object.iterator();
    while (it.next()) |entry| {
        if (!templateMatches(entry.key_ptr.*, path)) continue;
        if (operationIn(spec, entry.key_ptr.*, entry.value_ptr.*, method)) |found| return found;
    }
    return null;
}

/// Spec paths that differ from `path` in a single segment. Origins that write
/// placeholders as bare segments (`/airports/id/...`) cannot be matched by
/// template rules, so the caller offers these as suggestions instead.
pub fn candidatePaths(alloc: Allocator, spec: std.json.Value, path: []const u8, limit: usize) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    if (spec != .object) return list.toOwnedSlice(alloc);
    const paths = spec.object.get("paths") orelse return list.toOwnedSlice(alloc);
    if (paths != .object) return list.toOwnedSlice(alloc);
    var it = paths.object.iterator();
    while (it.next()) |entry| {
        if (list.items.len >= limit) break;
        if (!differsByOneSegment(entry.key_ptr.*, path)) continue;
        try list.append(alloc, entry.key_ptr.*);
    }
    return list.toOwnedSlice(alloc);
}

pub fn compactSchema(alloc: Allocator, operation: Operation) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\n");
    try writer.writeAll("  \"path\": ");
    try std.json.Stringify.value(operation.path, .{}, writer);
    try writer.writeAll(",\n  \"method\": ");
    try std.json.Stringify.value(operation.method, .{}, writer);
    try writer.writeAll(",\n  \"summary\": ");
    try std.json.Stringify.value(operationSummary(operation.value), .{}, writer);
    try writer.writeAll(",\n");
    const price = operationPrice(alloc, operation.value) catch try alloc.dupe(u8, "unknown");
    defer alloc.free(price);
    try writer.writeAll("  \"price_usdc\": ");
    try std.json.Stringify.value(price, .{}, writer);
    try writer.writeAll(",\n");
    try writeParamList(writer, operation, "path", "path_params");
    try writeParamList(writer, operation, "query", "query_params");
    const content_type = requestContentType(operation) orelse "application/json";
    try writer.writeAll("  \"content_type\": ");
    try std.json.Stringify.value(content_type, .{}, writer);
    try writer.writeAll(",\n");
    if (requiredFields(operation)) |fields| {
        try writer.writeAll("  \"required_fields\": [");
        for (fields, 0..) |field, i| {
            if (i != 0) try writer.writeAll(", ");
            try std.json.Stringify.value(field, .{}, writer);
        }
        try writer.writeAll("],\n");
    }
    if (exampleBody(operation)) |example| {
        try writer.writeAll("  \"example_body\": ");
        try std.json.Stringify.value(example, .{}, writer);
        try writer.writeAll("\n");
    } else {
        try writer.writeAll("  \"example_body\": null\n");
    }
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn operationIn(
    spec: std.json.Value,
    path: []const u8,
    path_item: std.json.Value,
    method: ?[]const u8,
) ?Operation {
    if (path_item != .object) return null;
    var it = path_item.object.iterator();
    while (it.next()) |entry| {
        const matches = if (method) |wanted|
            std.ascii.eqlIgnoreCase(entry.key_ptr.*, wanted)
        else
            isHttpMethod(entry.key_ptr.*);
        if (!matches) continue;
        return .{
            .root = spec,
            .path_item = path_item,
            .value = entry.value_ptr.*,
            .path = path,
            .method = upperMethod(entry.key_ptr.*),
        };
    }
    return null;
}

fn templateMatches(template: []const u8, path: []const u8) bool {
    var template_it = std.mem.splitScalar(u8, template, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    var saw_placeholder = false;
    while (true) {
        const template_segment = template_it.next();
        const path_segment = path_it.next();
        if (template_segment == null and path_segment == null) return saw_placeholder;
        if (template_segment == null or path_segment == null) return false;
        const wanted = template_segment.?;
        const actual = path_segment.?;
        if (wanted.len >= 2 and wanted[0] == '{' and wanted[wanted.len - 1] == '}') {
            if (actual.len == 0) return false;
            saw_placeholder = true;
            continue;
        }
        if (!std.mem.eql(u8, wanted, actual)) return false;
    }
}

fn differsByOneSegment(candidate: []const u8, path: []const u8) bool {
    var candidate_it = std.mem.splitScalar(u8, candidate, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    var differences: usize = 0;
    while (true) {
        const candidate_segment = candidate_it.next();
        const path_segment = path_it.next();
        if (candidate_segment == null and path_segment == null) return differences == 1;
        if (candidate_segment == null or path_segment == null) return false;
        if (std.mem.eql(u8, candidate_segment.?, path_segment.?)) continue;
        if (candidate_segment.?.len == 0 or path_segment.?.len == 0) return false;
        differences += 1;
        if (differences > 1) return false;
    }
}

const max_params = 25;
const max_param_text = 160;

fn writeParamList(
    writer: *std.Io.Writer,
    operation: Operation,
    location: []const u8,
    field_name: []const u8,
) !void {
    var count: usize = 0;
    var buf: [max_param_text]u8 = undefined;
    for ([_]std.json.Value{ operation.path_item, operation.value }) |holder| {
        if (holder != .object) continue;
        const declared = holder.object.get("parameters") orelse continue;
        if (declared != .array) continue;
        for (declared.array.items) |raw| {
            if (count >= max_params) break;
            const param = resolveRef(operation.root, raw);
            if (param != .object) continue;
            const in_value = stringField(param, "in") orelse continue;
            if (!std.mem.eql(u8, in_value, location)) continue;
            const name = stringField(param, "name") orelse continue;
            if (count == 0) {
                try writer.print("  \"{s}\": [", .{field_name});
            } else {
                try writer.writeAll(", ");
            }
            try std.json.Stringify.value(paramText(&buf, operation.root, param, name), .{}, writer);
            count += 1;
        }
    }
    if (count != 0) try writer.writeAll("],\n");
}

fn paramText(buf: []u8, root: std.json.Value, param: std.json.Value, name: []const u8) []const u8 {
    const schema = if (param.object.get("schema")) |raw| resolveRef(root, raw) else std.json.Value{ .null = {} };
    const type_name = stringField(schema, "type") orelse "string";
    const required = param.object.get("required") != null and
        param.object.get("required").? == .bool and
        param.object.get("required").?.bool;
    const head = std.fmt.bufPrint(buf, "{s} ({s}{s})", .{
        name,
        type_name,
        if (required) ", required" else "",
    }) catch return name;
    const description = stringField(param, "description") orelse return head;
    if (description.len == 0 or buf.len <= head.len + 2) return head;
    const room = buf.len - head.len - 2;
    const clipped = description[0..@min(description.len, room)];
    const tail = std.fmt.bufPrint(buf[head.len..], ": {s}", .{clipped}) catch return head;
    return buf[0 .. head.len + tail.len];
}

/// Follows local JSON pointers so `$ref`-heavy specs still yield fields.
fn resolveRef(root: std.json.Value, value: std.json.Value) std.json.Value {
    var current = value;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (current != .object) return current;
        const ref = stringField(current, "$ref") orelse return current;
        if (!std.mem.startsWith(u8, ref, "#/")) return current;
        var node = root;
        var it = std.mem.splitScalar(u8, ref[2..], '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            if (node != .object) return current;
            node = node.object.get(segment) orelse return current;
        }
        current = node;
    }
    return current;
}

fn requiredFields(operation: Operation) ?[]const std.json.Value {
    const schema = requestSchema(operation) orelse return null;
    if (schema != .object) return null;
    const required = schema.object.get("required") orelse return null;
    return if (required == .array) required.array.items else null;
}

fn exampleBody(operation: Operation) ?std.json.Value {
    const schema = requestSchema(operation) orelse return null;
    if (schema != .object) return null;
    return schema.object.get("example") orelse schema.object.get("examples");
}

fn requestSchema(operation: Operation) ?std.json.Value {
    if (operation.value != .object) return null;
    const body = resolveRef(operation.root, operation.value.object.get("requestBody") orelse return null);
    if (body != .object) return null;
    const content = body.object.get("content") orelse return null;
    if (content != .object) return null;
    const media = content.object.get("application/json") orelse blk: {
        var it = content.object.iterator();
        const first = it.next() orelse return null;
        break :blk first.value_ptr.*;
    };
    if (media != .object) return null;
    return resolveRef(operation.root, media.object.get("schema") orelse return null);
}

fn requestContentType(operation: Operation) ?[]const u8 {
    if (operation.value != .object) return null;
    const body = resolveRef(operation.root, operation.value.object.get("requestBody") orelse return null);
    if (body != .object) return null;
    const content = body.object.get("content") orelse return null;
    if (content != .object) return null;
    if (content.object.get("application/json") != null) return "application/json";
    var it = content.object.iterator();
    const first = it.next() orelse return null;
    return first.key_ptr.*;
}

fn operationSummary(operation: std.json.Value) []const u8 {
    return stringField(operation, "summary") orelse stringField(operation, "description") orelse "";
}

fn operationPrice(alloc: Allocator, operation: std.json.Value) ![]u8 {
    if (operation != .object) return error.NoPrice;
    const info = operation.object.get("x-payment-info") orelse return error.NoPrice;
    if (info != .object) return error.NoPrice;
    if (info.object.get("price")) |price| {
        switch (price) {
            .string => |text| return formatPriceText(alloc, text),
            .object => |obj| {
                if (obj.get("amount")) |amount| {
                    if (amount == .string) return formatPriceText(alloc, amount.string);
                }
            },
            else => {},
        }
    }
    if (info.object.get("amount")) |amount| {
        if (amount == .string) return formatPriceText(alloc, amount.string);
    }
    return error.NoPrice;
}

fn formatPriceText(alloc: Allocator, text: []const u8) ![]u8 {
    if (text.len > 0 and text[0] == '$') return alloc.dupe(u8, text);
    return std.fmt.allocPrint(alloc, "${s}", .{text});
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn isHttpMethod(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "get") or
        std.ascii.eqlIgnoreCase(name, "post") or
        std.ascii.eqlIgnoreCase(name, "put") or
        std.ascii.eqlIgnoreCase(name, "delete") or
        std.ascii.eqlIgnoreCase(name, "patch");
}

fn upperMethod(name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "get")) return "GET";
    if (std.ascii.eqlIgnoreCase(name, "post")) return "POST";
    if (std.ascii.eqlIgnoreCase(name, "put")) return "PUT";
    if (std.ascii.eqlIgnoreCase(name, "delete")) return "DELETE";
    if (std.ascii.eqlIgnoreCase(name, "patch")) return "PATCH";
    return name;
}

test "collectEndpoints reads x-payment-info prices" {
    const alloc = std.testing.allocator;
    const json =
        \\{"openapi":"3.1.0","info":{"title":"t","x-guidance":"use check then fetch"},"paths":{"/api/exa/search":{"post":{"summary":"Exa search","x-payment-info":{"price":{"mode":"fixed","currency":"USD","amount":"0.01"}}}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const view = try collectEndpoints(alloc, parsed.value, "https://stableenrich.dev", true);
    defer {
        for (view.endpoints) |endpoint| {
            alloc.free(endpoint.method);
            alloc.free(endpoint.path);
            alloc.free(endpoint.summary);
            alloc.free(endpoint.price_usdc);
        }
        alloc.free(view.endpoints);
        if (view.guidance) |guidance| alloc.free(guidance);
    }
    try std.testing.expectEqual(@as(usize, 1), view.endpoints.len);
    try std.testing.expectEqualStrings("POST", view.endpoints[0].method);
    try std.testing.expectEqualStrings("/api/exa/search", view.endpoints[0].path);
    try std.testing.expectEqualStrings("$0.01", view.endpoints[0].price_usdc);
    try std.testing.expectEqualStrings("use check then fetch", view.guidance.?);
}

test "compactSchema returns required fields and human price" {
    const alloc = std.testing.allocator;
    const json =
        \\{"paths":{"/api/exa/search":{"post":{"summary":"Exa search","x-payment-info":{"price":{"amount":"0.01"}},"requestBody":{"content":{"application/json":{"schema":{"type":"object","required":["query"],"example":{"query":"fx"}}}}}}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const operation = findOperation(parsed.value, "/api/exa/search", "POST").?;
    const text = try compactSchema(alloc, operation);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "$0.01") != null);
    try std.testing.expect(std.mem.find(u8, text, "query") != null);
    try std.testing.expect(std.mem.find(u8, text, "application/json") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"POST\"") != null);
}

test "compactSchema lists query parameters for GET routes" {
    const alloc = std.testing.allocator;
    const json =
        \\{"paths":{"/tweets/search":{"get":{"summary":"Search tweets","x-payment-info":{"price":{"amount":"0.006"}},"parameters":[{"name":"words","in":"query","required":true,"description":"Search keyword","schema":{"type":"string"}},{"$ref":"#/components/parameters/Cursor"}]}}},"components":{"parameters":{"Cursor":{"name":"next_token","in":"query","schema":{"type":"string"}}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const operation = findOperation(parsed.value, "/tweets/search", null).?;
    const text = try compactSchema(alloc, operation);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "words (string, required): Search keyword") != null);
    try std.testing.expect(std.mem.find(u8, text, "next_token (string)") != null);
    try std.testing.expect(std.mem.find(u8, text, "$0.006") != null);
}

test "findOperation matches templated paths and shares path item parameters" {
    const alloc = std.testing.allocator;
    const json =
        \\{"paths":{"/airports/{id}/weather":{"parameters":[{"name":"id","in":"path","required":true,"schema":{"type":"string"}}],"get":{"summary":"Weather"}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const operation = findOperation(parsed.value, "/airports/KJFK/weather", "GET").?;
    try std.testing.expectEqualStrings("/airports/{id}/weather", operation.path);
    const text = try compactSchema(alloc, operation);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "id (string, required)") != null);
    try std.testing.expect(findOperation(parsed.value, "/airports/KJFK/runways", "GET") == null);
}

test "candidatePaths suggests bare placeholder segments" {
    const alloc = std.testing.allocator;
    const json =
        \\{"paths":{"/airports/id/weather":{"get":{}},"/airports/id/flights":{"get":{}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expect(findOperation(parsed.value, "/airports/KJFK/weather", "GET") == null);
    const candidates = try candidatePaths(alloc, parsed.value, "/airports/KJFK/weather", 5);
    defer alloc.free(candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("/airports/id/weather", candidates[0]);
}
