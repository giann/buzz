// zig fmt: off
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const StringHashMap = std.StringHashMap;
const Chunk = @import("./chunk.zig").Chunk;
const VM = @import("./vm.zig").VM;
const Compiler = @import("./compiler.zig").Compiler;
const _memory = @import("./memory.zig");
const _value = @import("./value.zig");
const Token = @import("./token.zig").Token;
const Config = @import("./config.zig").Config;

const Value = _value.Value;
const HashableValue = _value.HashableValue;
const ValueType = _value.ValueType;
const valueToHashable = _value.valueToHashable;
const hashableToValue = _value.hashableToValue;
const valueToString = _value.valueToString;
const valueEql = _value.valueEql;
const valueIs = _value.valueIs;
const valueTypeEql = _value.valueTypeEql;
const allocate = _memory.allocate;
const allocateMany = _memory.allocateMany;
const free = _memory.free;
const freeMany = _memory.freeMany;
const markObj = _memory.markObj;
const markValue = _memory.markValue;
const collectGarbage = _memory.collectGarbage;

pub const ObjType = enum {
    String,
    Type,
    UpValue,
    Closure,
    Function,
    ObjectInstance,
    Object,
    List,
    Map,
    Enum,
    EnumInstance,
    Bound,
    Native,
    Error,
    Routine,
};

pub fn allocateObject(vm: *VM, comptime T: type, data: T) !*T {
    var before: usize = vm.bytes_allocated;

    var obj: *T = try allocate(vm, T);
    obj.* = data;

    // TODO: How to avoid this?
    var object: *Obj = switch (T) {
        ObjString => ObjString.toObj(obj),
        ObjTypeDef => ObjTypeDef.toObj(obj),
        ObjUpValue => ObjUpValue.toObj(obj),
        ObjClosure => ObjClosure.toObj(obj),
        ObjFunction => ObjFunction.toObj(obj),
        ObjObjectInstance => ObjObjectInstance.toObj(obj),
        ObjObject => ObjObject.toObj(obj),
        ObjList => ObjList.toObj(obj),
        ObjMap => ObjMap.toObj(obj),
        ObjEnum => ObjEnum.toObj(obj),
        ObjEnumInstance => ObjEnumInstance.toObj(obj),
        ObjBoundMethod => ObjBoundMethod.toObj(obj),
        ObjNative => ObjNative.toObj(obj),
        ObjError => ObjError.toObj(obj),
        else => {}
    };

    if (Config.debug_gc) {
        std.debug.warn("allocated {*} {*}\n", .{ obj, object });
        std.debug.warn("(from {}) {} allocated, total {}\n", .{ before, @sizeOf(T), vm.bytes_allocated });
    }

    // Add new object at start of vm.objects linked list
    object.next = vm.objects;
    vm.objects = object;

    return obj;
}

pub fn allocateString(vm: *VM, chars: []const u8) !*ObjString {
    if (vm.strings.get(chars)) |interned| {
        return interned;
    } else {
        var string: *ObjString = try allocateObject(vm, ObjString, ObjString{ .string = chars });

        vm.push(Value { .Obj = string.toObj() });
        try vm.strings.put(chars, string);
        _ = vm.pop();

        return string;
    }
}

pub fn copyString(vm: *VM, chars: []const u8) !*ObjString {
    if (vm.strings.get(chars)) |interned| {
        return interned;
    }

    var copy: []u8 = try allocateMany(vm, u8, chars.len);
    mem.copy(u8, copy, chars);

    return try allocateString(vm, copy);
}

pub fn copyStringRaw(strings: *std.StringHashMap(*ObjString), allocator: *Allocator, chars: []const u8, owned: bool) !*ObjString {
    if (strings.get(chars)) |interned| {
        return interned;
    }

    var copy: []u8 = undefined;
    if (!owned) {
        copy = try allocator.alloc(u8, chars.len);
        mem.copy(u8, copy, chars);
    }

    var obj_string: *ObjString = try allocator.create(ObjString);
    obj_string.* = ObjString {
        .string = if (owned) chars else copy
    };

    try strings.put(chars, obj_string);

    return obj_string;
}

