const Dylib = @This();

const std = @import("std");
const builtin = std.builtin;
const assert = std.debug.assert;
const fs = std.fs;
const fmt = std.fmt;
const log = std.log.scoped(.dylib);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const native_endian = builtin.target.cpu.arch.endian();

const Allocator = mem.Allocator;
const Arch = std.Target.Cpu.Arch;
const Symbol = @import("Symbol.zig");
const LibStub = @import("../tapi.zig").LibStub;

usingnamespace @import("commands.zig");

allocator: *Allocator,

arch: ?Arch = null,
header: ?macho.mach_header_64 = null,
file: ?fs.File = null,
name: ?[]const u8 = null,
syslibroot: ?[]const u8 = null,

ordinal: ?u16 = null,

// The actual dylib contents we care about linking with will be embedded at
// an offset within a file if we are linking against a fat lib
library_offset: u64 = 0,

load_commands: std.ArrayListUnmanaged(LoadCommand) = .{},

symtab_cmd_index: ?u16 = null,
dysymtab_cmd_index: ?u16 = null,
id_cmd_index: ?u16 = null,

id: ?Id = null,

/// Parsed symbol table represented as hash map of symbols'
/// names. We can and should defer creating *Symbols until
/// a symbol is referenced by an object file.
symbols: std.StringArrayHashMapUnmanaged(void) = .{},

// TODO add parsing re-exported libs from binary dylibs
dependent_libs: std.StringArrayHashMapUnmanaged(void) = .{},

pub const Id = struct {
    name: []const u8,
    timestamp: u32,
    current_version: u32,
    compatibility_version: u32,

    pub fn default(name: []const u8) Id {
        return .{
            .name = name,
            .timestamp = 2,
            .current_version = 0x10000,
            .compatibility_version = 0x10000,
        };
    }

    pub fn deinit(id: *Id, allocator: *Allocator) void {
        allocator.free(id.name);
    }

    const ParseError = fmt.ParseIntError || fmt.BufPrintError;

    pub fn parseCurrentVersion(id: *Id, version: anytype) ParseError!void {
        id.current_version = try parseVersion(version);
    }

    pub fn parseCompatibilityVersion(id: *Id, version: anytype) ParseError!void {
        id.compatibility_version = try parseVersion(version);
    }

    fn parseVersion(version: anytype) ParseError!u32 {
        const string = blk: {
            switch (version) {
                .int => |int| {
                    var out: u32 = 0;
                    const major = try math.cast(u16, int);
                    out += @intCast(u32, major) << 16;
                    return out;
                },
                .float => |float| {
                    var buf: [256]u8 = undefined;
                    break :blk try fmt.bufPrint(&buf, "{d:.2}", .{float});
                },
                .string => |string| {
                    break :blk string;
                },
            }
        };

        var out: u32 = 0;
        var values: [3][]const u8 = undefined;

        var split = mem.split(string, ".");
        var count: u4 = 0;
        while (split.next()) |value| {
            if (count > 2) {
                log.warn("malformed version field: {s}", .{string});
                return 0x10000;
            }
            values[count] = value;
            count += 1;
        }

        if (count > 2) {
            out += try fmt.parseInt(u8, values[2], 10);
        }
        if (count > 1) {
            out += @intCast(u32, try fmt.parseInt(u8, values[1], 10)) << 8;
        }
        out += @intCast(u32, try fmt.parseInt(u16, values[0], 10)) << 16;

        return out;
    }
};

pub const Error = error{
    OutOfMemory,
    EmptyStubFile,
    MismatchedCpuArchitecture,
    UnsupportedCpuArchitecture,
} || fs.File.OpenError || std.os.PReadError || Id.ParseError;

pub fn createAndParseFromPath(
    allocator: *Allocator,
    arch: Arch,
    path: []const u8,
    syslibroot: ?[]const u8,
) Error!?[]*Dylib {
    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    errdefer file.close();

    const dylib = try allocator.create(Dylib);
    errdefer allocator.destroy(dylib);

    const name = try allocator.dupe(u8, path);
    errdefer allocator.free(name);

    dylib.* = .{
        .allocator = allocator,
        .arch = arch,
        .name = name,
        .file = file,
        .syslibroot = syslibroot,
    };

    dylib.parse() catch |err| switch (err) {
        error.EndOfStream, error.NotDylib => {
            try file.seekTo(0);

            var lib_stub = LibStub.loadFromFile(allocator, file) catch {
                dylib.deinit();
                allocator.destroy(dylib);
                return null;
            };
            defer lib_stub.deinit();

            try dylib.parseFromStub(lib_stub);
        },
        else => |e| return e,
    };

    var dylibs = std.ArrayList(*Dylib).init(allocator);
    defer dylibs.deinit();

    try dylibs.append(dylib);
    try dylib.parseDependentLibs(&dylibs);

    return dylibs.toOwnedSlice();
}

