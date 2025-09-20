const std = @import("std");
const ring_buffers = @import("ring_buffers.zig");
const TypeErasedRingBuffer = ring_buffers.TypeErasedRingBuffer;

const Description = struct {
    tiles: []const Tile,
    edges: []const Edge,

    const Edge = struct {
        from: Tile.Id,
        to: Tile.Id,
        mode: Mode,
        type: ring_buffers.Types, // TODO: move Types into topology file i think

        const Mode = enum {
            readonly,
        };
    };
};

const Tile = struct {
    id: Id,
    core: u16,

    const Id = enum {
        producer1,
        producer2,
        consumer1,

        pub fn Function(comptime id: Id, comptime edges: []const Description.Edge) type {
            // record all rings which are directed at this tile and add them as parameters
            const Param = std.builtin.Type.Fn.Param;
            var params: []const Param = &.{};
            for (edges) |edge| {
                std.debug.assert(edge.to != edge.from); // uhh, don't do this?
                if (edge.to != id and edge.from != id) continue; // nothing to do

                const consuming = edge.to == id;
                params = params ++ [_]Param{.{
                    .is_generic = false,
                    .is_noalias = false,
                    .type = if (consuming) switch (edge.mode) {
                        .readonly => *ring_buffers.Consumer(edge.type),
                        // TODO: we'll have writable here as well for a consumer/producer queue
                    } else *ring_buffers.Producer(edge.type),
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

        // TODO: we obviously have the usecase where a tile will have multiple input ring buffers,
        // either pass in a reduced enum map with a custom enum for the specific edges the tile
        // asked for, or a slice. liking the first option more so far not sure if actually possible.
        pub fn function(comptime id: Id, comptime edges: []const Description.Edge) Function(id, edges) {
            return switch (id) {
                .producer1 => producer1,
                .producer2 => producer2,
                .consumer1 => consumer1,
            };
        }
    };
};

fn Topology(comptime desc: Description) type {
    return struct {
        /// Spawns the tiles and coordinates creating the rings.
        pub fn setup(allocator: std.mem.Allocator) !void {
            // TODO: this setup doesn't support having unique and then shared multi-consumer queues.
            var map: std.ArrayListUnmanaged(*TypeErasedRingBuffer) = try .initCapacity(allocator, desc.edges.len);
            defer map.deinit(allocator);

            // TODO: assuming that all maps are SPSC/readonly for now. we will need
            // better selection logic on whether this should share from existing maps,
            // i.e two readonly sinks + one writable source, or if each one should be seperate.
            for (desc.edges, 0..) |edge, i| {
                // TODO: move to zon prob, need to research how this number should be set
                const total_elements = 1024;
                const total_size = total_elements * switch (edge.type) {
                    inline else => |t| @sizeOf(ring_buffers.Producer(t)),
                };
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

                const type_erased: *TypeErasedRingBuffer = switch (edge.type) {
                    inline else => |t| b: {
                        const Ring = ring_buffers.Producer(t);
                        const p: *Ring = @ptrCast(mapped.ptr);
                        p.init(total_elements);
                        break :b &p.erased;
                    },
                };

                try map.append(allocator, type_erased);
            }

            var pid_map: std.AutoHashMapUnmanaged(std.posix.pid_t, Tile) = .{};
            defer pid_map.deinit(allocator);

            for (desc.tiles) |tile| {
                const pid = try std.posix.fork();
                if (pid < 0) @panic("fork failed?");
                if (pid == 0) {
                    // child

                    // pin the tile to the specified core in the topology
                    var set: std.os.linux.cpu_set_t = @splat(0);
                    const size_in_bits = 8 * @sizeOf(usize);
                    set[tile.core / size_in_bits] |= @as(usize, 1) << @intCast(tile.core % size_in_bits);
                    try std.os.linux.sched_setaffinity(0, &set);

                    switch (tile.id) {
                        inline else => |id| {
                            const Args = std.meta.ArgsTuple(id.Function(desc.edges));
                            var args: Args = undefined;

                            // TODO: just assuming that the arguments will be in order of edge.to matches in the topology,
                            // should figure out a better solution, just can't see one right now
                            comptime var i: u32 = 0;
                            inline for (desc.edges, 0..) |edge, j| {
                                if (edge.to == id or edge.from == id) {
                                    args[i] = @fieldParentPtr("erased", map.items[j]);
                                    i += 1;
                                }
                            }

                            const func = id.function(desc.edges);
                            if (args.len != 0) @call(.auto, func, args) else func();
                        },
                    }

                    std.debug.print("'{s}' exiting\n", .{@tagName(tile.id)});
                    std.posix.exit(0); // tile done
                } else {
                    // parent, record the pid
                    try pid_map.put(allocator, pid, tile);
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

const topology: Description = .{
    .tiles = &.{
        // This tile will just be running without any connections.
        .{ .id = .producer1, .core = 0 },

        // These tiles share a ring, where producer2 pushes and consumer1 pops.
        .{ .id = .producer2, .core = 1 },
        .{ .id = .consumer1, .core = 2 },
    },
    .edges = &.{
        .{
            // describes the relationship above ^
            .from = .producer2,
            .to = .consumer1,
            // consumer1 can only read from the queue, it will be given one that only has a `pop` method
            .mode = .readonly,
            // the type of element being passed along the ring
            .type = .foo,
        },
    },
};

pub fn main() !void {
    const Top = Topology(topology);

    try Top.setup(std.heap.smp_allocator);

    std.debug.print("ending!\n", .{});
}

fn producer1() void {
    std.debug.print("producer 1 started up!\n", .{});
    // does something here... but has no arguments!
}

fn producer2(ring: *ring_buffers.Producer(.foo)) void {
    std.debug.print("producer 2 started up!\n", .{});
    for (0..10) |i| {
        ring.push(.{ .x = @intCast(i) }) catch unreachable; // not pushing enough elements for it to fill up
    }
    std.debug.print("producer 2 finished pushing\n", .{});
}

fn consumer1(ring: *ring_buffers.Consumer(.foo)) void {
    std.debug.print("consumer 1 started up!\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    while (ring.pop()) |element| {
        std.debug.print("consumer 1 got: {}\n", .{element});
    }

    std.posix.abort();
}
