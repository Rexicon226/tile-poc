const std = @import("std");
const topo = @import("topology.zig");

const Ids = enum {
    idle,
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
        // Will just kinda set there and not do anything. For experimenting.
        .idle = .{ .core = 0 },

        // This tile will just be running without any connections.
        // As an example, request 64mb of stack size (more than the default 8mb on Linux)
        .producer1 = .{ .core = 1, .stack_size = 64 * 1024 * 1024 },

        // These tiles share a ring, where producer2 pushes and consumer1 pops.
        .producer2 = .{ .core = 6 },
        .consumer1 = .{ .core = 7 },
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
    try Topology.spawn(std.heap.smp_allocator, topology, .{
        .idle = idle,
        .producer1 = producer1,
        .producer2 = producer2,
        .consumer1 = consumer1,
    });

    std.debug.print("ending!\n", .{});
}

fn idle() !void {
    std.Thread.sleep(3 * std.time.ns_per_s);
}

fn producer1() !void {
    const stack_size = try std.posix.getrlimit(.STACK);
    std.debug.print("producer 1 started up! {d}\n", .{std.fmt.fmtIntSizeBin(stack_size.cur)});
    // does something here... but has no arguments!
    std.Thread.sleep(5 * std.time.ns_per_s);
}

fn producer2(args: topology.Args(.producer2)) !void {
    const stack_size = try std.posix.getrlimit(.STACK);
    std.debug.print("producer 2 started up! {d}\n", .{std.fmt.fmtIntSizeBin(stack_size.cur)});

    const ring = args.foo_channel;
    for (0..20) |i| {
        ring.push(.{ .x = @intCast(i) }) catch break;
        std.debug.print("pushed: {d}\n", .{i});
    }
    std.debug.print("producer 2 finished pushing\n", .{});
}

fn consumer1(args: topology.Args(.consumer1)) !void {
    const stack_size = try std.posix.getrlimit(.STACK);
    std.debug.print("consumer 1 started up! {d}\n", .{std.fmt.fmtIntSizeBin(stack_size.cur)});
    std.Thread.sleep(2 * std.time.ns_per_s);

    const ring = args.foo_channel;
    while (ring.pop()) |element| {
        std.debug.print("consumer 1 got: {d}\n", .{element.x});
    }
    std.posix.abort(); // showcase what the watchdog does on abort
}