pub fn deinit(self: *Dylib) void {
    for (self.load_commands.items) |*lc| {
        lc.deinit(self.allocator);
    }
    self.load_commands.deinit(self.allocator);

    for (self.symbols.keys()) |key| {
        self.allocator.free(key);
    }
    self.symbols.deinit(self.allocator);

    for (self.dependent_libs.keys()) |key| {
        self.allocator.free(key);
    }
    self.dependent_libs.deinit(self.allocator);

    if (self.name) |name| {
        self.allocator.free(name);
    }

    if (self.id) |*id| {
        id.deinit(self.allocator);
    }
}

pub fn closeFile(self: Dylib) void {
    if (self.file) |file| {
        file.close();
    }
}

fn decodeArch(cputype: macho.cpu_type_t) !std.Target.Cpu.Arch {
    const arch: Arch = switch (cputype) {
        macho.CPU_TYPE_ARM64 => .aarch64,
        macho.CPU_TYPE_X86_64 => .x86_64,
        else => {
            return error.UnsupportedCpuArchitecture;
        },
    };
    return arch;
}

pub fn parse(self: *Dylib) !void {
    log.debug("parsing shared library '{s}'", .{self.name.?});

    self.library_offset = offset: {
        const fat_header = try readFatStruct(self.file.?.reader(), macho.fat_header);
        if (fat_header.magic != macho.FAT_MAGIC) break :offset 0;

        var fat_arch_index: u32 = 0;
        while (fat_arch_index < fat_header.nfat_arch) : (fat_arch_index += 1) {
            const fat_arch = try readFatStruct(self.file.?.reader(), macho.fat_arch);
            // If we come across an architecture that we do not know how to handle, that's
            // fine because we can keep looking for one that might match.
            const lib_arch = decodeArch(fat_arch.cputype) catch |err| switch (err) {
                error.UnsupportedCpuArchitecture => continue,
                else => |e| return e,
            };
            if (lib_arch == self.arch.?) {
                // We have found a matching architecture!
                break :offset fat_arch.offset;
            }
        } else {
            log.err("Could not find matching cpu architecture in fat library: expected {s}", .{self.arch.?});
            return error.MismatchedCpuArchitecture;
        }
    };

    try self.file.?.seekTo(self.library_offset);

    var reader = self.file.?.reader();
    self.header = try reader.readStruct(macho.mach_header_64);

    if (self.header.?.filetype != macho.MH_DYLIB) {
        log.debug("invalid filetype: expected 0x{x}, found 0x{x}", .{ macho.MH_DYLIB, self.header.?.filetype });
        return error.NotDylib;
    }

    const this_arch: Arch = decodeArch(self.header.?.cputype) catch |err| switch (err) {
        error.UnsupportedCpuArchitecture => |e| {
            log.err("unsupported cpu architecture 0x{x}", .{self.header.?.cputype});
            return e;
        },
        else => |e| return e,
    };

    if (this_arch != self.arch.?) {
        log.err("mismatched cpu architecture: expected {s}, found {s}", .{ self.arch.?, this_arch });
        return error.MismatchedCpuArchitecture;
    }

    try self.readLoadCommands(reader);
    try self.parseId();
    try self.parseSymbols();
}

fn readFatStruct(reader: anytype, comptime T: type) !T {
    // Fat structures (fat_header & fat_arch) are always written and read to/from
    // disk in big endian order.
    var res: T = try reader.readStruct(T);
    if (native_endian != builtin.Endian.Big) {
        mem.bswapAllFields(T, &res);
    }
    return res;
}

