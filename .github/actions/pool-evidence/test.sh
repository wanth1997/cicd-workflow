#!/usr/bin/env bash
# pool-evidence (evidence.py): the pool-evidence line from fake cgroup v2 and
# v1 trees, the mount root only when mountinfo says it is the job's own cgroup,
# n/a for what cannot be read, a warning on an OOM kill, and exit 0 on every
# path.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "pool-evidence test: $*" >&2; exit 1; }
cases=0
mib=1048576

# put FILE CONTENT: a cgroup file under the fake root.
put() { mkdir -p "$(dirname "$tmp/cg/$1")"; printf '%s\n' "$2" > "$tmp/cg/$1"; }
fresh() { rm -rf "$tmp/cg" "$tmp/mountinfo"; mkdir -p "$tmp/cg"; printf '%s\n' "$1" > "$tmp/proc"; }
# mount ROOT POINT [FSTYPE [SUPER-OPTIONS]]: one more mountinfo line.
mount() {
  printf '36 35 0:30 %s %s rw,nosuid,nodev,noexec,relatime shared:10 master:2 - %s cgroup %s\n' \
    "$1" "$2" "${3:-cgroup}" "${4:-rw,memory}" >> "$tmp/mountinfo"
}
evidence() { # [VAR=VALUE ...]: sets out, code, line
  code=0
  : > "$tmp/out"
  : > "$tmp/summary"
  out="$(env -i PATH="$PATH" RUNNER_NAME=pool-win-heavy-example-app-1234 GITHUB_OUTPUT="$tmp/out" \
    GITHUB_STEP_SUMMARY="$tmp/summary" POOL_EVIDENCE_CGROUP_ROOT="$tmp/cg" \
    POOL_EVIDENCE_PROC_CGROUP="$tmp/proc" POOL_EVIDENCE_MOUNTINFO="$tmp/mountinfo" "$@" python3 -I "$here/evidence.py" 2>&1)" || code=$?
  line="$(grep '^pool-evidence: ' <<<"$out" | head -n 1 || true)"
}
want() { # CASE LINE-AFTER-"pool-evidence: "
  cases=$((cases + 1))
  [[ "$code" == 0 ]] || fail "$1: exit $code"$'\n'"$out"
  [[ "$line" == "pool-evidence: $2" ]] || fail "$1: got '$line'"$'\n'"want 'pool-evidence: $2'"
}
annotated() { # CASE KIND
  grep -qxF "::$2 title=pool-evidence::$line" <<<"$out" || fail "$1: no $2 with the line"$'\n'"$out"
}

# cgroup v2 inside a container (cgroup namespace: the job's cgroup is "/").
fresh "0::/"
put cgroup.controllers "cpu memory pids"
put memory.peak $((2600 * mib + 5))
put memory.max $((4096 * mib))
put memory.events $'low 0\nhigh 0\nmax 12\noom 1\noom_kill 0\noom_group_kill 0'
evidence
want "v2 container" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=2600 limit_mb=4096 failcnt=12 oom_kill=0"
annotated "v2 container" notice
grep -qxF "    $line" "$tmp/summary" || fail "summary: $(cat "$tmp/summary")"
diff "$tmp/out" <(printf 'peak_mb=2600\nlimit_mb=4096\nfailcnt=12\noom_kill=0\n') || fail "outputs"

put memory.events $'max 3\noom 2\noom_kill 2'
evidence
want "an OOM kill" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=2600 limit_mb=4096 failcnt=3 oom_kill=2"
annotated "an OOM kill" warning

put memory.max max
rm "$tmp/cg/memory.peak"
evidence
want "no limit, a kernel without memory.peak" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=n/a limit_mb=max failcnt=3 oom_kill=2"

# cgroup v2 without a namespace: the step's own cgroup below the root.
fresh "0::/ci-pool.slice/job-1.scope"
put cgroup.controllers "memory"
put memory.peak $((9000 * mib))
put ci-pool.slice/job-1.scope/memory.peak $((1500 * mib))
put ci-pool.slice/job-1.scope/memory.max $((2048 * mib))
put ci-pool.slice/job-1.scope/memory.events $'max 0\noom_kill 0'
evidence
want "v2 nested cgroup" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=1500 limit_mb=2048 failcnt=0 oom_kill=0"
# A membership that cannot be mapped is n/a, never the root's figures (9000 here).
put memory.max $((16384 * mib))
put memory.events $'max 5\noom_kill 4'
for member in "" /../../etc /.. /ci-pool.slice/../job-1.scope /ci-pool.slice/job-2.scope /ci-pool.slice/ \
  ci-pool.slice/job-1.scope /./ci-pool.slice/job-1.scope; do
  printf '0::%s\n' "$member" > "$tmp/proc"
  evidence
  want "v2 membership ${member:-(empty)}" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
