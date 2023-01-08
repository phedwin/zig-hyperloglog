const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const sparse = @import("sparse.zig");
const AllocationError = error{OutOfMemory};

const precision = 14;
const m = 1 << precision;
const max = 64 - precision;
const maxx = math.maxInt(u64) >> max;
const alpha = 0.7213 / (1.0 + 1.079 / @intToFloat(f64, m));
const sparse_threshold = m * 6 / 8;

var rnd = RndGen.init(0);

fn beta(z: f64) f64 {
    const zl = math.ln(z + 1);
    return -0.370393911 * z +
        0.070471823 * zl +
        0.17393686 * math.pow(f64, zl, 2) +
        0.16339839 * math.pow(f64, zl, 3) +
        -0.09237745 * math.pow(f64, zl, 4) +
        0.03738027 * math.pow(f64, zl, 5) +
        -0.005384159 * math.pow(f64, zl, 6) +
        0.00042419 * math.pow(f64, zl, 7);
}

const HyperLogLog = struct {
    const Self = @This();

    allocator: Allocator,
    dense: []u6,
    is_sparse: bool = true,
    set: sparse.Set,

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .dense = try allocator.alloc(u6, 0),
            .set = sparse.Set.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_sparse) {
            self.set.deinit();
        }
        self.allocator.free(self.dense);
    }

    pub fn toDense(self: *Self) !void {
        self.dense = self.allocator.alloc(u6, m) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        for (self.dense) |*x| {
            x.* = 0;
        }
        var itr = self.set.set.iterator();

        while (itr.next()) |x| {
            try self.addToDense(x.key_ptr.*);
        }
        self.is_sparse = false;
        self.set.clear();
    }

    fn addToSparse(self: *Self, hash: u64) !void {
        try self.set.add(hash);
    }

    fn addToDense(self: *Self, x: u64) !void {
        var k = x >> max;
        var val = @intCast(u6, @clz((x << precision) ^ maxx)) + 1;
        if (val > self.dense[k]) {
            self.dense[k] = val;
        }
    }

    pub fn addHashed(self: *Self, hash: u64) !void {
        if (self.is_sparse == true and self.set.len() < sparse_threshold) {
            return self.addToSparse(hash);
        } else if (self.is_sparse == true) {
            try self.toDense();
        }
        try self.addToDense(hash);
    }

    pub fn cardinality(self: *Self) u64 {
        if (self.is_sparse) {
            return @intCast(u64, self.set.len());
        }

        var sum: f64 = 0;
        var z: f64 = 0;

        for (self.dense) |x| {
            if (x == 0) {
                z += 1;
            }
            sum += 1.0 / math.pow(f64, 2.0, @intToFloat(f64, x));
        }
        const m_float = @intToFloat(f64, m);

        var est = alpha * m_float * (m_float - z) / (beta(z) + sum);
        return @floatToInt(u64, est + 0.5);
    }

    pub fn merge(self: *Self, other: *Self) !void {
        // if other is sparse then just add all the elements
        if (other.is_sparse) {
            var itr = other.set.set.iterator();
            while (itr.next()) |x| {
                var val: u64 = x.key_ptr.*;
                try self.addHashed(val);
            }
            return;
        }

        if (self.is_sparse and !other.is_sparse) {
            // if self is sparse and other is dense then switch to dense
            try self.toDense();
        }

        for (self.dense) |*x, i| {
            if (other.dense[i] > x.*) {
                x.* = other.dense[i];
            }
        }
    }
};

// ======== TESTS ========

const testing = std.testing;
const RndGen = std.rand.DefaultPrng;
const autoHash = std.hash.autoHash;
const Wyhash = std.hash.Wyhash;
const tolerated_err = 0.008;

fn testHash(key: anytype) u64 {
    // Any hash could be used here, for testing autoHash.
    var hasher = Wyhash.init(0);
    autoHash(&hasher, key);
    return hasher.final();
}

fn estimateError(got: u64, expected: u64) f64 {
    var delta = @intToFloat(f64, got) - @intToFloat(f64, expected);
    if (delta < 0) {
        delta = -delta;
    }
    return delta / @intToFloat(f64, expected);
}

test "init" {
    var hll = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll.deinit();

    try testing.expect(hll.is_sparse);
    try testing.expect(hll.set.len() == 0);
    try testing.expect(hll.dense.len == 0);
}