fn readLoadCommands(self: *Dylib, reader: anytype) !void {
    try self.load_commands.ensureCapacity(self.allocator, self.header.?.ncmds);

    var i: u16 = 0;
    while (i < self.header.?.ncmds) : (i += 1) {
        var cmd = try LoadCommand.read(self.allocator, reader);
        switch (cmd.cmd()) {
            macho.LC_SYMTAB => {
                self.symtab_cmd_index = i;
            },
            macho.LC_DYSYMTAB => {
                self.dysymtab_cmd_index = i;
            },
            macho.LC_ID_DYLIB => {
                self.id_cmd_index = i;
            },
            else => {
                log.debug("Unknown load command detected: 0x{x}.", .{cmd.cmd()});
            },
        }
        self.load_commands.appendAssumeCapacity(cmd);
    }
}

fn parseId(self: *Dylib) !void {
    const index = self.id_cmd_index orelse {
        log.debug("no LC_ID_DYLIB load command found; using hard-coded defaults...", .{});
        self.id = Id.default(try self.allocator.dupe(u8, self.name.?));
        return;
    };
    const id_cmd = self.load_commands.items[index].Dylib;
    const dylib = id_cmd.inner.dylib;

    // TODO should we compare the name from the dylib's id with the user-specified one?
    const dylib_name = @ptrCast([*:0]const u8, id_cmd.data[dylib.name - @sizeOf(macho.dylib_command) ..]);
    const name = try self.allocator.dupe(u8, mem.spanZ(dylib_name));

    self.id = .{
        .name = name,
        .timestamp = dylib.timestamp,
        .current_version = dylib.current_version,
        .compatibility_version = dylib.compatibility_version,
    };
}

fn parseSymbols(self: *Dylib) !void {
    const index = self.symtab_cmd_index orelse return;
    const symtab_cmd = self.load_commands.items[index].Symtab;

    var symtab = try self.allocator.alloc(u8, @sizeOf(macho.nlist_64) * symtab_cmd.nsyms);
    defer self.allocator.free(symtab);
    _ = try self.file.?.preadAll(symtab, symtab_cmd.symoff + self.library_offset);
    const slice = @alignCast(@alignOf(macho.nlist_64), mem.bytesAsSlice(macho.nlist_64, symtab));

    var strtab = try self.allocator.alloc(u8, symtab_cmd.strsize);
    defer self.allocator.free(strtab);
    _ = try self.file.?.preadAll(strtab, symtab_cmd.stroff + self.library_offset);

    for (slice) |sym| {
        const sym_name = mem.spanZ(@ptrCast([*:0]const u8, strtab.ptr + sym.n_strx));

        if (!(Symbol.isSect(sym) and Symbol.isExt(sym))) continue;

        const name = try self.allocator.dupe(u8, sym_name);
        try self.symbols.putNoClobber(self.allocator, name, {});
    }
}

fn hasTarget(targets: []const []const u8, target: []const u8) bool {
    for (targets) |t| {
        if (mem.eql(u8, t, target)) return true;
    }
    return false;
}

fn addObjCClassSymbols(self: *Dylib, sym_name: []const u8) !void {
    const expanded = &[_][]const u8{
        try std.fmt.allocPrint(self.allocator, "_OBJC_CLASS_$_{s}", .{sym_name}),
        try std.fmt.allocPrint(self.allocator, "_OBJC_METACLASS_$_{s}", .{sym_name}),
    };

    for (expanded) |sym| {
        if (self.symbols.contains(sym)) continue;
        try self.symbols.putNoClobber(self.allocator, sym, .{});
    }
}