pub const Obj = struct {
    const Self = @This();

    obj_type: ObjType,
    is_marked: bool = false,
    next: ?*Obj = null,

    pub fn is(self: *Self, type_def: *ObjTypeDef) bool {
        return switch (self.obj_type) {
            .String => type_def.def_type == .String,
            
            .Type,
            .Object,
            .Enum, => type_def.def_type == .Type,

            .ObjectInstance => type_def.def_type == .Object
                and ObjObjectInstance.cast(self).?.is(null, type_def),
            .EnumInstance => type_def.def_type == .Enum
                and ObjEnumInstance.cast(self).?.enum_ref.type_def == type_def,
            .Function => function: {
                const function: *ObjFunction = ObjFunction.cast(self).?;
                break :function function.type_def.eql(type_def);
            },

            .UpValue => upvalue: {
                const upvalue: *ObjUpValue = ObjUpValue.cast(self).?;
                break :upvalue valueIs(
                    Value{ .Obj = type_def.toObj() },
                    upvalue.closed orelse upvalue.location.*,
                );
            },
            .Closure => ObjClosure.cast(self).?.function.toObj().is(type_def),
            .List => ObjList.cast(self).?.type_def.eql(type_def),
            .Map => ObjMap.cast(self).?.type_def.eql(type_def),
            .Bound => bound: {
                const bound: *ObjBoundMethod = ObjBoundMethod.cast(self).?;
                break :bound valueIs(
                    Value{ .Obj = type_def.toObj() },
                    Value{ .Obj = if (bound.closure) |cls| cls.function.toObj() else bound.native.?.toObj() },
                );
            },

            .Native => unreachable, // TODO: we don't know how to embark NativeFn type at runtime yet
            .Error => unreachable, //type_def.def_type == .Error,
            .Routine => type_def.def_type == .Routine,
        };
    }

    pub fn typeEql(self: *Self, type_def: *ObjTypeDef) bool {
        return switch (self.obj_type) {
            .String => type_def.def_type == .String,
            .Type => type_def.def_type == .Type,
            .Routine => type_def.def_type == .Routine,
            .UpValue => uv: {
                var upvalue: *ObjUpValue = ObjUpValue.cast(self).?;
                break :uv valueTypeEql(upvalue.closed orelse upvalue.location.*, type_def);
            },
            .EnumInstance => ei: {
                var instance: *ObjEnumInstance = ObjEnumInstance.cast(self).?;
                break :ei type_def.def_type == .EnumInstance
                    and instance.enum_ref.type_def.eql(type_def.resolved_type.?.EnumInstance);
            },
            .ObjectInstance => oi: {
                var instance: *ObjObjectInstance = ObjObjectInstance.cast(self).?;
                break :oi type_def.def_type == .ObjectInstance
                    and instance.is(null, type_def.resolved_type.?.ObjectInstance);
            },
            .Enum => ObjEnum.cast(self).?.type_def.eql(type_def),
            .Object => ObjObject.cast(self).?.type_def.eql(type_def),
            .Function => ObjFunction.cast(self).?.type_def.eql(type_def),
            .Closure => ObjClosure.cast(self).?.function.type_def.eql(type_def),
            .Bound => bound: {
                var bound = ObjBoundMethod.cast(self).?;
                break :bound if (bound.closure) |cls| cls.function.type_def.eql(type_def)
                    else unreachable; // TODO
            },
            .List => ObjList.cast(self).?.type_def.eql(type_def),
            .Map => ObjMap.cast(self).?.type_def.eql(type_def),
            .Native => unreachable, // TODO
            .Error => unreachable,
        };
    }

    pub fn eql(self: *Self, other: *Self) bool {
        if (self.obj_type != other.obj_type) {
            return false;
        }

        switch (self.obj_type) {
            .String => {
                // return mem.eql(u8, ObjString.cast(self).?.string, ObjString.cast(other).?.string);
                
                // since string are interned this should be enough
                return self == other;
            },
            .Type => {
                const self_type: *ObjTypeDef = ObjTypeDef.cast(self).?;
                const other_type: *ObjTypeDef = ObjTypeDef.cast(other).?;

                return self_type.optional == other_type.optional and self_type.eql(other_type);
            },
            .UpValue => {
                const self_upvalue: *ObjUpValue = ObjUpValue.cast(self).?;
                const other_upvalue: *ObjUpValue = ObjUpValue.cast(other).?;

                return valueEql(self_upvalue.closed orelse self_upvalue.location.*, other_upvalue.closed orelse other_upvalue.location.*);
            },
            .EnumInstance => {
                const self_enum_instance: *ObjEnumInstance = ObjEnumInstance.cast(self).?;
                const other_enum_instance: *ObjEnumInstance = ObjEnumInstance.cast(other).?;

                return self_enum_instance.enum_ref == other_enum_instance.enum_ref
                    and self_enum_instance.case == other_enum_instance.case;
            },
            .Bound,
            .Closure,
            .Function,
            .ObjectInstance,
            .Object,
            .List,
            .Map,
            .Enum,
            .Native,
            .Error,
            .Routine, => {
                return self == other;
            },
        }
    }
};

// If returns false, no return value
pub const NativeFn = fn (vm: *VM) bool;

/// Native function
pub const ObjNative = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Native
    },

    // TODO: issue is list.member which separate its type definition from its runtime creation
    // type_def: *ObjTypeDef,

    native: NativeFn,

    pub fn mark(_: *Self, _: *VM) void {
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Native) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

pub const ObjRoutine = struct {
    const Self = @This();

    const State = enum {
        Normal,
        Suspended,
        Over,
    };

    obj: Obj = .{
        .obj_type = .Routine,
    },

    closure: *ObjClosure,
    routine: *VM,
    state: State = .Normal,

    pub fn rawStart(self: *Self, host: *VM, arguments: std.ArrayList(Value)) VM.Error!void {
        if (self.state != .Normal) {
            return host.runtimeError(.BadRoutineState, Value{ .Null = null }, null);
        }
        
        // TODO: capture closure's upvalues

        // TODO: is this necessary?
        self.routine.push(Value{ .Null = null });
        for (arguments.items) |arg| {
            self.routine.push(arg);
        }

        _ = try self.routine.call(self.closure, arguments.len);

        return try self.routine.run();
    }

    pub fn rawResume(self: *Self, host: *VM) VM.Error!void {
        if (self.state != .Suspended) {
            return host.runtimeError(.BadRoutineState, Value{ .Null = null }, null);
        }

        return try self.routine.run();
    }

    pub fn deinit(self: *Self) void {
        self.routine.deinit();
    }

    pub fn mark(_: *Self, _: *VM) void {
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Routine) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

pub const ObjError = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Error
    },

    message: *ObjString,
    // payload: *ObjObjectInstance // TODO: Instance of `Error`

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.message.toObj());
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Error) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// A String
pub const ObjString = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .String
    },

    /// The actual string
    string: []const u8,

    pub fn mark(_: *Self, _: *VM) void {
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .String) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn concat(self: *Self, vm: *VM, other: *Self) !*Self {
        var new_string: std.ArrayList(u8) = std.ArrayList(u8).init(vm.allocator);
        try new_string.appendSlice(self.string);
        try new_string.appendSlice(other.string);

        return copyString(vm, new_string.items);
    }
};

/// Upvalue
pub const ObjUpValue = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .UpValue
    },

    /// Slot on the stack
    location: *Value,
    closed: ?Value,
    next: ?*ObjUpValue = null,

    pub fn init(slot: *Value) Self {
        return Self {
            .closed = null,
            .location = slot,
            .next = null
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        if (self.closed) |uclosed| {
            try markValue(vm, uclosed);
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .UpValue) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Closure
pub const ObjClosure = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Closure
    },

    function: *ObjFunction,
    catch_closures: std.ArrayList(*ObjClosure),
    upvalues: std.ArrayList(*ObjUpValue),

    pub fn init(allocator: *Allocator, function: *ObjFunction) !Self {
        return Self {
            .function = function,
            .catch_closures = std.ArrayList(*ObjClosure).init(allocator),
            .upvalues = try std.ArrayList(*ObjUpValue).initCapacity(allocator, function.upvalue_count),
        };
    }
    
    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.function.toObj());
        for (self.catch_closures.items) |catch_closure| {
            try markObj(vm, catch_closure.toObj());
        }
        for (self.upvalues.items) |upvalue| {
            try markObj(vm, upvalue.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.catch_closures.deinit();
        self.upvalues.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Closure) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Function
pub const ObjFunction = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Function
    },

    type_def: *ObjTypeDef = undefined, // Undefined because function initialization is in several steps

    name: *ObjString,
    chunk: Chunk,
    upvalue_count: u8 = 0,

    pub fn init(allocator: *Allocator, name: *ObjString) !Self {
        return Self {
            .name = name,
            .chunk = Chunk.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.chunk.deinit();
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.name.toObj());
        try markObj(vm, self.type_def.toObj());
        for (self.chunk.constants.items) |constant| {
            try markValue(vm, constant);
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Function) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const FunctionDef = struct {
        name: *ObjString,
        return_type: *ObjTypeDef,
        parameters: std.StringArrayHashMap(*ObjTypeDef),
    };
};

