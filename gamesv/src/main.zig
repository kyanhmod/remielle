const builtin = @import("builtin");
const is_debug = builtin.mode == .debug;

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const net = std.Io.net;
const Random = std.Random;
const process = std.process;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Threaded = std.Io.Threaded;
const Allocator = std.mem.Allocator;
const DefaultCsprng = std.Random.DefaultCsprng;

const remielle = @import("remielle");
const assets = remielle.assets;
const protocol = remielle.protocol;
const protobuf = remielle.protobuf;
const Evented = remielle.io.Evented;

const logic = @import("logic.zig");
const messaging = @import("messaging.zig");
const Persistent = @import("Persistent.zig");

const initial_xorpad: *const [4096]u8 = @embedFile("initial_xorpad");

const recv_buffer_size = 32 * 1024;
const send_buffer_size = 32 * 1024;

const log = std.log.scoped(.@"remielle-gamesv");

pub const Args = struct {
    @"--listen-address": []const u8 = "127.0.0.1:20501",
    @"--concurrency": u32 = 16,
    @"--require-secure-random": bool = true,
};

pub const std_options: std.Options = .{
    .logFn = remielle.log.logFn,
};

var evented_instance: Evented = undefined;
var threaded_instance: Threaded = undefined;

const io_mode: remielle.io.Mode = .configured;

fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-gamesv [options]
        \\
        \\Options:
        \\  --help, -h                Print this help and exit
        \\  --listen-address          TCP listen address; default is {q}
        \\  --concurrency             Limit of concurrent connections; default is {d}
        \\  --require-secure-random   Whether to abort on entropy unavailability; default is {any}
        \\
    , .{
        defaults.@"--listen-address",
        defaults.@"--concurrency",
        defaults.@"--require-secure-random",
    })) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    process.exit(1);
}

pub fn main(init: process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const gpa = if (is_debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer if (is_debug) arena.deinit();

    const io = switch (io_mode) {
        .evented => evented: {
            evented_instance = try .init(gpa, .{
                .coroutine_limit = .unlimited,
                .stack_size = 1024 * 1024,
            });

            break :evented evented_instance.io();
        },
        .threaded => threaded: {
            threaded_instance = .init(gpa, .{
                .argv0 = .init(init.args),
                .environ = init.environ,
            });

            break :threaded threaded_instance.io();
        },
    };

    defer switch (io_mode) {
        .evented => evented_instance.deinit(),
        .threaded => threaded_instance.deinit(),
    };

    const args_slice = try init.args.toSlice(arena.allocator());
    const args = remielle.args.parse(Args, log, args_slice) orelse usage(io);

    const address = net.IpAddress.parseLiteral(args.@"--listen-address") catch |err|
        fatal("bad --listen-address: {t}", .{err});

    var asset_lookup = assets.Lookup.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
    };
    defer asset_lookup.deinit(gpa);

    var net_server = address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 64,
    }) catch |err| switch (err) {
        error.AddressInUse => fatal(
            \\address {qf} is already in use
            \\likely cause: another instance of this server is already running
        , .{address}),
        else => |e| fatal("failed to start: {t}", .{e}),
    };
    defer net_server.deinit(io);

    var connection_index_by_uid: std.array_hash_map.Auto(u32, u32) = .empty;
    defer connection_index_by_uid.deinit(gpa);
    connection_index_by_uid.ensureTotalCapacity(gpa, args.@"--concurrency") catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});

    const player_uids = gpa.alloc(u32, args.@"--concurrency") catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});
    defer gpa.free(player_uids);
    @memset(player_uids, 0);

    // TODO: compress allocation of `connections`, `recv_buffers`, `send_buffers`
    // into a single `alignedAlloc` call.
    const connections = gpa.alloc(Connection, args.@"--concurrency") catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});
    defer gpa.free(connections);

    const recv_buffers = gpa.alloc(u8, args.@"--concurrency" * recv_buffer_size) catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});
    defer gpa.free(recv_buffers);

    const send_buffers = gpa.alloc(u8, args.@"--concurrency" * send_buffer_size) catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});
    defer gpa.free(send_buffers);

    var persistent = Persistent.init(io, gpa, .cwd()) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| fatal("failed to initialize Persistent: {t}", .{e}),
    };
    defer persistent.deinit(gpa);

    var game: Game = .{
        .asset_lookup = &asset_lookup,
        .connections = connections,
        .connection_index_by_uid = &connection_index_by_uid,
        .connection_index_by_uid_mutex = .init,
        .persistent = &persistent,
        .persistent_mutex = .init,
    };

    var client_task_group: Io.Group = .init;
    defer client_task_group.cancel(io);

    for (game.connections, 0..) |*connection, index| {
        const recv_buffer = recv_buffers[recv_buffer_size * index ..][0..recv_buffer_size];
        const send_buffer = send_buffers[send_buffer_size * index ..][0..send_buffer_size];

        var task: Task = .{
            .index = @intCast(index),

            .csprng_seed = undefined, // populated by `randomSecure` below.
            .net_server = &net_server,
            .asset_lookup = &asset_lookup,

            .persistent = &persistent,
            .persistent_mutex = &game.persistent_mutex,

            .connection_index_by_uid = &connection_index_by_uid,
            .connection_index_by_uid_mutex = &game.connection_index_by_uid_mutex,

            .recv_buffer = recv_buffer,
            .send_buffer = send_buffer,
            .connection = connection,
        };

        connection.* = .{
            .mutex = .init,
            .sending = .is_set, // `is_set` indicates no pending net_write.
            .stream_maybe = null,
            .session = undefined,
        };

        io.randomSecure(&task.csprng_seed) catch |err| switch (err) {
            error.Canceled => unreachable,
            error.EntropyUnavailable => if (args.@"--require-secure-random")
                fatal("secure entropy source is uavailable", .{})
            else
                io.random(&task.csprng_seed),
        };

        client_task_group.concurrent(
            io,
            runClientTask,
            .{ io, gpa, task },
        ) catch
            fatal(
                \\failed to allocate concurrency for {d} sessions
                \\likely cause: --concurrency is higher than the system can process
            , .{args.@"--concurrency"});
    }

    // TODO: start control protocol task

    try remielle.splash.print(io);

    log.info("waiting for clients at tcp://{f}", .{net_server.socket.address});
    defer log.info("shutting down...", .{});

    switch (io_mode) {
        .evented => evented_instance.waitForShutdown(),
        .threaded => remielle.io.waitForShutdownThreaded(&threaded_instance),
    }
}