test "add sparse" {
    var hll = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll.deinit();

    var i: u64 = 0;
    while (i < sparse_threshold) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll.addHashed(hash);
    }

    try testing.expect(hll.is_sparse);
    try testing.expect(hll.set.len() == sparse_threshold);
    try testing.expect(hll.dense.len == 0);
}

test "add dense" {
    var hll = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll.deinit();

    var i: u64 = 0;
    while (i < sparse_threshold + 1) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll.addHashed(hash);
    }
    var est_err = estimateError(hll.cardinality(), sparse_threshold + 1);

    try testing.expect(!hll.is_sparse);
    try testing.expect(hll.set.len() == 0);
    try testing.expect(hll.dense.len == m);
    try testing.expect(est_err < tolerated_err);
}

test "merge sparse same" {
    var hll1 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll1.deinit();
    var hll2 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll2.deinit();

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll1.addHashed(hash);
        try hll2.addHashed(hash);
    }

    try hll1.merge(&hll2);

    try testing.expect(hll1.is_sparse);
    try testing.expect(hll1.dense.len == 0);
    try testing.expect(hll1.set.len() == 10);
    try testing.expect(hll1.cardinality() == 10);
}

test "merge sparse different" {
    var hll1 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll1.deinit();
    var hll2 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll2.deinit();

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll1.addHashed(hash);
        hash = rnd.random().int(u64);
        try hll2.addHashed(hash);
    }

    try hll1.merge(&hll2);

    try testing.expect(hll1.is_sparse);
    try testing.expect(hll1.dense.len == 0);
    try testing.expect(hll1.set.len() == 20);
    try testing.expect(hll1.cardinality() == 20);
}

test "merge sparse into dense" {
    var hll1 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll1.deinit();
    var hll2 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll2.deinit();

    var i: u64 = 0;
    while (i < sparse_threshold + 1) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll1.addHashed(hash);
    }
    i = 0;
    while (i < sparse_threshold) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll2.addHashed(hash);
    }

    try hll1.merge(&hll2);
    var est_err = estimateError(hll1.cardinality(), 2 * sparse_threshold + 1);

    try testing.expect(hll1.dense.len == m);
    try testing.expect(hll1.set.len() == 0);
    try testing.expect(est_err < tolerated_err);
}

test "merge dense into sparse" {
    var hll1 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll1.deinit();
    var hll2 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll2.deinit();

    var i: u64 = 0;
    while (i < sparse_threshold + 1) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll1.addHashed(hash);
    }
    i = 0;
    while (i < 10) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll2.addHashed(hash);
    }

    try hll2.merge(&hll1);
    var est_err = estimateError(hll2.cardinality(), 10 + sparse_threshold + 1);

    try testing.expect(!hll1.is_sparse);
    try testing.expect(hll1.dense.len == m);
    try testing.expect(hll1.set.len() == 0);
    try testing.expect(est_err < tolerated_err);
}

test "merge dense same" {
    var hll1 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll1.deinit();
    var hll2 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll2.deinit();

    var i: u64 = 0;
    while (i < sparse_threshold + 1) : (i += 1) {
        var hash = rnd.random().int(u64);
        try hll1.addHashed(hash);
        try hll2.addHashed(hash);
    }

    try hll1.merge(&hll2);
    var est_err = estimateError(hll1.cardinality(), sparse_threshold + 1);

    try testing.expect(!hll1.is_sparse);
    try testing.expect(hll1.dense.len == m);
    try testing.expect(hll1.set.len() == 0);
    try testing.expect(est_err < tolerated_err);
}

test "merge dense different" {
    var hll1 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll1.deinit();
    var hll2 = HyperLogLog.init(testing.allocator) catch unreachable;
    defer hll2.deinit();

    var i: u64 = 0;
    while (i < sparse_threshold + 1) : (i += 1) {
        var hash = testHash(i);
        try hll1.addHashed(hash);
        hash = testHash(sparse_threshold + 1 + i);
        try hll2.addHashed(hash);
    }

    try hll1.merge(&hll2);
    var est_err = estimateError(hll1.cardinality(), 2 * sparse_threshold + 2);

    try testing.expect(!hll1.is_sparse);
    try testing.expect(hll1.dense.len == m);
    try testing.expect(hll1.set.len() == 0);
    try testing.expect(est_err < tolerated_err);
}