/// Object instance
pub const ObjObjectInstance = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .ObjectInstance
    },

    /// Object
    object: *ObjObject,
    /// Fields value
    fields: StringHashMap(Value),

    pub fn init(allocator: *Allocator, object: *ObjObject) Self {
        return Self {
            .object = object,
            .fields = StringHashMap(Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.object.toObj());
        var it = self.fields.iterator();
        while (it.next()) |kv| {
            try markValue(vm, kv.value_ptr.*);
        }
    }

    pub fn deinit(self: *Self) void {
        self.fields.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .ObjectInstance) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    fn is(self: *Self, instance_type: ?*ObjTypeDef, type_def: *ObjTypeDef) bool {
        const object_def: *ObjTypeDef = instance_type orelse self.object.type_def;

        if (type_def.def_type != .Object) {
            return false;
        }

        return object_def == type_def
            or (object_def.resolved_type.?.Object.super != null and self.is(object_def.resolved_type.?.Object.super.?, type_def));
    }
};

/// Object
pub const ObjObject = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Object
    },

    type_def: *ObjTypeDef,

    /// Object name
    name: *ObjString,
    /// Object methods
    methods: StringHashMap(*ObjClosure),
    /// Object fields default values
    fields: StringHashMap(Value),
    /// Object static fields
    static_fields: StringHashMap(Value),
    /// Optional super class
    super: ?*ObjObject = null,

    pub fn init(allocator: *Allocator, name: *ObjString, type_def: *ObjTypeDef) Self {
        return Self {
            .name = name,
            .methods = StringHashMap(*ObjClosure).init(allocator),
            .fields = StringHashMap(Value).init(allocator),
            .static_fields = StringHashMap(Value).init(allocator),
            .type_def = type_def,
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.name.toObj());
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            try markObj(vm, kv.value_ptr.*.toObj());
        }
        var it2 = self.fields.iterator();
        while (it2.next()) |kv| {
            try markValue(vm, kv.value_ptr.*);
        }
        var it3 = self.static_fields.iterator();
        while (it3.next()) |kv| {
            try markValue(vm, kv.value_ptr.*);
        }
        if (self.super) |super| {
            try markObj(vm, super.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.methods.deinit();
        self.fields.deinit();
        self.static_fields.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Object) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const ObjectDef = struct {
        const ObjectDefSelf = @This();

        name: *ObjString,
        // TODO: Do i need to have two maps ?
        fields: StringHashMap(*ObjTypeDef),
        fields_defaults: StringHashMap(void),
        static_fields: StringHashMap(*ObjTypeDef),
        methods: StringHashMap(*ObjTypeDef),
        // When we have placeholders we don't know if they are properties or methods
        // That information is available only when the placeholder is resolved
        // It's not an issue since:
        //   - we use OP_GET_PROPERTY for both
        //   - OP_SET_PROPERTY for a method will ultimately fail
        //   - OP_INVOKE on a field will ultimately fail
        // TODO: but we can have field which are functions and then we don't know what's what
        placeholders: StringHashMap(*ObjTypeDef),
        static_placeholders: StringHashMap(*ObjTypeDef),
        super: ?*ObjTypeDef = null,
        inheritable: bool = false,
        

        pub fn init(allocator: *Allocator, name: *ObjString) ObjectDefSelf {
            return ObjectDefSelf {
                .name = name,
                .fields = StringHashMap(*ObjTypeDef).init(allocator),
                .static_fields = StringHashMap(*ObjTypeDef).init(allocator),
                .fields_defaults = StringHashMap(void).init(allocator),
                .methods = StringHashMap(*ObjTypeDef).init(allocator),
                .placeholders = StringHashMap(*ObjTypeDef).init(allocator),
                .static_placeholders = StringHashMap(*ObjTypeDef).init(allocator),
            };
        }

        pub fn deinit(self: *ObjectDefSelf) void {
            self.fields.deinit();
            self.static_fields.deinit();
            self.fields_defaults.deinit();
            self.methods.deinit();
            self.placeholders.deinit();
            self.static_placeholders.deinit();
        }
    };
};

