//! Placeholder: replaced by the port of the C library's `pow`.

const std = @import("std");

pub fn pow(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}
