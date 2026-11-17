#!/usr/bin/env python3
"""pool-evidence: one `pool-evidence:` line for the job that just ran, from
the memory cgroup the step runs in. On a pool runner that is the job's
container, so the figures are the job's own:

  pool-evidence: runner=<name> pool=yes cgroup=v2 peak_mb=2600 limit_mb=4096 failcnt=12 oom_kill=0

peak_mb   highest memory use (v2 memory.peak, v1 memory.max_usage_in_bytes);
limit_mb  the limit (memory.max / memory.limit_in_bytes), `max` for none;
failcnt   times use hit the limit (v2 memory.events `max`, v1 memory.failcnt);
oom_kill  processes the kernel OOM-killed in the cgroup (memory.events
          `oom_kill`, v1 memory.oom_control `oom_kill`).

A value it cannot read is `n/a`, and so is every value when the membership
path in /proc/self/cgroup cannot be mapped under the mount (only `/` reads
the mount root). The line goes to the log, to a notice
(a warning when oom_kill is above 0) and to the job summary. It never fails
the job: every path exits 0. POOL_EVIDENCE_CGROUP_ROOT (/sys/fs/cgroup) and
POOL_EVIDENCE_PROC_CGROUP (/proc/self/cgroup) are for the tests.
"""
import os
import re
import sys

MB = 1024 * 1024
UNLIMITED_V1 = 1 << 60   # v1 reports "no limit" as a page-rounded 2^63-1


def read(path):
    try:
        with open(path, encoding="ascii") as f:
            return f.read(65536).strip()
    except (OSError, UnicodeDecodeError):
        return None


def number(text):
    return int(text) if text is not None and re.fullmatch(r"[0-9]{1,20}", text) else None


def keyed(text, key):
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == key:
            return number(parts[1])
    return None


def mb(value):
    return "n/a" if value is None else str(value // MB)


def own_paths(root, proc):
    """-> (version, directory) of this process's memory cgroup; directory None when its
    membership path cannot be mapped under the mount; (None, None) without a memory cgroup."""
    text = read(proc) or ""
    v1 = v2 = None
    for line in text.splitlines():
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        if parts[0] == "0" and parts[1] == "":
            v2 = parts[2]
        elif "memory" in parts[1].split(","):
            v1 = parts[2]
    def inside(base, rel):
        # The mount root is ours only when the membership is exactly "/" (a cgroup
        # namespace: the container). An empty path, anything with "..", "." or an
        # empty part, or a directory we cannot see is not mapped: its figures are
        # n/a, never the root's.
        if rel == "/":
            return base
        if not rel:
            return None
        parts = rel.split("/")
        if parts[0] != "" or any(p in ("", ".", "..") for p in parts[1:]):
            return None
        path = os.path.join(base, *parts[1:])
        return path if os.path.isdir(path) else None
    if v1 is not None and os.path.isdir(os.path.join(root, "memory")):
        return "v1", inside(os.path.join(root, "memory"), v1)
    if v2 is not None and os.path.exists(os.path.join(root, "cgroup.controllers")):
        return "v2", inside(root, v2)
    return None, None


def evidence(root, proc):
    version, path = own_paths(root, proc)
    figures = {"peak": None, "limit": None, "failcnt": None, "oom_kill": None}
    if path is None:
        pass
    elif version == "v2":
        figures["peak"] = number(read(os.path.join(path, "memory.peak")))
        limit = read(os.path.join(path, "memory.max"))
        figures["limit"] = "max" if limit == "max" else number(limit)
        events = read(os.path.join(path, "memory.events"))
        figures["failcnt"] = keyed(events, "max")
        figures["oom_kill"] = keyed(events, "oom_kill")
    elif version == "v1":
        figures["peak"] = number(read(os.path.join(path, "memory.max_usage_in_bytes")))
        limit = number(read(os.path.join(path, "memory.limit_in_bytes")))
        figures["limit"] = "max" if limit is not None and limit >= UNLIMITED_V1 else limit
        figures["failcnt"] = number(read(os.path.join(path, "memory.failcnt")))
        figures["oom_kill"] = keyed(read(os.path.join(path, "memory.oom_control")), "oom_kill")
    return version or "n/a", figures


def append(name, text):
    path = os.environ.get(name, "")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def main():
    runner = re.sub(r"[^A-Za-z0-9_.-]", "?", os.environ.get("RUNNER_NAME", ""))[:100] or "n/a"
    pool = "yes" if runner.startswith("pool-") else "no"
    try:
        version, f = evidence(os.environ.get("POOL_EVIDENCE_CGROUP_ROOT") or "/sys/fs/cgroup",
                              os.environ.get("POOL_EVIDENCE_PROC_CGROUP") or "/proc/self/cgroup")
    except Exception as exc:  # evidence must never fail the job
        version, f = f"error ({type(exc).__name__})", {"peak": None, "limit": None,
                                                       "failcnt": None, "oom_kill": None}
    limit = f["limit"] if f["limit"] == "max" else mb(f["limit"])
    counts = {k: "n/a" if f[k] is None else str(f[k]) for k in ("failcnt", "oom_kill")}
    line = (f"pool-evidence: runner={runner} pool={pool} cgroup={version} peak_mb={mb(f['peak'])} "
            f"limit_mb={limit} failcnt={counts['failcnt']} oom_kill={counts['oom_kill']}")
    kind = "warning" if (f["oom_kill"] or 0) > 0 else "notice"
    print(line)
    print(f"::{kind} title=pool-evidence::{line}")
    append("GITHUB_OUTPUT", f"peak_mb={mb(f['peak'])}\nlimit_mb={limit}\n"
                            f"failcnt={counts['failcnt']}\noom_kill={counts['oom_kill']}\n")
    append("GITHUB_STEP_SUMMARY", f"    {line}\n\n")
    return 0


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - never fail the job
        print(f"pool-evidence: failed ({type(exc).__name__})")
    sys.exit(0)
