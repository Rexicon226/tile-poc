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
                /// Which tile will be sending the data.
                from: Id,
                /// Which tile will be recving the data.
                to: Id,
                /// The mode describes the channel relationship between the two tiles.
                ///
                /// - `readonly`, The `to` tile in this edge cannot push back onto the channel.
                ///
                /// TODO: consider adding a `writable` mode in case that is necassary. I *hope*, it isn't.
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
                        .type = Tile.Function(desc, @field(Id, tile_field.name)),
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
        };

        const Tile = struct {
            id: Id,
            info: Info,

            /// TODO: think about what other info we could describe about a tile.
            ///
            /// Some ideas:
            /// - the stack size of the forked process?
            const Info = struct {
                core: u16,
            };

            pub fn Function(desc: Description, id: Id) type {
                // record all rings which are directed at this tile and add them as parameters
                const Param = std.builtin.Type.Fn.Param;
                var params: []const Param = &.{};
                for (desc.edges) |edge| {
                    std.debug.assert(edge.to != edge.from); // uhh, don't do this?
                    std.debug.assert(@field(desc.tiles, @tagName(edge.from)) != null); // edge from disabled tile
                    std.debug.assert(@field(desc.tiles, @tagName(edge.to)) != null); // edge to disabled tile
                    if (edge.to != id and edge.from != id) continue; // nothing to do

                    const consuming = edge.to == id;
                    params = params ++ [_]Param{.{
                        .is_generic = false,
                        .is_noalias = false,
                        .type = if (consuming) switch (edge.mode) {
                            .readonly => *spsc.Consumer(edge.type, edge.capacity),
                            // TODO: we'll have writable here as well for a consumer/producer queue
                        } else *spsc.Producer(edge.type, edge.capacity),
                    }};
                }

                return @Type(.{ .@"fn" = .{
                    .params = params,
                    .calling_convention = .auto,
                    .is_generic = false,
                    .is_var_args = false,
                    .return_type = void,
                } });
            }
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

                    fn getElements(rb: *Self) [*]align(1) T {
                        const bytes: [*]u8 = @ptrCast(rb);
                        return @ptrCast(bytes + @sizeOf(Self));
                    }

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

        /// Spawns the tiles and coordinates creating the rings.
        pub fn setup(allocator: std.mem.Allocator, comptime desc: Description, funcs: desc.Functions()) !void {
            // TODO: this setup doesn't support having unique and then shared multi-consumer queues.
            var map: std.ArrayListUnmanaged(*TypeErasedRingBuffer) = try .initCapacity(allocator, desc.edges.len);
            defer map.deinit(allocator);

            // TODO: assuming that all maps are SPSC/readonly for now. we will need
            // better selection logic on whether this should share from existing maps,
            // i.e two readonly sinks + one writable source, or if each one should be seperate.
            inline for (desc.edges, 0..) |edge, i| {
                const Ring = spsc.Producer(edge.type, edge.capacity);
                const total_size = @sizeOf(Ring);

                var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
                const path = try std.fmt.bufPrintZ(&path_buffer, "/tile_ring_{d}", .{i});

                // create the shared memory
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
                try map.append(allocator, &p.erased);
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

                    // pin the tile to the specified core in the topology
                    var set: std.os.linux.cpu_set_t = @splat(0);
                    const size_in_bits = 8 * @sizeOf(usize);
                    set[tile.core / size_in_bits] |= @as(usize, 1) << @intCast(tile.core % size_in_bits);
                    try std.os.linux.sched_setaffinity(0, &set);

                    const Args = std.meta.ArgsTuple(Tile.Function(desc, id));
                    var args: Args = undefined;

                    // TODO: just assuming that the arguments will be in order of edge.to matches in the topology,
                    // should figure out a better solution, just can't see one right now
                    comptime var i: u32 = 0;
                    inline for (desc.edges, 0..) |edge, j| {
                        if (edge.to == id or edge.from == id) {
                            args[i] = @alignCast(@fieldParentPtr("erased", map.items[j]));
                            i += 1;
                        }
                    }

                    const func = @field(funcs, tile_field.name);
                    if (args.len != 0) @call(.auto, func, args) else func();

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
            while (pid_map.count() != 0) { // while there exist alive pids
                const result = std.posix.waitpid(-1, 0);
                defer std.debug.assert(pid_map.remove(result.pid));
                const pid = result.pid;
                const status = result.status;
                if (result.pid == -1) @panic("something went wrong");

                const W = std.c.W;
                if (W.IFEXITED(status))
                    log.warn("Child {d} exited with status: {d}", .{ pid, W.EXITSTATUS(status) })
                else if (W.IFSIGNALED(status))
                    log.warn("Child {d} killed by signal {d}", .{ pid, W.TERMSIG(status) })
                else if (W.IFSTOPPED(status))
                    log.warn("Child {d} stopped by signal {d}", .{ pid, W.STOPSIG(status) });
            }
        }
    };
}
