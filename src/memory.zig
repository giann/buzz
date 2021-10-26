const std = @import("std");
const builtin = @import("builtin");
const VM = @import("./vm.zig").VM;
const _value = @import("./value.zig");
const _obj = @import("./obj.zig");
const dumpStack = @import("./disassembler.zig").dumpStack;
const Config = @import("./config.zig").Config;

const Value = _value.Value;
const valueToString = _value.valueToString;
const Obj = _obj.Obj;
const ObjString = _obj.ObjString;
const ObjTypeDef = _obj.ObjTypeDef;
const ObjUpValue = _obj.ObjUpValue;
const ObjClosure = _obj.ObjClosure;
const ObjFunction = _obj.ObjFunction;
const ObjObjectInstance = _obj.ObjObjectInstance;
const ObjObject = _obj.ObjObject;
const ObjList = _obj.ObjList;
const ObjMap = _obj.ObjMap;
const ObjEnum = _obj.ObjEnum;
const ObjEnumInstance = _obj.ObjEnumInstance;
const ObjBoundMethod = _obj.ObjBoundMethod;
const ObjNative = _obj.ObjNative;
const ObjError = _obj.ObjError;
const ObjRoutine = _obj.ObjRoutine;

pub fn allocate(vm: *VM, comptime T: type) !*T {
    vm.bytes_allocated += @sizeOf(T);

    if (vm.bytes_allocated > vm.next_gc) {
        try collectGarbage(vm);
    }

    return try vm.allocator.create(T);
}

pub fn allocateMany(vm: *VM, comptime T: type, count: usize) ![]T {
    vm.bytes_allocated += @sizeOf(T);

    if (vm.bytes_allocated > vm.next_gc) {
        try collectGarbage(vm);
    }

    return try vm.allocator.alloc(T, count);
}

pub fn free(vm: *VM, comptime T: type, pointer: *T) void {
    vm.bytes_allocated -= @sizeOf(T);
    vm.allocator.destroy(pointer);

    if (Config.debug_gc) {
        std.debug.warn("(from {}), freed {}, {} allocated\n", .{ vm.bytes_allocated + @sizeOf(T), @sizeOf(T), vm.bytes_allocated });
    }
}

pub fn freeMany(vm: *VM, comptime T: type, pointer: []const T) void {
    const n: usize = (@sizeOf(T) * pointer.len);
    vm.bytes_allocated -= n;
    vm.allocator.free(pointer);

    if (Config.debug_gc) {
        std.debug.warn("(from {}), freed {}, {} allocated\n", .{ vm.bytes_allocated + n, n, vm.bytes_allocated });
    }
}

pub fn markObj(vm: *VM, obj: *Obj) !void {
    if (obj.is_marked) {
        if (Config.debug_gc) {
            std.debug.warn("{*} already marked\n", .{ obj });
        }
        return;
    }

    if (Config.debug_gc) {
        std.debug.warn("marking {*}: {s}\n", .{ obj, try valueToString(vm.allocator, Value{ .Obj = obj }) });
    }

    obj.is_marked = true;

    try vm.gray_stack.append(obj);
}

fn blackenObject(vm: *VM, obj: *Obj) !void {
    _ = try switch (obj.obj_type) {
        .String => ObjString.cast(obj).?.mark(vm),
        .Type => ObjTypeDef.cast(obj).?.mark(vm),
        .UpValue => ObjUpValue.cast(obj).?.mark(vm),
        .Closure => ObjClosure.cast(obj).?.mark(vm),
        .Function => ObjFunction.cast(obj).?.mark(vm),
        .ObjectInstance => ObjObjectInstance.cast(obj).?.mark(vm),
        .Object => ObjObject.cast(obj).?.mark(vm),
        .List => ObjList.cast(obj).?.mark(vm),
        .Map => ObjMap.cast(obj).?.mark(vm),
        .Enum => ObjEnum.cast(obj).?.mark(vm),
        .EnumInstance => ObjEnumInstance.cast(obj).?.mark(vm),
        .Bound => ObjBoundMethod.cast(obj).?.mark(vm),
        .Native => ObjNative.cast(obj).?.mark(vm),
        .Error => ObjError.cast(obj).?.mark(vm),
        .Routine => ObjRoutine.cast(obj).?.mark(vm),
    };
}

