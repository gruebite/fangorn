const std = @import("std");

pub fn Pointer(comptime T: type) type {
    return struct {
        const T = T;
        index: usize,
        epoch: usize,
        storage: usize,

        pub fn none() @This() {
            return @This(){
                .index = 0,
                .epoch = 0,
                .storage = 0,
            };
        }

        pub fn is_none(ptr: @This()) bool {
            return ptr.storage == 0;
        }
    };
}

pub fn WeakPointer(comptime T: type) type {
    return struct {
        const T = T;
        index: usize,
        epoch: usize,
        storage: usize,
    };
}

// 0 is considered invalid.
var last_storage_id: usize = 0;

pub fn Storage(comptime T: type) type {
    return struct {
        const Self = @This();

        id: usize,
        allocator: std.mem.Allocator,
        comps: std.ArrayList(T),
        refs: std.ArrayList(i32),
        sub_refs: std.ArrayList(usize),
        epochs: std.ArrayList(usize),
        free_indices: std.ArrayList(usize),

        pub fn init(allocator: std.mem.Allocator) Self {
            last_storage_id += 1;
            return Self{
                .id = last_storage_id,
                .allocator = allocator,
                .comps = std.ArrayList(T).init(allocator),
                .refs = std.ArrayList(i32).init(allocator),
                .sub_refs = std.ArrayList(usize).init(allocator),
                .epochs = std.ArrayList(usize).init(allocator),
                .free_indices = std.ArrayList(usize).init(allocator),
            };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) Self {
            return Self{
                .allocator = allocator,
                .comps = std.ArrayList(T).initCapacity(allocator, capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.comps.deinit();
            self.refs.deinit();
            self.sub_refs.deinit();
            self.epochs.deinit();
            self.free_indices.deinit();
        }

        pub fn sync(self: *Self) void {
            while (self.sub_refs.items.len > 0) {
                var sub_ref = self.sub_refs.pop();
                self.refs.items[sub_ref] -= 1;
                std.debug.assert(self.refs.items[sub_ref] >= 0);
                if (self.refs.items[sub_ref] == 0) {
                    self.epochs[sub_ref] += 1;
                    self.free_indices.append(sub_ref);
                }
            }
        }

        pub fn new(self: *Self, comp: T) !Pointer(T) {
            var index: usize = if (self.free_indices.items.len > 0) blk: {
                var idx = self.free_indices.pop();
                self.refs.items[idx] = 1;
                self.comps.items[idx] = comp;
                break :blk idx;
            } else blk: {
                try self.epochs.append(0);
                errdefer _ = self.epochs.pop();
                try self.refs.append(1);
                errdefer _ = self.refs.pop();
                try self.comps.append(comp);
                errdefer _ = self.comps.pop();
                // Increase the subref possibility.
                try self.sub_refs.resize(self.sub_refs.items.len + 1);
                break :blk self.comps.items.len - 1;
            };
            return Pointer(T){
                .index = index,
                .epoch = self.epochs.items[index],
                .storage = self.id,
            };
        }

        pub fn free(self: *Self, ptr: Pointer(T)) void {
            std.debug.assert(self.exists(ptr));
            self.sub_refs.append(ptr.index) catch unreachable;
        }

        pub fn exists(self: Self, ptr: Pointer(T)) bool {
            return ptr.index < self.comps.items.len and ptr.epoch == self.epochs.items[ptr.index] and ptr.storage == self.id;
        }

        pub fn get(self: *Self, ptr: Pointer(T)) *T {
            std.debug.assert(self.exists(ptr));
            return &self.comps.items[ptr.index];
        }

        pub fn upgrade(self: *Self, ptr: WeakPointer(T)) !?Pointer(T) {
            if (!self.exists(ptr)) {
                return null;
            }
            // Increase the subref possibility.
            try self.sub_refs.resize(self.sub_refs.items.len + 1);
            self.refs[ptr.index] += 1;
            return Pointer(T){
                .index = ptr.index,
                .epoch = ptr.epoch,
                .storage = ptr.storage,
            };
        }

        pub fn downgrade(self: *Self, ptr: Pointer(T)) WeakPointer(T) {
            std.debug.assert(self.exists(ptr));
            ptr.storage = 0;
            self.sub_refs.append(ptr.index);
            return WeakPointer(T){
                .index = ptr.index,
                .epoch = ptr.epoch,
                .storage = ptr.storage,
            };
        }

        pub fn clone(self: *Self, ptr: Pointer(T)) !Pointer(T) {
            std.debug.assert(self.exists(ptr));
            // Increase the subref possibility.
            try self.sub_refs.resize(self.sub_refs.items.len + 1);
            self.refs[ptr.index] += 1;
            return ptr.*;
        }

        pub fn iter(self: *Self) StorageIterator(T) {
            return StorageIterator(T){
                .storage = self,
                .index = 0,
            };
        }
    };
}

pub fn StorageIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        storage: *Storage(T),
        index: usize = 0,

        pub fn next(self: *Self) ?*T {
            while (self.index < self.storage.comps.items.len) : (self.index += 1) {
                if (self.storage.refs.items[self.index] > 0) {
                    self.index += 1;
                    return &self.storage.comps.items[self.index - 1];
                }
            } else {
                return null;
            }
        }
    };
}

test "basic functionality" {
    const testing = std.testing;

    const Position = struct {
        x: i32,
        y: i32,
    };

    const Velocity = struct {
        x: i32,
        y: i32,
    };

    const Storages = struct {
        positions: Storage(Position),
        velocities: Storage(Velocity),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .positions = Storage(Position).init(allocator),
                .velocities = Storage(Velocity).init(allocator),
            };
        }

        pub fn deinit(storages: *@This()) void {
            storages.positions.deinit();
            storages.velocities.deinit();
        }
    };

    const Entity = struct {
        storages: *Storages,
        pos: Pointer(Position),
        vel: Pointer(Velocity),

        pub fn init(storages: *Storages) !@This() {
            var pos = try storages.positions.new(std.mem.zeroes(Position));
            errdefer _ = storages.positions.free(pos);
            var vel = try storages.velocities.new(std.mem.zeroes(Velocity));
            errdefer _ = storages.velocities.free(vel);
            return @This(){
                .storages = storages,
                .pos = pos,
                .vel = vel,
            };
        }

        pub fn deinit(ent: *@This()) void {
            ent.storages.free(ent.pos);
            ent.storages.free(ent.vel);
        }
    };

    var storages = Storages.init(testing.allocator);
    defer storages.deinit();
    var entities = std.ArrayList(Entity).init(testing.allocator);
    defer entities.deinit();

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        var ent = try Entity.init(&storages);
        var pos = storages.positions.get(ent.pos);
        pos.x = i;
        pos.y = -i;
        try entities.append(ent);
    }

    i = 0;
    var iter = storages.positions.iter();
    while (iter.next()) |pos| : (i += 1) {
        try testing.expect(pos.x == i and pos.y == -i);
    }
}
