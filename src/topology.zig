const std = @import("std");
const linux = std.os.linux;
const Atomic = std.atomic.Value;
const W = std.c.W;

pub fn Topology(comptime Id: type, comptime Types: type) type {
    return struct {
        const num_tiles = @typeInfo(Id).@"enum".fields.len;

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
            pub fn Functions(comptime desc: Description) type {
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
            pipefds: [2]std.posix.fd_t,
        ) !void {
            comptime desc.validate();

            std.posix.close(pipefds[0]);

            // TODO: perhaps needs rework after we move over the sandboxed version
            var map: Map = .{};
            defer map.deinit(allocator);

            // inline for (desc.edges, 0..) |edge, i| {
            //     const gop = try map.getOrPut(allocator, .fromEdge(edge));

            //     if (gop.found_existing) {
            //         // if two edges share the same "from" and "name",
            //         // it must be a ring shared between multiple consumers
            //         std.debug.assert(edge.mode == .shared);
            //     } else {
            //         const Ring = spsc.Producer(edge.type, edge.capacity);
            //         const total_size = @sizeOf(Ring);

            //         var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
            //         const path = try std.fmt.bufPrintZ(&path_buffer, "/tile_ring_{d}", .{i});
            //         const fd = std.c.shm_open(path, @bitCast(std.c.O{
            //             .CREAT = true,
            //             .ACCMODE = .RDWR,
            //         }), 0o600);
            //         if (fd < 0) @panic("failed to shm_open");
            //         if (std.c.ftruncate(fd, total_size) != 0) @panic("failed to ftruncate");
            //         const mapped = try std.posix.mmap(
            //             null,
            //             total_size,
            //             std.posix.PROT.READ | std.posix.PROT.WRITE,
            //             .{ .TYPE = .SHARED },
            //             fd,
            //             0,
            //         );

            //         const p: *Ring = @ptrCast(mapped.ptr);
            //         p.init();
            //         gop.value_ptr.* = &p.erased;
            //     }
            // }

            // var pid_map: std.AutoHashMapUnmanaged(std.posix.pid_t, Tile) = .{};
            // defer pid_map.deinit(allocator);

            // TODO: store and restore the affinity of the pid process.
            // we don't want it left stuck on the same core as an important tile.

            // + 1 for the main process pipe as well
            var fds: std.BoundedArray(std.posix.pollfd, num_tiles + 1) = .{};
            var child_pids: std.BoundedArray(std.posix.pid_t, num_tiles) = .{};
            var child_names: std.BoundedArray([]const u8, num_tiles) = .{};

            inline for (@typeInfo(@TypeOf(desc.tiles)).@"struct".fields) |tile_field| {
                const tile = @field(desc.tiles, tile_field.name) orelse continue; // don't spawn disabled tiles
                const id = @field(Id, tile_field.name);

                const child_pipefd = try std.posix.pipe2(.{ .CLOEXEC = true });
                try fds.append(.{ .fd = child_pipefd[0], .events = 0, .revents = 0 });
                try child_pids.append(try runTile(
                    tile,
                    id,
                    desc,
                    funcs,
                    &map,
                    child_pipefd[1],
                ));
                try child_names.append(tile_field.name);
                std.posix.close(child_pipefd[1]);
            }

            // TODO: some sort of sandboxing for the pid process as well

            // Wait for all of the child process PIDs to die in order for them to not show up.
            for (child_pids.constSlice(), child_names.constSlice()) |pid, name| {
                const result = std.posix.wait4(pid, __WALL, null);
                if (pid != result.pid) {
                    @panic("wait4() return an unexpected pid");
                } else if (!W.IFEXITED(result.status)) {
                    std.debug.panic(
                        "tile: '{s}' exited while booting with code: {d}",
                        .{ name, W.TERMSIG(result.status) },
                    );
                }
                const exit_code = W.EXITSTATUS(result.status);
                if (exit_code != 0) {
                    std.debug.panic("tile: '{s}' exited with code: {d}", .{ name, exit_code });
                }
            }

            // place the main pipe last
            try fds.append(.{ .fd = pipefds[1], .events = 0, .revents = 0 });

            while (true) {
                _ = try std.posix.poll(fds.slice(), -1);

                for (fds.constSlice(), 0..) |fd, i| {
                    if (fd.revents != 0) {
                        if (i == num_tiles) std.posix.exit(0); // parent is dead
                        const tile_name = child_names.get(i);

                        // reap the child process
                        var wstatus: u32 = undefined;
                        const rc = linux.wait4(-1, &wstatus, __WALL | std.posix.W.NOHANG, null);
                        switch (std.posix.errno(rc)) {
                            .SUCCESS => continue, // spurious wakeup
                            else => unreachable,
                        }

                        if (W.IFEXITED(wstatus)) {
                            const exit_code = W.EXITSTATUS(wstatus);
                            if (exit_code == 0) {
                                std.debug.print("tile: '{s}' exited with exit code zero\n", .{});
                            } else {
                                std.debug.print("tile: '{s}' exited with code: {d}\n", .{exit_code});
                                std.posix.exit(exit_code);
                            }
                        } else {
                            std.debug.print("tile: '{s}' exited with signal: {d}\n", .{ tile_name, W.TERMSIG(wstatus) });
                            std.posix.exit(1);
                        }
                    }
                }
            }
        }

        fn runTile(
            tile: Tile.Info,
            comptime id: Id,
            comptime desc: Description,
            funcs: desc.Functions(),
            map: *const Map,
            pipefd: std.posix.fd_t,
        ) !std.posix.pid_t {
            _ = funcs;
            _ = map;

            // setup the info requested of this tile.
            {
                // pin the tile to the specified core in the topology. we set the affinity before the clone
                // in order to ensure the kernel only touches the tile on the right core.
                var set: std.os.linux.cpu_set_t = @splat(0);
                const size_in_bits = 8 * @sizeOf(usize);
                set[tile.core / size_in_bits] |= @as(usize, 1) << @intCast(tile.core % size_in_bits);
                try std.os.linux.sched_setaffinity(0, &set);
            }

            // remove CLOEXEC from the side of the pipe we're sending to the tile
            _ = try std.posix.fcntl(pipefd, std.posix.F.SETFD, 0);
            const fork_pid = try std.posix.fork();
            if (fork_pid == 0) {
                // child
                // now we setup the execve call to isolate the address space

                // TODO: redo this, uhhh, yeah....
                var self_exe_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
                const self_exe_path = try std.fs.selfExePath(&self_exe_buffer);
                self_exe_buffer[self_exe_path.len] = 0;
                const self_exe_path_z = self_exe_buffer[0..self_exe_path.len :0];
                const args: [*:null]const ?[*:0]const u8 = &.{ self_exe_path_z, "run-tile", @tagName(id) };
                return std.posix.execveZ(self_exe_path_z, args, &.{});
            } else {
                _ = try std.posix.fcntl(pipefd, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
                return fork_pid;
            }

            // // TODO: there are a few nested loops here, not sure how to optimize yet, but doesn't really matter for perf.
            // const Args = desc.Args(id);
            // var args: Args = undefined;
            // inline for (@typeInfo(Args).@"struct".fields) |field| {
            //     // find the `from` which will key into the map with the arg field name to find the ring we need to use
            //     const from_id = inline for (desc.edges) |edge| {
            //         if ((edge.to == id or edge.from == id) and
            //             std.mem.eql(u8, edge.name, field.name)) break edge.from;
            //     } else unreachable;

            //     @field(args, field.name) = @alignCast(@fieldParentPtr("erased", map.get(.{
            //         .id = from_id,
            //         .name = field.name,
            //     }).?));
            // }

        }
    };
}

const STACK_SIZE = 8 << 20;
const NORMAL_PAGE_SIZE = std.heap.page_size_min;
const __WALL = 0x40000000; // Wait on all children regardless of type.

/// Performs a very similar function to `std.Thread`, however it runs the functions in a NEWPID and backed by a large page stack.
pub const PidIsolation = struct {
    /// Creates a child of the main process in a new PID namespace. We hold an open
    /// pipe to it in order to give the child the ability to poll whether the parent
    /// is still alive. For the parent to check, it can just waitpid.
    pub fn spawn(comptime func: anytype, args: anytype) !std.posix.fd_t {
        const Args = @TypeOf(args);
        const S = struct {
            fn entryFunction(raw_arg: usize) callconv(.c) u8 {
                const args_ptr: *Args = @ptrFromInt(raw_arg);
                @call(.auto, func, args_ptr.*) catch |err| {
                    std.debug.print("error: {s}\n", .{@errorName(err)});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                    std.posix.abort(); // kills main process
                };
                return 0;
            }
        };

        const map_size = STACK_SIZE + (2 * NORMAL_PAGE_SIZE);
        const memory = try std.posix.mmap(
            null,
            map_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );

        // create zones above and below the mmaped stack to guard against access
        const lo_region = memory[0..NORMAL_PAGE_SIZE];
        const hi_region = memory[NORMAL_PAGE_SIZE + STACK_SIZE ..][0..NORMAL_PAGE_SIZE];

        std.posix.munmap(lo_region);
        std.posix.munmap(hi_region);

        if ((try std.posix.mmap(
            lo_region.ptr,
            NORMAL_PAGE_SIZE,
            std.posix.PROT.NONE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
            -1,
            0,
        )).ptr != lo_region.ptr) @panic("failed to init lo_region");
        if ((try std.posix.mmap(
            hi_region.ptr,
            NORMAL_PAGE_SIZE,
            std.posix.PROT.NONE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
            -1,
            0,
        )).ptr != hi_region.ptr) @panic("failed to init hi_region");

        const stack = memory[NORMAL_PAGE_SIZE..][0..STACK_SIZE];
        const rc = linux.clone(
            &S.entryFunction,
            @intFromPtr(stack.ptr + STACK_SIZE),
            linux.CLONE.NEWPID, // new pid namespace, TODO: needs root perms to use NEWPID?
            @intFromPtr(&args),
            null,
            0,
            null,
        );
        switch (std.os.linux.E.init(rc)) {
            .SUCCESS => {},
            else => |errno| std.debug.panic("clone failed with: {s}", .{@tagName(errno)}),
        }

        return @intCast(rc);
    }
};
