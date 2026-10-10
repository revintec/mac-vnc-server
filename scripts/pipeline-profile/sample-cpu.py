#!/usr/bin/env python3
"""Measure process CPU over an interval on macOS; 100% means one CPU core.

Usage: sample-cpu.py SCENARIO SECONDS PID [PID ...]
The Mach counters returned by proc_pid_rusage require timebase conversion.
CLOCK_UPTIME_RAW shares the epoch used by the Swift and Objective-C probes.
"""
import ctypes
import json
import sys
import time

kernel = ctypes.CDLL(None)
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
clock = kernel.clock_gettime_nsec_np
clock.argtypes = [ctypes.c_int]
clock.restype = ctypes.c_uint64
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int

class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

timebase = Timebase()
if kernel.mach_timebase_info(ctypes.byref(timebase)):
    raise RuntimeError('mach_timebase_info failed')

def now():
    return clock(8)  # CLOCK_UPTIME_RAW

def usage(pid):
    buffer = ctypes.create_string_buffer(256)
    if libproc.proc_pid_rusage(pid, 2, buffer):
        raise ProcessLookupError(f'Cannot sample PID {pid}: errno={ctypes.get_errno()}')
    fields = (ctypes.c_uint64 * 30).from_buffer(buffer, 16)  # skip UUID
    return {
        'user_ns': fields[0] * timebase.numer / timebase.denom,
        'system_ns': fields[1] * timebase.numer / timebase.denom,
        'rss_bytes': fields[6],
    }

if len(sys.argv) < 4:
    raise SystemExit(__doc__)
scenario, seconds = sys.argv[1], float(sys.argv[2])
pids = list(map(int, sys.argv[3:]))
if not 0 < seconds <= 60:
    raise SystemExit('Sample duration must be > 0 and <= 60 seconds')
before = {pid: usage(pid) for pid in pids}
start = now()
time.sleep(seconds)
end = now()
after = {pid: usage(pid) for pid in pids}
result = {
    'scenario': scenario,
    'start_uptime_ns': start,
    'end_uptime_ns': end,
    'duration_s': (end - start) / 1e9,
    'mach_timebase': [timebase.numer, timebase.denom],
    'processes': {
        pid: {
            'cpu_percent': 100 * sum(after[pid][k] - before[pid][k]
                                     for k in ['user_ns', 'system_ns']) / (end - start),
            'before': before[pid],
            'after': after[pid],
        } for pid in pids
    },
}
print(json.dumps(result, indent=2))