done
printf '1:name=systemd:/x\n' > "$tmp/proc"
evidence
want "no v2 membership line" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=n/a peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"

# cgroup v1 (memory controller on its own hierarchy), hybrid hosts included.
fresh $'12:memory:/docker/abc\n4:cpu,cpuacct:/docker/abc\n0::/init.scope'
put memory/docker/abc/memory.max_usage_in_bytes $((3000 * mib))
put memory/docker/abc/memory.limit_in_bytes $((4096 * mib))
put memory/docker/abc/memory.failcnt 7
put memory/docker/abc/memory.oom_control $'oom_kill_disable 0\nunder_oom 0\noom_kill 1'
put cgroup.controllers "pids"
evidence
want "v1" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=3000 limit_mb=4096 failcnt=7 oom_kill=1"
annotated "v1" warning
# v1: the hierarchy root has figures too; an unmapped membership must not read them.
put memory/memory.max_usage_in_bytes $((12000 * mib))
put memory/memory.limit_in_bytes $((16384 * mib))
put memory/memory.failcnt 9
put memory/memory.oom_control $'oom_kill_disable 0\nunder_oom 0\noom_kill 3'
for member in "" /../../etc /docker/.. /docker/missing /docker/abc/ docker/abc; do
  printf '12:memory:%s\n4:cpu,cpuacct:/docker/abc\n' "$member" > "$tmp/proc"
  evidence
  want "v1 membership ${member:-(empty)}" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
done
printf '4:cpu,cpuacct:/docker/abc\n' > "$tmp/proc"
evidence
want "no v1 membership line" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=n/a peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
printf '12:memory:/\n' > "$tmp/proc"
evidence
want "v1 membership exactly /" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=12000 limit_mb=16384 failcnt=9 oom_kill=3"
printf '12:memory:/docker/abc\n4:cpu,cpuacct:/docker/abc\n0::/init.scope\n' > "$tmp/proc"
put memory/docker/abc/memory.limit_in_bytes 9223372036854771712
put memory/docker/abc/memory.oom_control $'oom_kill_disable 0\nunder_oom 0'
evidence
want "v1 without a limit, an old kernel without oom_kill" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=3000 limit_mb=max failcnt=7 oom_kill=n/a"
annotated "v1 no oom_kill" notice

# cgroup v1 in a container without a cgroup namespace (Docker on a v1 host):
# the membership is the host-side path and the memory mount is a bind mount of
# exactly that cgroup, so the figures are at the mount root.
na="runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
own=/ci-pool.slice/docker-abc.scope
fresh "12:memory:$own"$'\n4:cpu,cpuacct:'"$own"
put memory/memory.max_usage_in_bytes $((3100 * mib))
put memory/memory.limit_in_bytes $((4096 * mib))
put memory/memory.failcnt 2
put memory/memory.oom_control $'oom_kill_disable 0\nunder_oom 0\noom_kill 0'
evidence
want "v1 bind mount, no mountinfo" "$na"
mkdir "$tmp/dir"
evidence POOL_EVIDENCE_MOUNTINFO="$tmp/dir"
want "v1 bind mount, mountinfo unreadable" "$na"
: > "$tmp/mountinfo"
evidence
want "v1 bind mount, mountinfo empty" "$na"
printf 'garbage\n1 2 3\n - cgroup cgroup rw,memory\n' > "$tmp/mountinfo"
evidence
want "v1 bind mount, mountinfo garbage" "$na"
rm "$tmp/mountinfo"
mount / / overlay rw
mount "$own" "$tmp/cg/cpu,cpuacct" cgroup rw,cpu,cpuacct
mount "$own" "$tmp/cg/memory"
evidence
want "v1 mount root is the membership" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=3100 limit_mb=4096 failcnt=2 oom_kill=0"
for root in / /ci-pool.slice /ci-pool.slice/docker-abd.scope "$own/" "$own/child" /docker-abc.scope; do
  rm "$tmp/mountinfo"
  mount "$root" "$tmp/cg/memory"
  evidence
  want "v1 mount root $root is not the membership" "$na"
