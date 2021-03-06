const std = @import("std");
const api = @import("./buzz_api.zig");
const utils = @import("../src/utils.zig");

export fn getStdIn(vm: *api.VM) c_int {
    vm.bz_pushNum(@intToFloat(f64, std.io.getStdIn().handle));

    return 1;
}

export fn getStdOut(vm: *api.VM) c_int {
    vm.bz_pushNum(@intToFloat(f64, std.io.getStdOut().handle));

    return 1;
}

export fn getStdErr(vm: *api.VM) c_int {
    vm.bz_pushNum(@intToFloat(f64, std.io.getStdErr().handle));

    return 1;
}

export fn FileOpen(vm: *api.VM) c_int {
    const mode: u8 = @floatToInt(u8, api.Value.bz_valueToNumber(vm.bz_peek(0)));
    const filename: []const u8 = std.mem.sliceTo(api.Value.bz_valueToString(vm.bz_peek(1)) orelse "", 0);

    var file: std.fs.File = if (std.fs.path.isAbsolute(filename))
        switch (mode) {
            0 => std.fs.openFileAbsolute(filename, .{ .mode = .read_only }) catch {
                vm.bz_throwString("Could not open file");

                return -1;
            },
            else => std.fs.createFileAbsolute(filename, .{ .read = mode != 1 }) catch {
                vm.bz_throwString("Could not open file");

                return -1;
            },
        }
    else switch (mode) {
        0 => std.fs.cwd().openFile(filename, .{ .mode = .read_only }) catch {
            vm.bz_throwString("Could not open file");

            return -1;
        },
        else => std.fs.cwd().createFile(filename, .{ .read = mode != 1 }) catch {
            vm.bz_throwString("Could not open file");

            return -1;
        },
    };

    vm.bz_pushNum(@intToFloat(f64, file.handle));

    return 1;
}

export fn FileClose(vm: *api.VM) c_int {
    const handle: std.fs.File.Handle = @floatToInt(
        std.fs.File.Handle,
        api.Value.bz_valueToNumber(vm.bz_peek(0)),
    );

    const file: std.fs.File = std.fs.File{ .handle = handle };
    file.close();

    return 0;
}

export fn FileReadAll(vm: *api.VM) c_int {
    const handle: std.fs.File.Handle = @floatToInt(
        std.fs.File.Handle,
        api.Value.bz_valueToNumber(vm.bz_peek(0)),
    );

    const file: std.fs.File = std.fs.File{ .handle = handle };

    const content: [*:0]u8 = file.readToEndAllocOptions(api.VM.allocator, 10240, null, @alignOf(u8), 0) catch {
        vm.bz_throwString("Could not read file");

        return -1;
    };

    vm.bz_pushString(api.ObjString.bz_string(vm, content) orelse {
        vm.bz_throwString("Could not read file");

        return -1;
    });

    return 1;
}

export fn FileReadLine(vm: *api.VM) c_int {
    const handle: std.fs.File.Handle = @floatToInt(
        std.fs.File.Handle,
        api.Value.bz_valueToNumber(vm.bz_peek(0)),
    );

    const file: std.fs.File = std.fs.File{ .handle = handle };
    const reader = file.reader();

    var buffer = std.ArrayList(u8).init(api.VM.allocator);

    var i: usize = 0;
    while (i < 16 * 8 * 64) : (i += 1) {
        const read: ?u8 = reader.readByte() catch null;

        if (read == null) {
            break;
        }

        buffer.append(read.?) catch {
            vm.bz_throwString("Could not read file");

            return -1;
        };

        if (read.? == '\n') {
            break;
        }
    }

    // EOF?
    if (buffer.items.len == 0) {
        vm.bz_pushNull();
    } else {
        vm.bz_pushString(api.ObjString.bz_string(vm, utils.toCString(api.VM.allocator, buffer.items) orelse {
            vm.bz_throwString("Could not read file");

            return -1;
        }) orelse {
            vm.bz_throwString("Could not read file");

            return -1;
        });
    }

    return 1;
}

export fn FileRead(vm: *api.VM) c_int {
    const n: u64 = @floatToInt(u64, api.Value.bz_valueToNumber(vm.bz_peek(0)));
    const handle: std.fs.File.Handle = @floatToInt(
        std.fs.File.Handle,
        api.Value.bz_valueToNumber(vm.bz_peek(1)),
    );

    const file: std.fs.File = std.fs.File{ .handle = handle };
    const reader = file.reader();

    var buffer = api.VM.allocator.alloc(u8, n) catch {
        vm.bz_throwString("Could not read file");

        return -1;
    };
    // bz_string will copy it
    defer api.VM.allocator.free(buffer);

    const read = reader.read(buffer) catch {
        vm.bz_throwString("Could not read file");

        return -1;
    };

    if (read == 0) {
        vm.bz_pushNull();
    } else {
        vm.bz_pushString(api.ObjString.bz_string(vm, utils.toCString(api.VM.allocator, buffer) orelse {
            vm.bz_throwString("Could not read file");

            return -1;
        }) orelse {
            vm.bz_throwString("Could not read file");

            return -1;
        });
    }

    return 1;
}

// extern fun File_write(num fd, [num] bytes) > void;
export fn FileWrite(vm: *api.VM) c_int {
    const handle: std.fs.File.Handle = @floatToInt(
        std.fs.File.Handle,
        api.Value.bz_valueToNumber(vm.bz_peek(1)),
    );

    const file: std.fs.File = std.fs.File{ .handle = handle };

    _ = file.write(std.mem.sliceTo(vm.bz_peek(0).bz_valueToString().?, 0)) catch {
        vm.bz_throwString("Could not read file");

        return -1;
    };

    return 0;
}
