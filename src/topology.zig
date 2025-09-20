const std = @import("std");
const Atomic = std.atomic.Value;

pub fn Topology(comptime Id: type, comptime Types: type) type {
    return struct {
        /// Describes the layout of the tile topology.
        pub const Description = struct {
            /// If a tile is null in the description, it is not spawned and any edges that are
            /// trying to use it will compile error.
            tiles: std.enums.EnumFieldStruct(Id, ?Tile.Info, null),
            edges: []const Edge,

            /// Describes a communication channel between two tiles.
            const Edge = struct {
                /// What the edge will be called in the `from` and `to` tile function arguments.
                /// We only have one name shared across the two tiles in order to make it clearer
                /// which channel does what. There is no possiblity of confusing, since the naming
                /// is shared across implementations.
                ///
                /// A couple rules:
                ///
                /// - A tile A cannot have two edges (no matter if it is `from` or `to`) which have
                /// the same name. e.g. if a tile A and B share an edge called "foo", tile B cannot
                /// have an edge with tile C called "foo".
                ///
                /// - If a tile A and B share an edge "foo", and a tile C and D share an edge "foo",
                /// that is completely legal. The only thing that matters is that in between each tile,
                /// the edges it is a part of do not collide in names.
                ///
                /// Both of these properties are asserted at compile-time.
                name: []const u8,
                /// Which tile will be sending the data.
                from: Id,
                /// Which tile will be recving the data.
                to: Id,
                /// The mode describes the channel relationship between the two tiles.
                ///
                /// - `readonly`, The `to` tile in this edge cannot push back onto the channel.
                /// - `shared`, The `from` tile in this edge will have multiple consumer tiles,
                /// and it will switch to using an spmc queue instead of a spsc one. Both the
                /// `from` and `to` tiles need to indicate `shared` mode in their respective edges.
                /// Which edge is shared is determined by the name, they must match in all edges.
                ///
                /// TODO: consider adding a `writable` mode in case that is necassary. I *hope*, it isn't.
                ///
                /// TODO: check that for `shared` edges, the `from` node really does have multiple consumers.
                /// or maybe not, if we want it to be a bit more generic.
                ///
                /// TODO: currently there is no error when we create a `readonly` edge between tile A and B
                /// and then a `shared` edge between tile A and C. there should be! if more than two tiles
                /// are using a ring, it should be shared from all sides.
                mode: Mode,
                /// The type of the data moved across the channel. We express this is a finite list of
                /// possibilities, since we want to encourage as little different `Types` as possible,
                /// thus focusing on batching data and less traffic between tiles.
                type: Types,
                /// The number of elements (measured in elements, *not* bytes) the ring buffer can store.
                /// If you attempt to `push` onto the channel when it is full, `error.RingFull` will be
                /// returned indicating this.
                ///
                /// TODO: consider having shared wait events inside of the buffers, so that we can
                /// express something like:
                ///
                /// Tile A runs much faster than Tile B does in terms of the ring. Assuming that Tile B
                /// is running at-least fast enough to keep up with the rest of the validator (so it
                /// isn't a critical performance issue), we should be able to consistently put Tile A
                /// to sleep until more room is made available (or perhaps it just skips past the
                /// processing step involving Tile B and works with some other tiles).
                /// This can be achieved through wait-events or some sort of waker/poll API.
                capacity: u64,

                const Mode = enum {
                    readonly,
                    // TODO: consider moving shared/unique into a seperate config, although i
                    // do like the fact that shared implies readonly on recv, since we *really* want to
                    // avoid mpmc rings, they should just not be needed at any point in time.
                    shared,
                };
            };

            /// Returns a struct where each field represents an active tile, and the field type
            /// is the tile function signature required to fulfill the edges.
            fn Functions(comptime desc: Description) type {
                var fields: []const std.builtin.Type.StructField = &.{};
                for (@typeInfo(@TypeOf(desc.tiles)).@"struct".fields) |tile_field| {
                    // if this tile is disabled, just continue to the next one
                    if (@field(desc.tiles, tile_field.name) == null) continue;

                    fields = fields ++ [_]std.builtin.Type.StructField{.{
                        .name = tile_field.name,
                        .type = Function(desc, @field(Id, tile_field.name)),
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = 0,
                    }};
                }

                return @Type(.{ .@"struct" = .{
                    .layout = .auto,
                    .decls = &.{},
                    .fields = fields,
                    .backing_integer = null,
                    .is_tuple = false,
                } });
            }

            /// Returns the function type required for a tile to satisfy the topology provided
            fn Function(desc: Description, id: Id) type {
                const A = Args(desc, id);
                const has_parameters = @typeInfo(A).@"struct".fields.len != 0;
                return @Type(.{ .@"fn" = .{
                    .params = if (has_parameters) &.{.{
                        .type = Args(desc, id),
                        .is_generic = false,
                        .is_noalias = false,
                    }} else &.{},
                    .calling_convention = .auto,
                    .is_generic = false,
                    .is_var_args = false,
                    .return_type = anyerror!void,
                } });
            }

            /// Creates the `args` parameter for tile functions based off of what edges they need to work with.
            pub fn Args(desc: Description, id: Id) type {
                const StructField = std.builtin.Type.StructField;
                var fields: []const StructField = &.{};
                edges: for (desc.edges, 0..) |edge, i| {
                    std.debug.assert(edge.to != edge.from); // uhh, don't do this?
                    std.debug.assert(@field(desc.tiles, @tagName(edge.from)) != null); // edge from disabled tile
                    std.debug.assert(@field(desc.tiles, @tagName(edge.to)) != null); // edge to disabled tile
                    if (edge.to != id and edge.from != id) continue; // nothing to do

                    const consuming = edge.to == id;
                    if (edge.mode == .shared and !consuming) {
                        // have we already seen and created a field for a shared producer?
                        // - if so, just skip creating this field, since they'll be shared.
                        // - if the `shared` mode isn't indicated, there will be a compile error
                        // due to duplicate struct fields.
                        for (desc.edges[0..i]) |previous| if (previous.from == id) continue :edges;
                    }

                    const Producer = switch (edge.mode) {
                        .readonly => spsc.Producer(edge.type, edge.capacity),
                        .shared => spmc.Producer(edge.type, edge.capacity),
                    };
                    const Consumer = switch (edge.mode) {
                        .readonly => spsc.Consumer(edge.type, edge.capacity),
                        .shared => spmc.Consumer(edge.type, edge.capacity),
                    };

                    fields = fields ++ [_]StructField{.{
                        .name = edge.name ++ "",
                        .type = if (consuming) *Consumer else *Producer,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(*Producer),
                    }};
                }

                return @Type(.{ .@"struct" = .{
                    .fields = fields,
                    .decls = &.{},
                    .backing_integer = null,
                    .is_tuple = false,
                    .layout = .auto,
                } });
            }

            fn validate(desc: Description) void {
                // ensure all consumers of shared edges use `shared` mode
                {
                    // first we find all producer_id + name pairs in the edges, and note down
                    // if we see any more than once (those are the ones that need to be shared!)
                    var seen: []const MapKey = &.{};
                    var should_be_shared: []const MapKey = &.{};
                    edges: for (desc.edges) |edge| {
                        const key: MapKey = .fromEdge(edge);
                        for (seen) |p| {
                            if (MapKey.Context.eql(.{}, p, key)) {
                                // we've already seen this edge
                                should_be_shared = should_be_shared ++ &[_]MapKey{key};
                                continue :edges;
                            }
                        } else {
                            seen = seen ++ &[_]MapKey{key};
                        }
                    }

                    // go through the list again and ensure that all of the edges on the `should_be_shared`, are infact shared
                    for (desc.edges) |edge| {
                        const key: MapKey = .fromEdge(edge);
                        for (should_be_shared) |p| {
                            if (MapKey.Context.eql(.{}, p, key) and edge.mode != .shared) {
                                @compileError("edge '" ++ edge.name ++ "' from producer '" ++ @tagName(edge.from) ++
                                    "' is used by more than two tiles, but not indicated as `shared`");
                            }
                        }
                    }
                }
            }
        };

        const Tile = struct {
            id: Id,
            info: Info,

            const Info = struct {
                /// Which core number the tile will be pinned to. Indexed from 0.
                core: u16,
                /// If set, `setrlimit` will be called until the stack size require is fullfilled
                /// for that fork. Useful when we have individual tiles that require more stack
                /// than simpler ones.
                ///
                /// NOTE: a bit of experimenting shows that `setrlimit` is in-fact per-process, so
                /// each fork can have a different amount.
                stack_size: ?u64 = null,
            };
        };

        pub const TypeErasedRingBuffer = struct {
            head: Atomic(u64) align(std.atomic.cache_line),
            tail: Atomic(u64) align(std.atomic.cache_line),
            type: Types,
        };

        pub const spsc = struct {
            /// Producer side of SP ring buffer
            pub fn Producer(comptime t: Types, comptime capacity: comptime_int) type {
                return struct {
                    elements: [capacity]T,
                    erased: TypeErasedRingBuffer,

                    const Self = @This();
                    const T = t.Data();

                    const mask = capacity - 1;

                    pub fn init(rb: *Self) void {
                        rb.* = .{
                            .erased = .{
                                .head = .init(0),
                                .tail = .init(0),
                                .type = t,
                            },
                            .elements = undefined,
                        };
                    }

                    pub fn push(rb: *Self, element: T) !void {
                        std.debug.assert(t == rb.erased.type);

                        const head = rb.erased.head.load(.acquire);
                        const tail = rb.erased.tail.raw;
                        if (head +% 1 -% tail > capacity) return error.RingFull;

                        rb.elements[head & mask] = element;
                        rb.erased.head.store(head +% 1, .release);
                    }
                };
            }

            /// Consumer side of SP ring buffer
            pub fn Consumer(comptime t: Types, comptime capacity: comptime_int) type {
                return struct {
                    elements: [capacity]T,
                    erased: TypeErasedRingBuffer,

                    const Self = @This();
                    const T = t.Data();

                    const mask = capacity - 1;

                    pub fn pop(rb: *Self) ?T {
                        std.debug.assert(t == rb.erased.type);

                        const tail = rb.erased.tail.load(.acquire);
                        const head = rb.erased.head.raw;
                        if (tail -% head == 0) return null;
                        const element = rb.elements[tail & mask];
                        rb.erased.tail.store(tail +% 1, .release);
                        return element;
                    }
                };
            }
        };

        pub const spmc = struct {
            pub fn Producer(comptime t: Types, comptime capacity: comptime_int) type {
                return struct {
                    elements: [capacity]T,
                    erased: TypeErasedRingBuffer,

                    const Self = @This();
                    const T = t.Data();

                    pub fn init(rb: *Self) void {
                        rb.* = .{
                            .erased = .{
                                .head = .init(std.math.maxInt(u64)),
                                .tail = .init(std.math.maxInt(u64)),
                                .type = t,
                            },
                            .elements = undefined,
                        };
                    }

                    pub fn push(rb: *Self, element: T) !void {
                        const head = rb.erased.head.load(.acquire);
                        const tail = rb.erased.tail.load(.acquire);
                        if (tail -% head == capacity) return error.RingFull;

                        const idx = tail % capacity;
                        rb.elements[idx] = element;

                        rb.erased.tail.store(tail +% 1, .release);
                    }
                };
            }

            pub fn Consumer(comptime t: Types, comptime capacity: comptime_int) type {
                return struct {
                    elements: [capacity]T,
                    erased: TypeErasedRingBuffer,

                    const Self = @This();
                    const T = t.Data();

                    pub fn pop(rb: *Self) ?T {
                        var head = rb.erased.head.load(.acquire);

                        while (true) {
                            const tail = rb.erased.tail.load(.acquire);
                            if (tail == head) return null;

                            // try to install new head index
                            if (rb.erased.head.cmpxchgWeak(
                                head,
                                head +% 1,
                                .acq_rel,
                                .acquire,
                            )) |new| {
                                head = new;
                                continue;
                            } else {
                                // TODO: fence here before, but i'm not sure what it was doing, investigate
                                // TODO: what happens if we push a ton of things before installation and
                                // the read, how to ensure this read stays valid. i.e pop thread suspended.

                                // won the race, it's now safe to read the element,
                                // nothing else should try to touch it
                                return rb.elements[head % capacity];
                            }
                        }
                    }
                };
            }
        };

        const MapKey = struct {
            id: Id,
            name: []const u8,

            fn fromEdge(edge: Description.Edge) MapKey {
                return .{
                    .id = edge.from,
                    .name = edge.name,
                };
            }

            pub const Context = struct {
                pub fn hash(_: Context, a: MapKey) u64 {
                    var hasher = std.hash.Wyhash.init(0);
                    std.hash.autoHash(&hasher, a.id);
                    hasher.update(a.name);
                    return hasher.final();
                }

                pub fn eql(_: Context, a: MapKey, b: MapKey) bool {
                    return a.id == b.id and std.mem.eql(u8, a.name, b.name);
                }
            };
        };

        const Map = std.HashMapUnmanaged(
            MapKey,
            *TypeErasedRingBuffer,
            MapKey.Context,
            std.hash_map.default_max_load_percentage,
        );

        /// Spawns the tiles and coordinates creating the rings.
        pub fn spawn(
            allocator: std.mem.Allocator,
            comptime desc: Description,
            funcs: desc.Functions(),
        ) !void {
            comptime desc.validate();

            var map: Map = .{};
            defer map.deinit(allocator);

            inline for (desc.edges, 0..) |edge, i| {
                const gop = try map.getOrPut(allocator, .fromEdge(edge));

                if (gop.found_existing) {
                    // if two edges share the same "from" and "name",
                    // it must be a ring shared between multiple consumers
                    std.debug.assert(edge.mode == .shared);
                } else {
                    const Ring = spsc.Producer(edge.type, edge.capacity);
                    const total_size = @sizeOf(Ring);

                    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
                    const path = try std.fmt.bufPrintZ(&path_buffer, "/tile_ring_{d}", .{i});
                    const fd = std.c.shm_open(path, @bitCast(std.c.O{
                        .CREAT = true,
                        .ACCMODE = .RDWR,
                    }), 0o600);
                    if (fd < 0) @panic("failed to shm_open");
                    if (std.c.ftruncate(fd, total_size) != 0) @panic("failed to ftruncate");
                    const mapped = try std.posix.mmap(
                        null,
                        total_size,
                        std.posix.PROT.READ | std.posix.PROT.WRITE,
                        .{ .TYPE = .SHARED },
                        fd,
                        0,
                    );

                    const p: *Ring = @ptrCast(mapped.ptr);
                    p.init();
                    gop.value_ptr.* = &p.erased;
                }
            }

            var pid_map: std.AutoHashMapUnmanaged(std.posix.pid_t, Tile) = .{};
            defer pid_map.deinit(allocator);

            inline for (@typeInfo(@TypeOf(desc.tiles)).@"struct".fields) |tile_field| {
                const tile = @field(desc.tiles, tile_field.name) orelse continue; // don't spawn disabled tiles
                const id = @field(Id, tile_field.name);

                const pid = try std.posix.fork();
                if (pid < 0) @panic("fork failed?");
                if (pid == 0) {
                    // child
                    // we *cannot* return errors from within the fork,
                    // since it could lead to unexpected execution outside this function
                    errdefer comptime unreachable;

                    runTile(tile, id, desc, funcs, tile_field.name, &map) catch |err| {
                        std.debug.print(
                            "'{s}' failed with error: {s}\n",
                            .{ @tagName(id), @errorName(err) },
                        );
                        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
                        std.debug.print("'{s}': aborting", .{@tagName(id)});
                        std.posix.abort();
                    };

                    std.debug.print("'{s}' exiting\n", .{@tagName(id)});
                    std.posix.exit(0); // tile done
                } else {
                    // parent, record the pid
                    try pid_map.put(allocator, pid, .{
                        .id = id,
                        .info = tile,
                    });
                }
            }

            // we begin the role of watchdog now, listening for any failures with the tiles
            const log = std.log.scoped(.watchdog);
            while (true) { // keep running until a child dies
                const result = std.posix.waitpid(-1, 0);
                defer std.debug.assert(pid_map.remove(result.pid));
                const pid = result.pid;
                const status = result.status;
                if (pid == -1) @panic("something went wrong");

                const W = std.c.W;
                if (W.IFEXITED(status))
                    log.warn("Child {d} exited with status: {d}", .{ pid, W.EXITSTATUS(status) })
                else if (W.IFSIGNALED(status))
                    log.warn("Child {d} killed by signal {d}", .{ pid, W.TERMSIG(status) })
                else if (W.IFSTOPPED(status))
                    log.warn("Child {d} stopped by signal {d}", .{ pid, W.STOPSIG(status) });
            }
        }

        fn runTile(
            tile: Tile.Info,
            comptime id: Id,
            comptime desc: Description,
            funcs: desc.Functions(),
            comptime tile_name: []const u8,
            map: *const Map,
        ) !void {
            // setup the info requested of this tile.
            {
                // pin the tile to the specified core in the topology
                var set: std.os.linux.cpu_set_t = @splat(0);
                const size_in_bits = 8 * @sizeOf(usize);
                set[tile.core / size_in_bits] |= @as(usize, 1) << @intCast(tile.core % size_in_bits);
                try std.os.linux.sched_setaffinity(0, &set);

                // configure the stack size
                if (tile.stack_size) |stack_size| {
                    var rl = try std.posix.getrlimit(.STACK);
                    if (rl.cur < stack_size) {
                        rl.cur = stack_size;
                        try std.posix.setrlimit(.STACK, rl);
                    }
                }

                // set the name of the process to the id, doesn't require a pid
                switch (@as(std.posix.E, @enumFromInt(try std.posix.prctl(
                    .SET_NAME,
                    .{@intFromPtr(@tagName(id).ptr)},
                )))) {
                    .SUCCESS => {},
                    else => |e| return std.posix.unexpectedErrno(e),
                }
            }

            // TODO: there are a few nested loops here, not sure how to optimize yet, but doesn't really matter for perf.
            const Args = desc.Args(id);
            var args: Args = undefined;
            inline for (@typeInfo(Args).@"struct".fields) |field| {
                // find the `from` which will key into the map with the arg field name to find the ring we need to use
                const from_id = inline for (desc.edges) |edge| {
                    if ((edge.to == id or edge.from == id) and
                        std.mem.eql(u8, edge.name, field.name)) break edge.from;
                } else unreachable;

                @field(args, field.name) = @alignCast(@fieldParentPtr("erased", map.get(.{
                    .id = from_id,
                    .name = field.name,
                }).?));
            }

            const func = @field(funcs, tile_name);
            const arguments = if (@typeInfo(Args).@"struct".fields.len == 0) .{} else .{args};
            try @call(.auto, func, arguments);
        }
    };
}