done
rm "$tmp/mountinfo"
mount "$own" "$tmp/cg/memory" tmpfs rw,memory
evidence
want "v1 mount is not a cgroup mount" "$na"
rm "$tmp/mountinfo"
mount "$own" "$tmp/cg/memory" cgroup rw,cpu,cpuacct
evidence
want "v1 mount is another controller" "$na"
rm "$tmp/mountinfo"
mount "$own" "$tmp/cg/memory/sub"
mount "$own" "$tmp/cg/memoryx"
evidence
want "v1 membership mounted somewhere else" "$na"
rm "$tmp/mountinfo"
mount "$own" "$tmp/cg/memory"
mount /other "$tmp/cg/memory"
evidence
want "v1 a later mount at the same place" "$na"
rm "$tmp/mountinfo"
mount "$own" "$tmp/cg/memory"
mount / "$tmp/cg" tmpfs rw
evidence
want "v1 a later mount on a parent directory" "$na"
rm "$tmp/mountinfo"
mount "$own" "$tmp/cg/memory"
printf '12:memory:%s/\n' "$own" > "$tmp/proc"
evidence
want "v1 membership with a trailing slash" "$na"
# The mount root wins over a same-named directory below it (that is a child).
printf '12:memory:%s\n' "$own" > "$tmp/proc"
put "memory$own/memory.max_usage_in_bytes" $((50 * mib))
evidence
want "v1 mount root, same path below it" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=3100 limit_mb=4096 failcnt=2 oom_kill=0"
rm "$tmp/mountinfo"
evidence
want "v1 no mountinfo, path below the mount" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v1 peak_mb=50 limit_mb=n/a failcnt=n/a oom_kill=n/a"

# cgroup v2: the same rule for a cgroup2 mount.
na="${na/cgroup=v1/cgroup=v2}"
fresh "0::$own"
put cgroup.controllers "memory"
put memory.peak $((1700 * mib))
put memory.max $((2048 * mib))
put memory.events $'max 1\noom_kill 0'
evidence
want "v2 bind mount, no mountinfo" "$na"
mount "$own" "$tmp/cg" cgroup2 rw,nsdelegate
evidence
want "v2 mount root is the membership" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=1700 limit_mb=2048 failcnt=1 oom_kill=0"
rm "$tmp/mountinfo"
mount /ci-pool.slice "$tmp/cg" cgroup2 rw,nsdelegate
evidence
want "v2 mount root is not the membership" "$na"
rm "$tmp/mountinfo"
mount "$own" "$tmp/cg" cgroup rw,memory
evidence
want "v2 mount is a v1 mount" "$na"

# Nothing readable, garbage, not a pool runner, odd runner names: still exit 0.
fresh ""
evidence
want "no cgroup" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=n/a peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
evidence POOL_EVIDENCE_PROC_CGROUP="$tmp/missing"
want "no /proc/self/cgroup" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=n/a peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
fresh "0::/"
put cgroup.controllers "memory"
put memory.peak "-5"
put memory.max "12abc"
put memory.events $'max x\noom_kill'
evidence
want "values that are not numbers" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
printf '\xff\xfe' > "$tmp/cg/memory.peak"
evidence
want "a file that is not text" "runner=pool-win-heavy-example-app-1234 pool=yes cgroup=v2 peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
evidence RUNNER_NAME=GitHub-Actions-12
want "a GitHub-hosted runner" "runner=GitHub-Actions-12 pool=no cgroup=v2 peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
evidence RUNNER_NAME=$'pool-x\n::error::y'
want "a runner name with a newline" "runner=pool-x???error??y pool=yes cgroup=v2 peak_mb=n/a limit_mb=n/a failcnt=n/a oom_kill=n/a"
grep -q '^::error' <<<"$out" && fail "the runner name injected a workflow command"
evidence RUNNER_NAME= GITHUB_OUTPUT="$tmp/no-such-dir/out"
cases=$((cases + 1))
[[ "$code" == 0 ]] || fail "an unwritable GITHUB_OUTPUT failed the step (exit $code)"
grep -q '^pool-evidence: failed (' <<<"$out" || fail "an unwritable GITHUB_OUTPUT was not reported"$'\n'"$out"

echo "pool-evidence: $cases cases passed (cgroup v2, v1, mount root by mountinfo, n/a, OOM warning, exit 0)"
