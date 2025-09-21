const std = @import("std");
const linux = std.os.linux;

const topo = @import("topology.zig");

const Ids = enum {
    idle,
};

const Types = enum {};

const Topology = topo.Topology(Ids, Types);

const topology: Topology.Description = .{
    .tiles = .{
        .idle = .{ .core = 0 },
    },
    .edges = &.{},
};

pub fn main() !void {
    const functions = topology.Functions(){ .idle = idle };

    const args = std.os.argv;
    if (args.len > 1) {
        const sub_command = std.mem.span(args[1]);
        std.debug.assert(std.mem.eql(u8, sub_command, "run-tile"));

        const tile_name = std.mem.span(args[2]);
        inline for (@typeInfo(@TypeOf(functions)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, tile_name)) {
                const func = @field(functions, field.name);
                _ = try topo.PidIsolation.spawn(
                    func,
                    .{},
                );
            }
        }
        return;
    }

    const pipefd = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    const pid_namespace = try topo.PidIsolation.spawn(
        Topology.spawn,
        .{
            std.heap.smp_allocator,
            topology,
            functions,
            pipefd,
        },
    );
    std.posix.close(pipefd[1]);

    const __WALL = 0x40000000; // Wait on all children regardless of type.
    const result = std.posix.wait4(pid_namespace, __WALL, null);
    const W = std.c.W;
    if (W.IFEXITED(result.status))
        std.debug.print("PidNamespace exited with status: {d}\n", .{W.EXITSTATUS(result.status)})
    else if (W.IFSIGNALED(result.status))
        std.debug.print("PidNamespace killed by signal {d}\n", .{W.TERMSIG(result.status)})
    else if (W.IFSTOPPED(result.status))
        std.debug.print("PidNamespace stopped by signal {d}\n", .{W.STOPSIG(result.status)});

    std.debug.print("main process exiting!\n", .{});
}

fn idle() !void {
    std.debug.print("idle spawned\n", .{});
    std.Thread.sleep(1 * std.time.ns_per_s);

    while (true) {}
}
