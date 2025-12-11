const std = @import("std");
const root = @import("root");
const ports = @import("../io/ports.zig");

const Date = root.lib.common.time.Date;
const Time = root.lib.common.time.Time;
const DateTime = root.lib.common.time.DateTime;

pub fn timestamp() u64 {
    return rtc_to_unix(read_rtc_stable());
}

pub fn get_date() Date {
    const raw_date = read_rtc_stable();

    return .{
        .day = raw_date.day,
        .month = raw_date.month,
        .year = raw_date.year,
    };
}

pub fn get_time() Time {
    const raw_time = read_rtc_stable();

    return .{
        .secconds = raw_time.sec,
        .minutes = raw_time.min,
        .hours = raw_time.hour,
    };
}

pub fn get_datetime() DateTime {
    const datetime = read_rtc_stable();

    return .{
        .day = datetime.day,
        .month = datetime.month,
        .year = datetime.year,
        .seconds = datetime.sec,
        .minutes = datetime.min,
        .hours = datetime.hour,
    };
}

// CMOS IO operations
inline fn is_updating() bool {
    ports.outb(0x70, 0x0A);
    return (ports.inb(0x71) & 0x80) != 0;
}

inline fn read_cmos(index: u8) u8 {
    ports.outb(0x70, index);
    return ports.inb(0x71);
}

// FIXME lots of unoptimized code

fn read_rtc_stable() RTCData {
    var first: RTCData = undefined;
    var second: RTCData = undefined;

    while (true) {
        while (is_updating()) {}

        first = RTCData.read_raw();
        while (is_updating()) {}
        second = RTCData.read_raw();

        if (first.eql(second)) break;
    }

    return first;
}

const RTCData = struct {
    sec: u8,
    min: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u16,

    pub fn read_raw() RTCData {
        var sec = read_cmos(0x00);
        var min = read_cmos(0x02);
        var hour = read_cmos(0x04);
        var day = read_cmos(0x07);
        var month = read_cmos(0x08);
        var year = read_cmos(0x09);

        const bcd = (read_cmos(0x0B) & 0x04) == 0;

        if (bcd) {
            sec = bcd_to_bin(sec);
            min = bcd_to_bin(min);
            hour = bcd_to_bin(hour);
            day = bcd_to_bin(day);
            month = bcd_to_bin(month);
            year = bcd_to_bin(year);
        }

        const full_year: u16 = if (year < 70) 2000 + @as(u16, @intCast(year)) else 1900 + @as(u16, @intCast(year));

        return .{
            .sec = sec,
            .min = min,
            .hour = hour,
            .day = day,
            .month = month,
            .year = full_year,
        };
    }

    inline fn eql(self: RTCData, other: RTCData) bool {
        return std.meta.eql(self, other);
    }
};

fn bcd_to_bin(x: u8) u8 {
    return (x >> 4) * 10 + (x & 0x0F);
}

// i fucking HATE unix
fn rtc_to_unix(r: RTCData) u64 {
    const days_per_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var days: u64 = 0;

    // complete years
    var y: u16 = 1970;
    while (y < r.year) {
        days += if (is_leap(y)) 366 else 365;
        y += 1;
    }

    // complete months
    var m: usize = 0;
    while (m + 1 < r.month) {
        days += if (m == 1 and is_leap(r.year)) 29 else days_per_month[m];
        m += 1;
    }

    // complete days
    days += r.day - 1;

    // converting to secconds
    return (((days * 24 + r.hour) * 60 + r.min) * 60) + r.sec;
}
fn is_leap(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}