const Game = struct {
    asset_lookup: *const assets.Lookup,
    connections: []Connection,
    /// Not threadsafe. Lock `connection_index_by_uid_mutex` before operating on it.
    connection_index_by_uid: *std.array_hash_map.Auto(u32, u32),
    connection_index_by_uid_mutex: Io.Mutex,
    /// Not threadsafe. Lock `persistent_mutex` before operating on it.
    persistent: *Persistent,
    persistent_mutex: Io.Mutex,
};

const Task = struct {
    index: u32,

    csprng_seed: [DefaultCsprng.secret_seed_length]u8,
    asset_lookup: *const assets.Lookup,
    net_server: *net.Server,

    /// Not threadsafe. Lock `persistent_mutex` before operating on it.
    persistent: *Persistent,
    persistent_mutex: *Io.Mutex,

    /// Not threadsafe. Lock `connection_index_by_uid_mutex` before operating on it.
    connection_index_by_uid: *std.array_hash_map.Auto(u32, u32),
    connection_index_by_uid_mutex: *Io.Mutex,

    connection: *Connection,
    recv_buffer: []u8,
    send_buffer: []u8,
};

fn runClientTask(io: Io, gpa: Allocator, task: Task) Io.Cancelable!void {
    var csprng: DefaultCsprng = .init(task.csprng_seed);

    while (true) {
        const stream = task.net_server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
        defer stream.close(io);

        log.info("new connection from {f}", .{stream.socket.address});
        defer log.info("connection from {f} closed", .{stream.socket.address});

        try task.connection.setStream(io, stream);
        defer task.connection.removeStream(io);

        serveStream(io, gpa, csprng.random(), &task, stream) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => |e| {
                log.err("failed to serve client from {f}: {t}", .{ stream.socket.address, e });
                continue;
            },
        };
    }
}

