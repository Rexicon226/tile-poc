const std = @import("std");
const topo = @import("topology.zig");

const Ids = enum {
    producer1,
    producer2,
    consumer1,
};

const Types = enum {
    foo,

    pub fn Data(comptime t: Types) type {
        return switch (t) {
            .foo => Foo,
        };
    }

    const Foo = struct {
        x: u32 align(64),
    };
};

const Topology = topo.Topology(Ids, Types);

const topology: Topology.Description = .{
    .tiles = .{
        // This tile will just be running without any connections.
        .producer1 = .{ .core = 0 },

        // These tiles share a ring, where producer2 pushes and consumer1 pops.
        .producer2 = .{ .core = 1 },
        .consumer1 = .{ .core = 2 },
    },
    .edges = &.{
        .{
            .name = "foo_channel",
            // describes the relationship in the previous sentence ^
            .from = .producer2,
            .to = .consumer1,
            // consumer1 can only read from the queue, it will be given one that only has a `pop` method
            .mode = .readonly,
            // the type of element being passed along the ring
            .type = .foo,
            .capacity = 1024,
        },
    },
};

pub fn main() !void {
    try Topology.setup(std.heap.smp_allocator, topology, .{
        .producer1 = producer1,
        .producer2 = producer2,
        .consumer1 = consumer1,
    });

    std.debug.print("ending!\n", .{});
}

fn producer1(_: topology.Args(.producer1)) void {
    std.debug.print("producer 1 started up!\n", .{});
    // does something here... but has no arguments!
}

fn producer2(args: topology.Args(.producer2)) void {
    const ring = args.foo_channel;
    std.debug.print("producer 2 started up!\n", .{});
    for (0..20) |i| {
        ring.push(.{ .x = @intCast(i) }) catch break;
        std.debug.print("pushed: {d}\n", .{i});
    }
    std.debug.print("producer 2 finished pushing\n", .{});
}

fn consumer1(args: topology.Args(.consumer1)) void {
    const ring = args.foo_channel;
    std.debug.print("consumer 1 started up!\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);
    while (ring.pop()) |element| {
        std.debug.print("consumer 1 got: {}\n", .{element});
    }
    std.posix.abort(); // showcase what the watchdog does on abort
}