/// List
pub const ObjList = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .List
    },

    type_def: *ObjTypeDef,

    /// List items
    items: std.ArrayList(Value),

    methods: std.StringHashMap(*ObjNative),

    pub fn init(allocator: *Allocator, type_def: *ObjTypeDef) Self {
        return Self {
            .items = std.ArrayList(Value).init(allocator),
            .type_def = type_def,
            .methods = std.StringHashMap(*ObjNative).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        for (self.items.items) |value| {
            try markValue(vm, value);
        }
        try markObj(vm, self.type_def.toObj());
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            try markObj(vm, kv.value_ptr.*.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit();
        self.methods.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .List) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    // TODO: find a way to return the same ObjNative pointer for the same type of Lists
    pub fn member(self: *Self, vm: *VM, method: []const u8) !?*ObjNative {
        if (self.methods.get(method)) |native| {
            return native;
        }

        var nativeFn: ?NativeFn = null;
        if (mem.eql(u8, method, "append")) {
            nativeFn = append;
        } else if (mem.eql(u8, method, "len")) {
            nativeFn = len;
        } else if (mem.eql(u8, method, "next")) {
            nativeFn = next;
        }

        if (nativeFn) |unativeFn| {
            var native: *ObjNative = try allocateObject(vm, ObjNative, .{
                .native = unativeFn
            });

            try self.methods.put(method, native);

            return native;
        }

        return null;
    }

    fn append(vm: *VM) bool {
        var list_value: Value = vm.peek(1);
        var list: *ObjList = ObjList.cast(list_value.Obj).?;
        var value: Value = vm.peek(0);

        list.items.append(value) catch |err| {
            const messageValue: Value = (copyString(vm, "Could not append to list") catch {
                std.debug.warn("Could not append to list", .{});
                std.os.exit(1);
            }).toValue();

            vm.throw(err, messageValue) catch {
                std.debug.warn("Could not append to list", .{});
                std.os.exit(1);
            };
            return false;
        };

        vm.push(list_value);

        return true;
    }

    fn len(vm: *VM) bool {
        var list: *ObjList = ObjList.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Number = @intToFloat(f64, list.items.items.len) });

        return true;
    }

    pub fn rawNext(self: *Self, vm: *VM, list_index: ?f64) !?f64 {
        if (list_index) |index| {
            if (index < 0 or index >= @intToFloat(f64, self.items.items.len)) {
                try vm.throw(VM.Error.OutOfBound, (try copyString(vm, "Out of bound access to list")).toValue());
            }

            return if (index + 1 >= @intToFloat(f64, self.items.items.len))
                null
            else
                index + 1;
        } else {
            return if (self.items.items.len > 0) @intToFloat(f64, 0) else null;
        }
    }

    fn next(vm: *VM) bool {
        var list_value: Value = vm.peek(1);
        var list: *ObjList = ObjList.cast(list_value.Obj).?;
        var list_index: Value = vm.peek(0);

        var next_index: ?f64 = list.rawNext(
            vm,
            if (list_index == .Null) null
            else list_index.Number
        ) catch |err| {
            // TODO: should we distinguish NativeFn and ExternFn ?
            std.debug.warn("{}\n", .{err});
            std.os.exit(1);
        };

        vm.push(
            if (next_index) |unext_index| Value{ .Number = unext_index }
            else Value{ .Null = null }
        );

        return true;
    }

    pub const ListDef = struct {
        const SelfListDef = @This();

        item_type: *ObjTypeDef,
        methods: std.StringHashMap(*ObjTypeDef),

        pub fn init(allocator: *Allocator, item_type: *ObjTypeDef) SelfListDef {
            return .{
                .item_type = item_type,
                .methods = std.StringHashMap(*ObjTypeDef).init(allocator)
            };
        }

        pub fn deinit(self: *SelfListDef) void {
            self.methods.deinit();
        }
        
        pub fn member(obj_list: *ObjTypeDef, compiler: *Compiler, method: []const u8) !?*ObjTypeDef {
            var self = obj_list.resolved_type.?.List;
            
            if (self.methods.get(method)) |native_def| {
                return native_def;
            }

            if (mem.eql(u8, method, "append")) {
                var parameters = std.StringArrayHashMap(*ObjTypeDef).init(compiler.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the list.

                // `value` arg is of item_type
                try  parameters.put("value", self.item_type);

                var method_def = ObjFunction.FunctionDef{
                    .name = try copyStringRaw(compiler.strings, compiler.allocator, "append", false),
                    .parameters = parameters,
                    .return_type = obj_list
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{
                    .Native = method_def
                };

                var native_type = try compiler.getTypeDef(ObjTypeDef{
                    .def_type = .Native,
                    .resolved_type = resolved_type
                });

                try self.methods.put("append", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "len")) {
                var parameters = std.StringArrayHashMap(*ObjTypeDef).init(compiler.allocator);

                var method_def = ObjFunction.FunctionDef{
                    .name = try copyStringRaw(compiler.strings, compiler.allocator, "len", false),
                    .parameters = parameters,
                    .return_type = try compiler.getTypeDef(ObjTypeDef{
                        .def_type = .Number,
                    })
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{
                    .Native = method_def
                };

                var native_type = try compiler.getTypeDef(ObjTypeDef{
                    .def_type = .Native,
                    .resolved_type = resolved_type
                });

                try self.methods.put("len", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "next")) {
                var parameters = std.StringArrayHashMap(*ObjTypeDef).init(compiler.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the list.

                // `key` arg is number
                try  parameters.put("key", try compiler.getTypeDef(ObjTypeDef{
                    .def_type = .Number,
                    .optional = true
                }));

                var method_def = ObjFunction.FunctionDef{
                    .name = try copyStringRaw(compiler.strings, compiler.allocator, "next", false),
                    .parameters = parameters,
                    // When reached end of list, returns null
                    .return_type = try compiler.getTypeDef(ObjTypeDef{
                        .def_type = .Number,
                        .optional = true
                    })
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{
                    .Native = method_def
                };

                var native_type = try compiler.getTypeDef(ObjTypeDef{
                    .def_type = .Native,
                    .resolved_type = resolved_type
                });

                try self.methods.put("next", native_type);

                return native_type;
            }

            return null;
        }
    };
};

/// Map
pub const ObjMap = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Map
    },

    type_def: *ObjTypeDef,

    // We need an ArrayHashMap for `next`
    // In order to use a regular HashMap, we would have to hack are away around it to implement next
    map: std.AutoArrayHashMap(HashableValue, Value),

    pub fn init(allocator: *Allocator, type_def: *ObjTypeDef) Self {
        return .{
            .type_def = type_def,
            .map = std.AutoArrayHashMap(HashableValue, Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            try markValue(vm, hashableToValue(kv.key_ptr.*));
            try markValue(vm, kv.value_ptr.*);
        }
        try markObj(vm, self.type_def.toObj());
    }

    pub fn rawNext(self: *Self, key: ?HashableValue) ?HashableValue {
        const keys: []HashableValue = self.map.keys();

        if (key) |ukey| {
            const index: usize = self.map.getIndex(ukey).?;

            if (index < keys.len - 1) {
                return keys[index + 1];
            } else {
                return null;
            }
        } else {
            return if (keys.len > 0) keys[0] else null;
        }
    }
    
    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Map) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const MapDef = struct {
        key_type: *ObjTypeDef,
        value_type: *ObjTypeDef,
    };
};

/// Enum
pub const ObjEnum = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Enum
    },

    /// Used to allow type checking at runtime
    type_def: *ObjTypeDef,

    name: *ObjString,
    cases: std.ArrayList(Value),

    pub fn init(allocator: *Allocator, def: *ObjTypeDef) Self {
        return Self {
            .type_def = def,
            .name = def.resolved_type.?.Enum.name,
            .cases = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.name.toObj());
        try markObj(vm, self.type_def.toObj());
        try markObj(vm, self.name.toObj());
        for (self.cases.items) |case| {
            try markValue(vm, case);
        } 
    }

    pub fn rawNext(self: *Self, vm: *VM, enum_case: ?*ObjEnumInstance) !?*ObjEnumInstance {
        if (enum_case) |case| {
            assert(case.enum_ref == self);
            
            if (case.case == self.cases.items.len - 1) {
                return null;
            }
            
            return try allocateObject(vm, ObjEnumInstance, ObjEnumInstance{
                .enum_ref = self,
                .case = @intCast(u8, case.case + 1),
            });
        } else {
            return try allocateObject(vm, ObjEnumInstance, ObjEnumInstance{
                .enum_ref = self,
                .case = 0,
            });
        }
    }

    pub fn deinit(self: *Self) void {
        self.cases.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Enum) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const EnumDef = struct {
        const EnumDefSelf = @This();

        name: *ObjString,
        enum_type: *ObjTypeDef,
        cases: std.ArrayList([]const u8),

        pub fn init(allocator: *Allocator, name: *ObjString, enum_type: *ObjTypeDef) EnumDefSelf {
            return EnumDefSelf {
                .name = name,
                .cases = std.ArrayList([]const u8).init(allocator),
                .enum_type = enum_type,
            };
        }

        pub fn deinit(self: *EnumDefSelf) void {
            self.cases.deinit();
        }
    };
};