fn freeObj(vm: *VM, obj: *Obj) void {
    if (Config.debug_gc) {
        std.debug.warn("freeing {*}: {}\n", .{ obj, obj.obj_type });
    }

    switch (obj.obj_type) {
        .String => {
            var obj_string = ObjString.cast(obj).?;
            freeMany(vm, u8, obj_string.string);
            free(vm, ObjString, obj_string);
        },
        .Type => {
            var obj_typedef = ObjTypeDef.cast(obj).?;
            obj_typedef.deinit();
            free(vm, ObjTypeDef, obj_typedef);
        },
        .UpValue => free(vm, ObjUpValue, ObjUpValue.cast(obj).?),
        .Closure => {
            var obj_closure = ObjClosure.cast(obj).?;
            obj_closure.deinit();
            free(vm, ObjClosure, obj_closure);
        },
        .Function => {
            var obj_function = ObjFunction.cast(obj).?;
            obj_function.deinit();
            free(vm, ObjFunction, obj_function);
        },
        .ObjectInstance => {
            var obj_objectinstance = ObjObjectInstance.cast(obj).?;
            obj_objectinstance.deinit();
            free(vm, ObjObjectInstance, obj_objectinstance);
        },
        .Object => {
            var obj_object = ObjObject.cast(obj).?;
            obj_object.deinit();
            free(vm, ObjObject, obj_object);
        },
        .List => {
            var obj_list = ObjList.cast(obj).?;
            obj_list.deinit();
            free(vm, ObjList, obj_list);
        },
        .Map => {
            var obj_map = ObjMap.cast(obj).?;
            obj_map.deinit();
            free(vm, ObjMap, obj_map);
        },
        .Enum => {
            var obj_enum = ObjEnum.cast(obj).?;
            obj_enum.deinit();
            free(vm, ObjEnum, obj_enum);
        },
        .EnumInstance => free(vm, ObjEnumInstance, ObjEnumInstance.cast(obj).?),
        .Bound => free(vm, ObjBoundMethod, ObjBoundMethod.cast(obj).?),
        .Native => free(vm, ObjNative, ObjNative.cast(obj).?),
        .Error => free(vm, ObjError, ObjError.cast(obj).?),
        .Routine => {
            var obj_routine = ObjRoutine.cast(obj).?;
            obj_routine.deinit();
            free(vm, ObjRoutine, obj_routine);
        }
    }
}

pub fn markValue(vm: *VM, value: Value) !void {
    if (value == .Obj) {
        try markObj(vm, value.Obj);
    }
}

fn markRoots(vm: *VM) !void {
    // Mark stack values
    var i = @ptrCast([*]Value, vm.stack);
    while (@ptrToInt(i) < @ptrToInt(vm.stack_top)) : (i += 1) {
        try markValue(vm, i[0]);
    }

    // Mark closure
    for (vm.frames.items) |frame| {
        try markObj(vm, frame.closure.toObj());
    }

    // Mark opened upvalues
    if (vm.open_upvalues) |open_upvalues| {
        var upvalue: ?*ObjUpValue = open_upvalues;
        while (upvalue) |unwrapped| : (upvalue = unwrapped.next) {
            try markObj(vm, unwrapped.toObj());
        }
    }

    // Mark globals
    for (vm.globals.items) |global| {
        try markValue(vm, global);
    }
}

fn traceReference(vm: *VM) !void {
    while (vm.gray_stack.items.len > 0) {
        try blackenObject(vm, vm.gray_stack.pop());
    }
}

fn sweep(vm: *VM) void {
    var swept: usize = vm.bytes_allocated;

    var previous: ?*Obj = null;
    var obj: ?*Obj = vm.objects;
    while (obj) |uobj| {
        if (uobj.is_marked) {
            uobj.is_marked = false;

            previous = uobj;
            obj = uobj.next;
        } else {
            var unreached: *Obj = uobj;
            obj = uobj.next;

            if (previous) |uprevious| {
                uprevious.next = obj;
            } else {
                vm.objects = obj;
            }

            freeObj(vm, unreached);
        }
    }

    if (Config.debug_gc) {
        std.debug.warn("Swept {} bytes, now {} bytes, remaining are:\n", .{ swept - vm.bytes_allocated, vm.bytes_allocated });
        obj = vm.objects;
        while (obj) |uobj| {
            std.debug.warn("\t{*}: {s}\n", .{ uobj, uobj });
            obj = uobj.next;
        }
    }
}

pub fn collectGarbage(vm: *VM) !void {
    if (Config.debug_gc) {
        std.debug.warn("-- gc starts\n", .{});

        try dumpStack(vm);
    }

    try markRoots(vm);

    try traceReference(vm);

    var it = vm.strings.iterator();
    while (it.next()) |kv| {
        try markObj(vm, kv.value_ptr.*.toObj());
    }

    sweep(vm);

    vm.next_gc = vm.bytes_allocated * 2;

    if (Config.debug_gc) {
        std.debug.warn("-- gc end\n", .{});
    }
}