fn serveStream(
    io: Io,
    gpa: Allocator,
    csprng: Random,
    task: *const Task,
    stream: net.Stream,
) !void {
    var stream_reader = stream.reader(io, task.recv_buffer);
    var sink: Io.Writer = .fixed(task.send_buffer);

    processFirstCommand(
        io,
        gpa,
        csprng,
        task,
        &stream_reader.interface,
        &sink,
    ) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.EndOfStream => return,
        error.ReadFailed => switch (stream_reader.err.?) {
            error.Canceled => |e| return e,
            else => return,
        },
        error.WriteFailed => {
            log.err("send_buffer exceeded while processing first command", .{});
            return;
        },

        else => |e| return e,
    };

    defer releasePlayerUId(io, task);

    try task.connection.writeAll(io, sink.buffered());
    sink.end = 0;

    while (protocol.Command.decode(&stream_reader.interface)) |command| {
        if (protobuf.features.isAvailable(.log_out)) {
            if (command.id == protobuf.main_desc.PlayerLogoutCsReq.cmd_id)
                return;
        }

        try processCommandLoggedIn(io, gpa, task, &command, &sink);

        const to_write = sink.buffered();
        if (to_write.len != 0) {
            try task.connection.writeAll(io, sink.buffered());
            sink.end = 0;
        }
    } else |err| switch (err) {
        error.EndOfStream,
        error.MagicNumberMismatch,
        => return,

        error.ReadFailed => switch (stream_reader.err.?) {
            error.Canceled => |e| return e,
            else => {},
        },
    }
}

fn processFirstCommand(
    io: Io,
    gpa: Allocator,
    csprng: Random,
    task: *const Task,
    reader: *Io.Reader,
    sink: *Io.Writer,
) !void {
    // TODO: eliminate heap allocations (blocked by Persistent rewrite)

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const command: protocol.Command = try .decode(reader);

    if (command.id != protobuf.main_desc.PlayerGetTokenCsReq.cmd_id)
        return error.UnexpectedFirstCmdId;

    protocol.xor(command.body, initial_xorpad);

    var string_buffer: [1024]u8 = undefined;

    var br: Io.Reader = .fixed(command.body);
    var fba: std.heap.FixedBufferAllocator = .init(&string_buffer);

    const request = protobuf.decode(
        .main,
        protobuf.main.PlayerGetTokenCsReq,
        fba.allocator(),
        &br,
    ) catch
        return error.MalformedPayload;

    const client_rand_key = remielle.rsa.decryptString(@constCast(request.client_rand_key)) catch
        return error.DecryptFail;

    if (client_rand_key.len != 8)
        return error.DecryptFail;

    try task.persistent_mutex.lock(io);
    defer task.persistent_mutex.unlock(io);

    const get_or_create = try task.persistent.getOrCreatePlayerUid(io, request.account_uid, gpa);

    if (!try takePlayerUid(io, task, get_or_create.player_uid))
        return error.PlayerBusy;

    errdefer releasePlayerUId(io, task);

    task.connection.session = .{
        .uid = get_or_create.player_uid,
        .packet_id_counter = 0,
        .properties = .init,
        .xorpad = undefined,
    };

    if (get_or_create.created) {
        task.connection.session.properties.setDefaults();
    } else blk: {
        // TODO: less retarded way of loading this.

        if (task.persistent.loadPlayer(io, arena, get_or_create.player_uid)) |player_save| {
            if (task.connection.session.properties.fromPlayerSave(&player_save))
                break :blk
            else |_| {}
        } else |err| switch (err) {
            error.Canceled => |e| return e,
            else => {},
        }

        task.connection.session.properties.setDefaults();
    }

    const server_rand_key = csprng.int(u64);
    var encrypt_buffer: remielle.rsa.EncryptAndSignBuffer = undefined;
    remielle.rsa.encryptAndSign(&encrypt_buffer, @ptrCast(&server_rand_key));

    const response: protobuf.main.PlayerGetTokenScRsp = .{
        .uid = get_or_create.player_uid,
        .server_rand_key = &encrypt_buffer.ciphertext,
        .sign = &encrypt_buffer.sign,
    };

    try protocol.Command.encode(
        sink,
        protobuf.main_desc.PlayerGetTokenScRsp.cmd_id,
        .{},
        response,
        initial_xorpad,
    );

    protocol.getDecryptVector(
        &task.connection.session.xorpad,
        mem.readInt(u64, client_rand_key[0..8], .little) ^ server_rand_key,
    );
}