pub const ObjEnumInstance = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .EnumInstance
    },

    enum_ref: *ObjEnum,
    case: u8,

    pub fn mark(self: *Self, vm: *VM) !void {
        try markObj(vm, self.enum_ref.toObj());
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .EnumInstance) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn value(self: *Self) Value {
        return self.enum_ref.cases.items[self.case];
    }
};

/// Bound
pub const ObjBoundMethod = struct {
    const Self = @This();

    obj: Obj = .{
        .obj_type = .Bound
    },

    receiver: Value,
    closure: ?*ObjClosure = null,
    native: ?*ObjNative = null,

    pub fn mark(self: *Self, vm: *VM) !void {
        try markValue(vm, self.receiver);
        if (self.closure) |closure| {
            try markObj(vm, closure.toObj());
        }
        if (self.native) |native| {
            try markObj(vm, native.toObj());
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Bound) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Type
pub const ObjTypeDef = struct {
    const Self = @This();

    pub const Type = enum {
        Bool,
        Number,
        String,
        ObjectInstance,
        Object,
        Enum,
        EnumInstance,
        List,
        Map,
        Function,
        Type, // Something that holds a type, not an actual type
        Void,
        Native,
        Routine,

        Placeholder, // Used in first-pass when we refer to a not yet parsed type
    };

    pub const TypeUnion = union(Type) {
        // For those type checking is obvious, the value is a placeholder
        Bool: bool,
        Number: bool,
        String: bool,
        Type: bool,
        Void: bool,
        Routine: bool,

        // For those we check that the value is an instance of, because those are user defined types
        ObjectInstance: *ObjTypeDef,
        EnumInstance: *ObjTypeDef,

        // Those are never equal
        Object: ObjObject.ObjectDef,
        Enum: ObjEnum.EnumDef,

        // For those we compare definitions, so we own those structs, we don't use actual Obj because we don't want the data, only the types
        List: ObjList.ListDef,
        Map: ObjMap.MapDef,
        Function: ObjFunction.FunctionDef,
        Native: ObjFunction.FunctionDef,

        Placeholder: PlaceholderDef,
    };

    obj: Obj = .{
        .obj_type = .Type
    },

    /// True means its an optional (e.g `str?`)
    optional: bool = false,
    def_type: Type,
    /// Used when the type is not a basic type
    resolved_type: ?TypeUnion = null,

    pub fn deinit(_: *Self) void {
        std.debug.warn("ObjTypeDef.deinit not implemented\n", .{});
    }

    pub fn mark(self: *Self, vm: *VM) !void {
        if (self.resolved_type) |resolved| {
            if (resolved == .ObjectInstance) {
                try markObj(vm, resolved.ObjectInstance.toObj());
            } else if (resolved == .EnumInstance) {
                try markObj(vm, resolved.EnumInstance.toObj());
            }
        }
    }

    /// Beware: allocates a string, caller owns it
    pub fn toString(self: Self, allocator: *Allocator) (Allocator.Error || std.fmt.BufPrintError)![]const u8 {
        var type_str: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);

        switch (self.def_type) {
            .Bool => try type_str.appendSlice("bool"),
            .Number => try type_str.appendSlice("num"),
            .String => try type_str.appendSlice("str"),
            .Routine => try type_str.appendSlice("thd"),

            // TODO: Find a key for vm.getTypeDef which is unique for each class even with the same name
            .Object => {
                try type_str.appendSlice("{ObjectDef}");
                try type_str.appendSlice(self.resolved_type.?.Object.name.string);
            },
            .Enum => {
                try type_str.appendSlice("{EnumDef}");
                try type_str.appendSlice(self.resolved_type.?.Enum.name.string);
            },
        
            .ObjectInstance => try type_str.appendSlice(self.resolved_type.?.ObjectInstance.resolved_type.?.Object.name.string),
            .EnumInstance => try type_str.appendSlice(self.resolved_type.?.EnumInstance.resolved_type.?.Enum.name.string),

            .List => {
                var list_type = try self.resolved_type.?.List.item_type.toString(allocator);
                defer allocator.free(list_type);

                try type_str.append('[');
                try type_str.appendSlice(list_type);
                try type_str.append(']');
            },
            .Map => {
                var key_type = try self.resolved_type.?.Map.key_type.toString(allocator);
                defer allocator.free(key_type);
                var value_type = try self.resolved_type.?.Map.value_type.toString(allocator);
                defer allocator.free(value_type);
                
                try type_str.append('{');
                try type_str.appendSlice(key_type);
                try type_str.append(',');
                try type_str.appendSlice(value_type);
                try type_str.append('}');
            },
            .Function => {
                var function_def = self.resolved_type.?.Function;

                try type_str.appendSlice("Function(");
                try type_str.appendSlice(function_def.name.string);
                try type_str.appendSlice("(");

                var it = function_def.parameters.iterator();
                while (it.next()) |kv| {
                    var param_type = try kv.value_ptr.*.toString(allocator);
                    defer allocator.free(param_type);

                    try type_str.appendSlice(param_type);
                    try type_str.append(',');
                }

                try type_str.append(')');

                if (function_def.return_type.def_type != Type.Void) {
                    var return_type = try self.resolved_type.?.Function.return_type.toString(allocator);
                    defer allocator.free(return_type);

                    try type_str.appendSlice(") > ");
                    try type_str.appendSlice(return_type);
                }
            },
            .Type => try type_str.appendSlice("type"),
            .Void => try type_str.appendSlice("void"),

            .Placeholder => {
                try type_str.appendSlice("{PlaceholderDef}");
            },
            
            .Native => {
                try type_str.appendSlice("Native(");
                
                var ref: []u8 = try allocator.alloc(u8, 30);
                defer allocator.free(ref);
                ref = try std.fmt.bufPrint(ref, "{x}", .{ @ptrToInt(&self) });

                try type_str.appendSlice(ref);
                try type_str.appendSlice(")");
            }
        }

        if (self.optional) {
            try type_str.append('?');
        }

        return type_str.items;
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn toInstance(self: *Self) Self {
        return switch (self.def_type) {
            .Object => object: {
                var resolved_type: ObjTypeDef.TypeUnion = ObjTypeDef.TypeUnion{
                    .ObjectInstance = self
                };

                break :object Self{
                    .optional = self.optional,
                    .def_type = .ObjectInstance,
                    .resolved_type = resolved_type
                };
            },
            .Enum => enum_instance: {
                var resolved_type: ObjTypeDef.TypeUnion = ObjTypeDef.TypeUnion{
                    .EnumInstance = self
                };

                break :enum_instance Self{
                    .optional = self.optional,
                    .def_type = .EnumInstance,
                    .resolved_type = resolved_type
                };
            },
            else => self.*
        };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Type) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn instanceEqlTypeUnion(a: *ObjTypeDef, b: *ObjTypeDef) bool {
        assert(a.def_type == .Object);
        assert(b.def_type == .Object);

        return a == b
            or (b.resolved_type.?.Object.super != null and instanceEqlTypeUnion(a, b.resolved_type.?.Object.super.?));
    }

    // Compare two type definitions
    pub fn eqlTypeUnion(a: TypeUnion, b: TypeUnion) bool {
        if (@as(Type, a) != @as(Type, b)) {
            return false;
        }

        return switch (a) {
            .Bool, .Number, .String, .Type, .Void, .Routine, => return true,

            .ObjectInstance => {
                return a.ObjectInstance.eql(b.ObjectInstance)
                    or instanceEqlTypeUnion(a.ObjectInstance, b.ObjectInstance);
            },
            .EnumInstance => return a.EnumInstance.eql(b.EnumInstance),

            .Object,
            .Enum => false, // Thore are never equal even if definition is the same

            .List => return a.List.item_type.eql(b.List.item_type),
            .Map => return a.Map.key_type.eql(b.Map.key_type)
                and a.Map.value_type.eql(b.Map.value_type),
            .Function => {
                // Compare return types
                if (!a.Function.return_type.eql(b.Function.return_type)) {
                    return false;
                }

                // Compare arity
                if (a.Function.parameters.count() != b.Function.parameters.count()) {
                    return false;
                }

                // Compare parameters (we ignore argument names and only compare types)
                const a_keys: [][]const u8 = a.Function.parameters.keys();
                const b_keys: [][]const u8 = b.Function.parameters.keys();

                if (a_keys.len != b_keys.len) {
                    return false;
                }

                for (a_keys) |_, index| {
                    if (!a.Function.parameters.get(a_keys[index]).?
                        .eql(b.Function.parameters.get(b_keys[index]).?)) {
                        return false;
                    }
                }

                return true;
            },

            .Placeholder => a.Placeholder.eql(b.Placeholder),
            .Native => {
                // Compare return types
                if (a.Native.return_type.eql(b.Native.return_type)) {
                    return false;
                }

                // Compare arity
                if (a.Native.parameters.count() != b.Native.parameters.count()) {
                    return false;
                }

                // Compare parameters
                var it = a.Native.parameters.iterator();
                while (it.next()) |kv| {
                    if (b.Native.parameters.get(kv.key_ptr.*)) |value| {
                        if (!kv.value_ptr.*.eql(value)) {
                            return false;
                        }
                    } else {
                        return false;
                    }
                }

                return true;
            },
        };
    }

    // Compare two type definitions
    pub fn eql(self: *Self, other: *Self) bool {
        const type_eql: bool = self.def_type == other.def_type
            and ((self.resolved_type == null and other.resolved_type == null)
                or eqlTypeUnion(self.resolved_type.?, other.resolved_type.?));

        return self == other
            or (self.optional and other.def_type == .Void) // Void is equal to any optional type
            or (type_eql or other.def_type == .Placeholder or self.def_type == .Placeholder);
    }
};

// TODO: use ArrayList writer instead of std.fmt.bufPrint
pub fn objToString(allocator: *Allocator, buf: []u8, obj: *Obj) (Allocator.Error || std.fmt.BufPrintError)![]u8 {
    return switch (obj.obj_type) {
        .String => try std.fmt.bufPrint(buf, "{s}", .{ ObjString.cast(obj).?.string }),
        .Type => {
            // TODO: no use for typedef.toString to allocate a buffer
            var type_def: *ObjTypeDef = ObjTypeDef.cast(obj).?; 
            var type_str: []const u8 = try type_def.toString(allocator);
            defer allocator.free(type_str);

            return try std.fmt.bufPrint(buf, "type: 0x{x} `{s}`", .{ @ptrToInt(type_def), type_str });
        },
        .UpValue => {
            var upvalue: *ObjUpValue = ObjUpValue.cast(obj).?;
            var upvalue_str: []const u8 = try valueToString(allocator, upvalue.closed orelse upvalue.location.*);
            defer allocator.free(upvalue_str);

            return try std.fmt.bufPrint(buf, "upvalue: 0x{x} `{s}`", .{ @ptrToInt(upvalue), upvalue_str });
        },
        .Closure => try std.fmt.bufPrint(buf, "closure: 0x{x} `{s}`", .{ @ptrToInt(ObjClosure.cast(obj).?), ObjClosure.cast(obj).?.function.name.string }),
        .Function => try std.fmt.bufPrint(buf, "function: 0x{x} `{s}`", .{ @ptrToInt(ObjFunction.cast(obj).?), ObjFunction.cast(obj).?.name.string }),
        .ObjectInstance => try std.fmt.bufPrint(buf, "object instance: 0x{x} `{s}`", .{ @ptrToInt(ObjObjectInstance.cast(obj).?), ObjObjectInstance.cast(obj).?.object.name.string }),
        .Object => try std.fmt.bufPrint(buf, "object: 0x{x} `{s}`", .{ @ptrToInt(ObjObject.cast(obj).?), ObjObject.cast(obj).?.name.string }),
        .List => {
            var list: *ObjList = ObjList.cast(obj).?;
            var type_str: []const u8 = try list.type_def.resolved_type.?.List.item_type.toString(allocator);
            defer allocator.free(type_str);

            return try std.fmt.bufPrint(buf, "list: 0x{x} [{s}]", .{ @ptrToInt(list), type_str });
        },
        .Map => {
            var map: *ObjMap = ObjMap.cast(obj).?;
            var key_type_str: []const u8 = try map.type_def.resolved_type.?.Map.key_type.toString(allocator);
            defer allocator.free(key_type_str);
            var value_type_str: []const u8 = try map.type_def.resolved_type.?.Map.value_type.toString(allocator);
            defer allocator.free(value_type_str);

            return try std.fmt.bufPrint(buf, "map: 0x{x} {{{s}, {s}}}", .{ @ptrToInt(map), key_type_str, value_type_str });
        },
        .Enum => try std.fmt.bufPrint(buf, "enum: 0x{x} `{s}`", .{ @ptrToInt(ObjEnum.cast(obj).?), ObjEnum.cast(obj).?.name.string }),
        .EnumInstance => enum_instance: {
            var instance: *ObjEnumInstance = ObjEnumInstance.cast(obj).?;
            var enum_: *ObjEnum = instance.enum_ref;

            break :enum_instance try std.fmt.bufPrint(
                buf,
                "{s}.{s}",
                .{
                    enum_.name.string,
                    enum_.type_def.resolved_type.?.Enum.cases.items[instance.case]
                }
            );
        },
        .Bound => {
            var bound: *ObjBoundMethod = ObjBoundMethod.cast(obj).?;
            var receiver_str: []const u8 = try valueToString(allocator, bound.receiver);
            defer allocator.free(receiver_str);

            if (bound.closure) |closure| {
                var closure_name: []const u8 =  closure.function.name.string;
                return try std.fmt.bufPrint(buf, "bound method: {s} to {s}", .{ receiver_str, closure_name });
            } else {
                assert(bound.native != null);
                return try std.fmt.bufPrint(buf, "bound method: {s} to native 0x{}", .{ receiver_str, @ptrToInt(bound.native.?) });
            }
        },
        .Native => {
            var native: *ObjNative = ObjNative.cast(obj).?;

            return try std.fmt.bufPrint(buf, "native: 0x{x}", .{ @ptrToInt(native) });
        },
        .Error => {
            var err: *ObjError = ObjError.cast(obj).?;

            return try std.fmt.bufPrint(buf, "err: 0x{x} `{s}`", .{ @ptrToInt(err), err.message.string });
        },
        .Routine => {
            var routine: *ObjRoutine = ObjRoutine.cast(obj).?;

            return try std.fmt.bufPrint(buf, "thread: 0x{x}", .{ @ptrToInt(routine) });
        }
    };
}

pub const PlaceholderDef = struct {
    const Self = @This();

    // TODO: are relations enough and booleans useless?
    const PlaceholderRelation = enum {
        Call,
        Subscript,
        Key,
        FieldAccess,
        Assignment,
    };

    name: ?*ObjString = null,

    // Assumption made by the code referencing the value
    callable: ?bool = null,             // Function, Object or Class
    subscriptable: ?bool = null,        // Array or Map
    field_accessible: ?bool = null,     // Object, Class or Enum
    assignable: ?bool = null,           // Not a Function, Object, Class or Enum
    resolved_parameters: ?std.StringArrayHashMap(*ObjTypeDef) = null, // Maybe we resolved argument list but we don't know yet if Object/Class or Function
    resolved_def_type: ?ObjTypeDef.Type = null,    // Meta type
    // TODO: do we ever infer that much that we can build an actual type?
    resolved_type: ?*ObjTypeDef = null, // Actual type
    where: Token,                       // Where the placeholder was created

    // When accessing/calling/subscrit/assign a placeholder we produce another. We keep them linked so we
    // can trace back the root of the unknown type.
    parent: ?*ObjTypeDef = null,
    // What's the relation with the parent?
    parent_relation: ?PlaceholderRelation = null,
    // Children adds themselves here
    children: std.ArrayList(*ObjTypeDef),

    pub fn init(allocator: *Allocator, where: Token) Self {
        return Self {
            .where = where.clone(),
            .children = std.ArrayList(*ObjTypeDef).init(allocator)
        };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
    }

    pub fn link(parent: *ObjTypeDef, child: *ObjTypeDef, relation: PlaceholderRelation) !void {
        assert(parent.def_type == .Placeholder);
        assert(child.def_type == .Placeholder);

        child.resolved_type.?.Placeholder.parent = parent;
        try parent.resolved_type.?.Placeholder.children.append(child);
        child.resolved_type.?.Placeholder.parent_relation = relation;
    }

    pub fn eql(a: Self, b: Self) bool {
        if (a.resolved_parameters != null and b.resolved_parameters != null) {
            var it = a.resolved_parameters.?.iterator();
            while (it.next()) |kv| {
                if (b.resolved_parameters.?.get(kv.key_ptr.*)) |b_arg_type| {
                    return b_arg_type.eql(kv.value_ptr.*);
                } else {
                    return false;
                }
            }
        }

        return ((a.callable != null and b.callable != null and a.callable.? == b.callable.?) or a.callable == null or b.callable == null)
            and ((a.subscriptable != null and b.subscriptable != null and a.subscriptable.? == b.subscriptable.?) or a.subscriptable == null or b.subscriptable == null)
            and ((a.field_accessible != null and b.field_accessible != null and a.field_accessible.? == b.field_accessible.?) or a.field_accessible == null or b.subscriptable == null)
            and ((a.assignable != null and b.assignable != null and a.assignable.? == b.assignable.?) or a.assignable == null or b.subscriptable == null)
            and ((a.resolved_def_type != null and b.resolved_def_type != null and a.resolved_def_type.? == b.resolved_def_type.?) or a.resolved_def_type == null or b.resolved_def_type == null)
            and ((a.resolved_type != null and b.resolved_type != null and a.resolved_type.?.eql(b.resolved_type.?)) or a.resolved_type == null or b.subscriptable == null);
    }

    pub fn enrich(one: *Self, other: *Self) !void {
        one.callable = one.callable orelse other.callable;
        other.callable = one.callable orelse other.callable;

        one.subscriptable = one.subscriptable orelse other.subscriptable;
        other.subscriptable = one.subscriptable orelse other.subscriptable;

        one.field_accessible = one.field_accessible orelse other.field_accessible;
        other.field_accessible = one.field_accessible orelse other.field_accessible;

        one.assignable = one.assignable orelse other.assignable;
        other.assignable = one.assignable orelse other.assignable;

        one.resolved_def_type = one.resolved_def_type orelse other.resolved_def_type;
        other.resolved_def_type = one.resolved_def_type orelse other.resolved_def_type;

        one.resolved_type = one.resolved_type orelse other.resolved_type;
        other.resolved_type = one.resolved_type orelse other.resolved_type;

        if (other.resolved_parameters) |parameters| {
            one.resolved_parameters = try parameters.clone();
        } else if (one.resolved_parameters) |parameters| {
            other.resolved_parameters = try parameters.clone();
        }
    }

    // TODO: zig bug here
    pub fn isBasicType(self: Self, basic_type: ObjTypeDef.Type) bool {
        return (self.resolved_def_type != null and self.resolved_def_type.? == basic_type)
                or (self.resolved_type != null and self.resolved_type.?.def_type == basic_type);
    }

    pub fn isAssignable(self: *Self) bool {
        if (self.assignable == null) {
            return true;
        }

        return self.assignable.?
            and (self.resolved_def_type == null
                // TODO: method actually but right now we have no way to distinguish them
                or self.resolved_def_type.? != .Function
                or self.resolved_def_type.? != .Object)
            and (self.resolved_type == null
                // TODO: method actually but right now we have no way to distinguish them
                or self.resolved_type.?.def_type != .Function
                or self.resolved_type.?.def_type != .Object);
    }

    pub fn isCallable(self: *Self) bool {
        if (self.callable == null) {
            return true;
        }

        return self.callable.?
            and (self.resolved_def_type == null
                or self.resolved_def_type.? == .Function)
            and (self.resolved_type == null
                or self.resolved_type.?.def_type == .Function);
    }

    pub fn isFieldAccessible(self: *Self) bool {
        if (self.field_accessible == null) {
            return true;
        }

        return self.field_accessible.?
            and (self.resolved_def_type == null
                or self.resolved_def_type.? == .Object
                or self.resolved_def_type.? == .Enum
                or self.resolved_def_type.? == .EnumInstance
                or self.resolved_def_type.? == .ObjectInstance)
            and (self.resolved_type == null
                or self.resolved_type.?.def_type == .Object
                or self.resolved_type.?.def_type == .Enum
                or self.resolved_type.?.def_type == .EnumInstance
                or self.resolved_type.?.def_type == .ObjectInstance);
    }

    pub fn isSubscriptable(self: *Self) bool {
        if (self.subscriptable == null) {
            return true;
        }

        return self.subscriptable.?
            and (self.resolved_def_type == null
                or self.resolved_def_type.? == .List
                or self.resolved_def_type.? == .Map)
            and (self.resolved_type == null
                or self.resolved_type.?.def_type == .List
                or self.resolved_type.?.def_type == .Map);
    }

    pub fn isIterable(self: *Self) bool {
        return (self.resolved_def_type == null
            or self.resolved_def_type.? == .List
            or self.resolved_def_type.? == .Map
            or self.resolved_def_type.? == .Enum)
            and (self.resolved_type == null
                or self.resolved_type.?.def_type == .List
                or self.resolved_type.?.def_type == .Map
                or self.resolved_type.?.def_type == .Enum);
    }

    pub fn couldBeList(self: *Self) bool {
        return self.isSubscriptable()
            and (self.resolved_def_type == null or self.resolved_def_type.? == .List)
            and (self.resolved_type == null or self.resolved_type.?.def_type == .List);
    }

    pub fn couldBeMap(self: *Self) bool {
        return self.isSubscriptable()
            and (self.resolved_def_type == null or self.resolved_def_type.? == .Map)
            and (self.resolved_type == null or self.resolved_type.?.def_type == .Map);
    }

    pub fn couldBeObject(self: *Self) bool {
        return self.isFieldAccessible()
            and (self.resolved_def_type == null or self.resolved_def_type.? == .Object)
            and (self.resolved_type == null or self.resolved_type.?.def_type == .Object);
    }

    pub fn isCoherent(self: *Self) bool {
        if (self.resolved_def_type != null
            and self.resolved_type != null
            and @as(ObjTypeDef.Type, self.resolved_type.?.def_type) != self.resolved_def_type.?) {
            return false;
        }

        // Nothing can be called and subscrited
        if ((self.callable orelse false) and (self.subscriptable orelse false)) {
            return false;
        }

        // Nothing with fields can be subscrited
        if ((self.field_accessible orelse false) and (self.subscriptable orelse false)) {
            return false;
        }

        // `and` because we checked for compatibility earlier and those function will return true if the flag is null
        return self.isCallable() and self.isSubscriptable() and self.isFieldAccessible() and self.isAssignable();
    }
};