pub fn parseFromStub(self: *Dylib, lib_stub: LibStub) !void {
    if (lib_stub.inner.len == 0) return error.EmptyStubFile;

    log.debug("parsing shared library from stub '{s}'", .{self.name.?});

    const umbrella_lib = lib_stub.inner[0];

    var id = Id.default(try self.allocator.dupe(u8, umbrella_lib.install_name));
    if (umbrella_lib.current_version) |version| {
        try id.parseCurrentVersion(version);
    }
    if (umbrella_lib.compatibility_version) |version| {
        try id.parseCompatibilityVersion(version);
    }
    self.id = id;

    const target_string: []const u8 = switch (self.arch.?) {
        .aarch64 => "arm64-macos",
        .x86_64 => "x86_64-macos",
        else => unreachable,
    };

    var umbrella_libs = std.StringHashMap(void).init(self.allocator);
    defer umbrella_libs.deinit();

    for (lib_stub.inner) |stub, stub_index| {
        if (!hasTarget(stub.targets, target_string)) continue;

        if (stub_index > 0) {
            // TODO I thought that we could switch on presence of `parent-umbrella` map;
            // however, turns out `libsystem_notify.dylib` is fully reexported by `libSystem.dylib`
            // BUT does not feature a `parent-umbrella` map as the only sublib. Apple's bug perhaps?
            try umbrella_libs.put(stub.install_name, .{});
        }

        if (stub.exports) |exports| {
            for (exports) |exp| {
                if (!hasTarget(exp.targets, target_string)) continue;

                if (exp.symbols) |symbols| {
                    for (symbols) |sym_name| {
                        if (self.symbols.contains(sym_name)) continue;
                        try self.symbols.putNoClobber(self.allocator, try self.allocator.dupe(u8, sym_name), {});
                    }
                }

                if (exp.objc_classes) |classes| {
                    for (classes) |sym_name| {
                        try self.addObjCClassSymbols(sym_name);
                    }
                }
            }
        }

        if (stub.reexports) |reexports| {
            for (reexports) |reexp| {
                if (!hasTarget(reexp.targets, target_string)) continue;

                if (reexp.symbols) |symbols| {
                    for (symbols) |sym_name| {
                        if (self.symbols.contains(sym_name)) continue;
                        try self.symbols.putNoClobber(self.allocator, try self.allocator.dupe(u8, sym_name), {});
                    }
                }

                if (reexp.objc_classes) |classes| {
                    for (classes) |sym_name| {
                        try self.addObjCClassSymbols(sym_name);
                    }
                }
            }
        }

        if (stub.objc_classes) |classes| {
            for (classes) |sym_name| {
                try self.addObjCClassSymbols(sym_name);
            }
        }
    }

    log.debug("{s}", .{umbrella_lib.install_name});

    // TODO track which libs were already parsed in different steps
    for (lib_stub.inner) |stub| {
        if (!hasTarget(stub.targets, target_string)) continue;

        if (stub.reexported_libraries) |reexports| {
            for (reexports) |reexp| {
                if (!hasTarget(reexp.targets, target_string)) continue;

                for (reexp.libraries) |lib| {
                    if (umbrella_libs.contains(lib)) {
                        log.debug("  | {s} <= {s}", .{ lib, umbrella_lib.install_name });
                        continue;
                    }

                    log.debug("  | {s}", .{lib});
                    try self.dependent_libs.put(self.allocator, try self.allocator.dupe(u8, lib), {});
                }
            }
        }
    }
}

pub fn parseDependentLibs(self: *Dylib, out: *std.ArrayList(*Dylib)) !void {
    outer: for (self.dependent_libs.keys()) |lib| {
        const dirname = fs.path.dirname(lib) orelse {
            log.warn("unable to resolve dependency {s}", .{lib});
            continue;
        };
        const filename = fs.path.basename(lib);
        const without_ext = if (mem.lastIndexOfScalar(u8, filename, '.')) |index|
            filename[0..index]
        else
            filename;

        for (&[_][]const u8{ "dylib", "tbd" }) |ext| {
            const with_ext = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{
                without_ext,
                ext,
            });
            defer self.allocator.free(with_ext);

            const lib_path = if (self.syslibroot) |syslibroot|
                try fs.path.join(self.allocator, &.{ syslibroot, dirname, with_ext })
            else
                try fs.path.join(self.allocator, &.{ dirname, with_ext });

            log.debug("trying dependency at fully resolved path {s}", .{lib_path});

            const dylibs = (try createAndParseFromPath(
                self.allocator,
                self.arch.?,
                lib_path,
                self.syslibroot,
            )) orelse {
                continue;
            };

            try out.appendSlice(dylibs);

            continue :outer;
        } else {
            log.warn("unable to resolve dependency {s}", .{lib});
        }
    }
}

pub fn createProxy(self: *Dylib, sym_name: []const u8) !?*Symbol {
    if (!self.symbols.contains(sym_name)) return null;

    const name = try self.allocator.dupe(u8, sym_name);
    const proxy = try self.allocator.create(Symbol.Proxy);
    errdefer self.allocator.destroy(proxy);

    proxy.* = .{
        .base = .{
            .@"type" = .proxy,
            .name = name,
        },
        .file = self,
    };

    return &proxy.base;
}
