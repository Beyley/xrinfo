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

fn findOutputFromChain(comptime T: type, xr_type: c.XrStructureType, ptr: ?*anyopaque) ?*T {
    var iter: ?*c.XrBaseOutStructure = @alignCast(@ptrCast(ptr));
    while (iter) |base| {
        if (base.type == xr_type)
            return @ptrCast(iter);

        iter = base.next;
    }
    return null;
}

fn addOutputToChain(chain: *anyopaque, ptr: *anyopaque) void {
    var last: *c.XrBaseOutStructure = @alignCast(@ptrCast(chain));
    var iter: ?*c.XrBaseOutStructure = last;
    while (iter) |base| {
        last = iter.?;
        iter = base.next;
    }
    last.next = @alignCast(@ptrCast(ptr));
}

fn boundedStr(comptime len: comptime_int, str: [:0]const u8) ![len]u8 {
    var ret: [len]u8 = @splat(0);

    if (str.len > len) return error.OutOfMemory;
    @memcpy(ret[0..str.len], str);

    return ret;
}

const app_version: XrVersion = .{ .major = 0, .minor = 1, .patch = 0 };

pub fn enumerateExtensions(allocator: std.mem.Allocator, layer: ?[*:0]const u8, writer: anytype) ![]c.XrExtensionProperties {
    var extension_count: u32 = 0;
    try err(c.xrEnumerateInstanceExtensionProperties(layer, 0, &extension_count, null));

    const raw_extensions = try allocator.alloc(c.XrExtensionProperties, extension_count);
    defer allocator.free(raw_extensions);
    @memset(raw_extensions, .{ .type = c.XR_TYPE_EXTENSION_PROPERTIES });

    try err(c.xrEnumerateInstanceExtensionProperties(layer, @intCast(raw_extensions.len), &extension_count, raw_extensions.ptr));
    // The second xrEnumerateInstanceExtensionProperties call may not always return the same value as the first call! it writes how many its used, so let's slice to that
    const extensions = raw_extensions[0..extension_count];

    if (extension_count == 0) return &.{};

    if (layer) |api_layer|
        std.debug.print("API Layer {s} supports {d} extensions\n", .{ api_layer, extension_count })
    else
        std.debug.print("Runtime supports {d} extensions\n", .{extension_count});

    for (extensions, 0..) |extension, i| {
        try writer.print(
            "\t[{d}] {s} (v{d})\n",
            .{
                i,
                std.mem.sliceTo(&extension.extensionName, 0),
                extension.extensionVersion,
            },
        );
    }

    return allocator.dupe(c.XrExtensionProperties, extensions);
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

        allocator.free(try enumerateExtensions(allocator, layer_name, out));

        try out.writeByte('\n');
    }

    const supported_extensions = try enumerateExtensions(allocator, null, out);
    defer allocator.free(supported_extensions);

    // api version check
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

    var enabled_extensions = std.ArrayList([*:0]const u8).init(allocator);
    defer enabled_extensions.deinit();

    var xdev_space = false;
    for (supported_extensions) |*supported_extension| {
        const extension_name = std.mem.sliceTo(&supported_extension.extensionName, 0);

        // We can get extra info from OpenXR using this extension, if we enable it
        if (std.mem.eql(u8, extension_name, c.XR_MNDX_XDEV_SPACE_EXTENSION_NAME)) {
            try enabled_extensions.append(c.XR_MNDX_XDEV_SPACE_EXTENSION_NAME);
            xdev_space = true;
        }
    }

    var instance: c.XrInstance = undefined;
    try err(c.xrCreateInstance(&.{
        .type = c.XR_TYPE_INSTANCE_CREATE_INFO,
        .applicationInfo = .{
            .apiVersion = @bitCast(best_version.?),
            .applicationName = try boundedStr(128, "xrinfo"),
            .applicationVersion = 0,
        },
        .enabledExtensionCount = @intCast(enabled_extensions.items.len),
        .enabledExtensionNames = enabled_extensions.items.ptr,
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

    var system_id: c.XrSystemId = undefined;
    try err(c.xrGetSystem(instance, &.{
        .formFactor = c.XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY,
        .type = c.XR_TYPE_SYSTEM_GET_INFO,
    }, &system_id));

    var system_properties: c.XrSystemProperties = .{ .type = c.XR_TYPE_SYSTEM_PROPERTIES };

    if (xdev_space) {
        var xdev_space_properties: c.XrSystemXDevSpacePropertiesMNDX = .{ .type = c.XR_TYPE_SYSTEM_XDEV_SPACE_PROPERTIES_MNDX };
        addOutputToChain(&system_properties, &xdev_space_properties);
    }

    try err(c.xrGetSystemProperties(instance, system_id, &system_properties));

    std.debug.print("Got OpenXR system\n\tID: {d}\n\tName: {s}\n\tVendor ID: {d}\n", .{
        system_properties.systemId,
        std.mem.sliceTo(&system_properties.systemName, 0),
        system_properties.vendorId,
    });
    std.debug.print("System Graphics Properties:\n\tMax Layer Count: {d}\n\tMax Swapchain Image Width: {d}\n\tMax Swapchain Image Height: {d}\n", .{
        system_properties.graphicsProperties.maxLayerCount,
        system_properties.graphicsProperties.maxSwapchainImageWidth,
        system_properties.graphicsProperties.maxSwapchainImageHeight,
    });
    std.debug.print("System Tracking properties:\n\tOrientation Tracking: {}\n\tPosition Tracking: {}\n", .{
        system_properties.trackingProperties.orientationTracking != 0,
        system_properties.trackingProperties.positionTracking != 0,
    });

    if (findOutputFromChain(c.XrSystemXDevSpacePropertiesMNDX, c.XR_TYPE_SYSTEM_XDEV_SPACE_PROPERTIES_MNDX, &system_properties)) |mndx_space_properties| {
        std.debug.print("System XDEV Space Properties:\n\t{}\n", .{mndx_space_properties.supportsXDevSpace != 0});
    }

    try err(c.xrDestroyInstance(instance));
}
