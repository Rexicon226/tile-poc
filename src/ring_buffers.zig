//! shared memory queues for IPC

const std = @import("std");
const Atomic = std.atomic.Value;

/// TODO: something to re-consider for later. we need some type-safe way of specifying... the types.
/// we should in theory have a pretty small and well defined list of things we want to send?
/// we want to focus on batching as much data together as possible, so this should encourage that.
pub const Types = enum(u8) {
    foo,

    pub fn Data(comptime t: Types) type {
        return switch (t) {
            .foo => Foo,
        };
    }

    const Foo = struct {
        x: u32,
    };
};

pub const TypeErasedRingBuffer = extern struct {
    head: Atomic(u64) align(std.atomic.cache_line),
    tail: Atomic(u64) align(std.atomic.cache_line),
    capacity: u64,
};

/// Producer side of SP ring buffer
pub fn Producer(comptime t: Types) type {
    return extern struct {
        type: Types, // TODO: i want to do runtime checking that we're recovering the same type
        erased: TypeErasedRingBuffer,
        // the payload just follows, we assume the ring buffer is placed at the start
        // of the shared memory region, and just the rest of it is what we're allowed to use.

        const Self = @This();
        const T = t.Data();

        pub fn init(rb: *Self, capacity: u64) void {
            rb.* = .{
                .type = t,
                .erased = .{
                    .head = .init(0),
                    .tail = .init(0),
                    .capacity = capacity,
                },
            };
        }

        fn getElements(rb: *Self) [*]align(1) T {
            const bytes: [*]u8 = @ptrCast(rb);
            return @ptrCast(bytes + @sizeOf(Self));
        }

        pub fn push(rb: *Self, element: T) !void {
            const head = rb.erased.head.load(.monotonic);
            const tail = rb.erased.tail.load(.acquire);
            const next = (head + 1) % rb.erased.capacity;
            if (next == tail) return error.RingFull;

            const elements = rb.getElements();
            elements[head] = element;

            rb.erased.head.store(next, .release);
        }
    };
}

/// Consumer side of SP ring buffer
pub fn Consumer(comptime t: Types) type {
    return extern struct {
        type: Types,
        erased: TypeErasedRingBuffer,

        const Self = @This();
        const T = t.Data();

        fn getElements(rb: *Self) [*]align(1) T {
            const bytes: [*]u8 = @ptrCast(rb);
            return @ptrCast(bytes + @sizeOf(Self));
        }

        pub fn pop(rb: *Self) ?T {
            const head = rb.erased.head.load(.acquire);
            const tail = rb.erased.tail.load(.monotonic);
            if (head == tail) return null; // empty

            const elements = rb.getElements();
            const element = elements[tail];

            const next = (tail + 1) % rb.erased.capacity;
            rb.erased.tail.store(next, .release);
            return element;
        }
    };
}