/// Try to "take the ownership" of player uid by adding index of task to the map.
fn takePlayerUid(io: Io, task: *const Task, uid: u32) Io.Cancelable!bool {
    try task.connection_index_by_uid_mutex.lock(io);
    defer task.connection_index_by_uid_mutex.unlock(io);

    const gop = task.connection_index_by_uid.getOrPutAssumeCapacity(uid);
    if (gop.found_existing) return false;

    gop.value_ptr.* = uid;
    task.connection.session.uid = uid;

    return true;
}

fn releasePlayerUId(io: Io, task: *const Task) void {
    task.connection_index_by_uid_mutex.lockUncancelable(io);
    defer task.connection_index_by_uid_mutex.unlock(io);

    assert(task.connection_index_by_uid.swapRemove(task.connection.session.uid));
    task.connection.session.uid = 0;
}

fn processCommandLoggedIn(
    io: Io,
    gpa: Allocator,
    task: *const Task,
    command: *const protocol.Command,
    sink: *Io.Writer,
) !void {
    protocol.xor(command.body, &task.connection.session.xorpad);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    try task.connection.mutex.lock(io); // Lock for accessing `properties`.
    defer task.connection.mutex.unlock(io);

    const time: Io.Timestamp = .now(io, .real);

    messaging.handlers.process(
        arena.allocator(),
        time,
        &.{
            .packet_id_counter = &task.connection.session.packet_id_counter,
            .xorpad = &task.connection.session.xorpad,
            .writer = sink,
        },
        &task.connection.session.properties,
        task.asset_lookup,
        &task.persistent.calendar,
        command,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.SendBufferExceeded,
        else => |e| return e,
    };

    const uid = task.connection.session.uid;
    const player_save = try task.connection.session.properties.toPlayerSave(arena.allocator());

    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    task.persistent.savePlayer(io, uid, player_save) catch |err| switch (err) {
        error.Canceled => unreachable, // blocked
        else => |e| log.err("failed to save player with UID {d}: {t}", .{ uid, e }),
    };
}

const Connection = struct {
    /// Guards `sending.reset`, `session`.
    mutex: Io.Mutex,
    /// `unset` when a `net_write` operation is pending on the stream.
    sending: Io.Event,
    /// Not threadsafe.
    /// Use `writeAll` to access this.
    stream_maybe: ?Io.net.Stream,
    /// Not threadsafe. Lock `mutex` before operating on it.
    session: Session,

    const Session = struct {
        uid: u32,
        packet_id_counter: u32,
        xorpad: [4096]u8,
        properties: logic.Properties,
    };

    // TODO: might as well introduce timeout to avoid indefinitely blocking
    // in case client died upon `net_write`.
    fn acquireWrite(connection: *Connection, io: Io) Io.Cancelable!?net.Stream {
        // Make sure no one else will be `wait`ing concurrently.
        try connection.mutex.lock(io);
        defer connection.mutex.unlock(io);

        try connection.sending.wait(io);
        const stream = connection.stream_maybe orelse return null;

        // Note that `reset` may happen only under a mutex to prevent others racing on `wait`.
        connection.sending.reset();
        return stream;
    }

    fn releaseWrite(connection: *Connection, io: Io) void {
        assert(!connection.sending.isSet()); // always a race condition
        connection.sending.set(io);
    }

    fn setStream(connection: *Connection, io: Io, stream: net.Stream) Io.Cancelable!void {
        assert(connection.stream_maybe == null);
        assert(connection.sending.isSet());

        try connection.mutex.lock(io);
        defer connection.mutex.unlock(io);

        connection.stream_maybe = stream;
    }

    fn removeStream(connection: *Connection, io: Io) void {
        assert(connection.stream_maybe != null);
        defer {
            assert(connection.sending.isSet());
            assert(connection.stream_maybe == null);
        }

        connection.mutex.lockUncancelable(io);
        defer connection.mutex.unlock(io);

        connection.sending.waitUncancelable(io);
        connection.stream_maybe = null;
    }

    fn writeAll(connection: *Connection, io: Io, buffer: []const u8) Io.Cancelable!void {
        const stream = try connection.acquireWrite(io) orelse return;
        defer connection.releaseWrite(io);

        var remaining = buffer;

        while (remaining.len != 0) {
            var vector: [1][]const u8 = .{remaining};

            const result = try io.operate(.{ .net_write = .{
                .socket_handle = stream.socket.handle,
                .data = &vector,
            } });

            const written = result.net_write catch return;
            remaining = remaining[written..];
        }
    }
};
