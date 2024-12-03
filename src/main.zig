const std = @import("std");

const c = @import("c");

const err = @import("err.zig").handleResult;
const Error = @import("err.zig").Error;

pub const XrVersion = packed struct(u64) {
    patch: u32,
    minor: u16,
    major: u16,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

fn boundedStr(comptime len: comptime_int, str: [:0]const u8) ![len]u8 {
    var ret: [len]u8 = @splat(0);

    if (str.len > len) return error.OutOfMemory;
    @memcpy(ret[0..str.len], str);

    return ret;
}

const app_version: XrVersion = .{ .major = 0, .minor = 1, .patch = 0 };

pub fn enumerateExtensions(allocator: std.mem.Allocator, layer: ?[*:0]const u8, out: anytype) !void {
    var extension_count: u32 = 0;
    try err(c.xrEnumerateInstanceExtensionProperties(layer, 0, &extension_count, null));

    const raw_extensions = try allocator.alloc(c.XrExtensionProperties, extension_count);
    defer allocator.free(raw_extensions);
    @memset(raw_extensions, .{ .type = c.XR_TYPE_EXTENSION_PROPERTIES });

    try err(c.xrEnumerateInstanceExtensionProperties(layer, @intCast(raw_extensions.len), &extension_count, raw_extensions.ptr));
    // The second xrEnumerateInstanceExtensionProperties call may not always return the same value as the first call! it writes how many its used, so let's slice to that
    const extensions = raw_extensions[0..extension_count];

    if (extension_count == 0) return;

    if (layer) |api_layer|
        std.debug.print("API Layer {s} supports {d} extensions\n", .{ api_layer, extension_count })
    else
        std.debug.print("Runtime supports {d} extensions\n", .{extension_count});

    for (extensions, 0..) |extension, i| {
        try out.print(
            "\t[{d}] {s} (v{d})\n",
            .{
                i,
                std.mem.sliceTo(&extension.extensionName, 0),
                extension.extensionVersion,
            },
        );
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leak");
    const allocator = gpa.allocator();

    const out = std.io.getStdOut().writer();

    var layer_count: u32 = 0;
    try err(c.xrEnumerateApiLayerProperties(0, &layer_count, null));

    const raw_layers = try allocator.alloc(c.XrApiLayerProperties, layer_count);
    defer allocator.free(raw_layers);
    @memset(raw_layers, .{ .type = c.XR_TYPE_API_LAYER_PROPERTIES });

    try err(c.xrEnumerateApiLayerProperties(@intCast(raw_layers.len), &layer_count, raw_layers.ptr));
    // The second xrEnumerateApiLayerProperties call may not always return the same value as the first call! it writes how many its used, so let's slice to that
    const layers = raw_layers[0..layer_count];

    try out.print("{d} API layers are available\n\n", .{layer_count});
    for (layers, 0..) |layer, i| {
        const layer_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&layer.layerName)), 0);
        const layer_description = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&layer.description)), 0);
        const layer_spec_version: XrVersion = @bitCast(layer.specVersion);

        try out.print(
            "[{d}] {s} (v{d}, for OpenXR {}): {s}\n",
            .{
                i,
                layer_name,
                layer.layerVersion,
                layer_spec_version,
                layer_description,
            },
        );

        try enumerateExtensions(allocator, layer_name, out);

        try out.writeByte('\n');
    }

    try enumerateExtensions(allocator, null, out);

    const versions_to_try: []const XrVersion = &.{
        .{ .major = 1, .minor = 1, .patch = 0 },
        .{ .major = 1, .minor = 0, .patch = 0 },
    };
    var best_version: ?XrVersion = null;
    for (versions_to_try) |version| {
        var instance: c.XrInstance = null;

        err(c.xrCreateInstance(&.{
            .type = c.XR_TYPE_INSTANCE_CREATE_INFO,
            .applicationInfo = .{
                .apiVersion = @bitCast(version),
                .applicationName = try boundedStr(128, "xrinfo"),
                .applicationVersion = 0,
            },
        }, &instance)) catch |ret| {
            if (ret == Error.api_version_unsupported) {
                try out.print("API version {} is unsupported\n", .{version});

                continue;
            }

            return ret;
        };

        if (best_version == null) best_version = version;

        try out.print("API version {} is supported\n", .{version});

        try err(c.xrDestroyInstance(instance));
    }

    if (best_version == null) {
        try out.print("Could not create OpenXR instance for *any* version! Attempted {any}\n", .{versions_to_try});
        return;
    }

    var instance: c.XrInstance = undefined;
    try err(c.xrCreateInstance(&.{
        .type = c.XR_TYPE_INSTANCE_CREATE_INFO,
        .applicationInfo = .{
            .apiVersion = @bitCast(best_version.?),
            .applicationName = try boundedStr(128, "xrinfo"),
            .applicationVersion = 0,
        },
        .enabledExtensionCount = 1,
        // .enabledExtensionCount = 2,
        .enabledExtensionNames = @as([*]const [*:0]const u8, &.{
            "XR_MND_headless",
            // "XR_EXT_active_action_set_priority",
        }),
    }, &instance));

    var instanceProperties: c.XrInstanceProperties = .{ .type = c.XR_TYPE_INSTANCE_PROPERTIES };
    try err(c.xrGetInstanceProperties(instance, &instanceProperties));

    std.debug.print(
        "Created OpenXR instance {s} v{d}\n",
        .{
            std.mem.sliceTo(&instanceProperties.runtimeName, 0),
            @as(XrVersion, @bitCast(instanceProperties.runtimeVersion)),
        },
    );

    try err(c.xrDestroyInstance(instance));
}
