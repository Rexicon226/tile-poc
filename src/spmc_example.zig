const std = @import("std");
const topo = @import("topology.zig");

const Ids = enum {
    producer1,
    consumer1,
    consumer2,
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
        .producer1 = .{ .core = 0 },
        .consumer1 = .{ .core = 1 },
        .consumer2 = .{ .core = 2 },
    },
    .edges = &.{
        .{ .name = "channel", .from = .producer1, .to = .consumer1, .mode = .shared, .type = .foo, .capacity = 1024 },
        .{ .name = "channel", .from = .producer1, .to = .consumer2, .mode = .shared, .type = .foo, .capacity = 1024 },
    },
};

pub fn main() !void {
    try Topology.setup(std.heap.smp_allocator, topology, .{
        .producer1 = producer1,
        .consumer1 = consumer1,
        .consumer2 = consumer2,
    });

    std.debug.print("ending!\n", .{});
}

fn producer1(args: topology.Args(.producer1)) void {
    std.debug.print("producer 1 started up!\n", .{});
    const ring = args.channel;

    for (0..100) |i| {
        ring.push(.{ .x = @intCast(i) }) catch unreachable;
    }

    std.debug.print("producer 1 finished pushing\n", .{});
}

fn consumer1(args: topology.Args(.consumer1)) void {
    std.debug.print("consumer 1 started up!\n", .{});
    const ring = args.channel;

    var max: u64 = 0;
    while (ring.pop()) |element| {
        max = @max(max, element.x);
    }
    std.debug.print("max consumer 1: '{d}'\n", .{max});
}

fn consumer2(args: topology.Args(.consumer2)) void {
    std.debug.print("consumer 2 started up!\n", .{});
    const ring = args.channel;

    var max: u64 = 0;
    while (ring.pop()) |element| {
        max = @max(max, element.x);
    }
    std.debug.print("max consumer 2: '{d}'\n", .{max});
}
