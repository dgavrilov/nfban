#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

config_dir=$tmpdir/etc/nfban
unit_file=$tmpdir/etc/systemd/system/nfban.service
mock_bin=$tmpdir/bin
nft_state=$tmpdir/nft_state
nft_log=$tmpdir/nft.log
test_nfban=$tmpdir/nfban

mkdir -p -- "$config_dir/hosts" "${unit_file%/*}" "$mock_bin" "$nft_state"
: >"$config_dir/cidrs.txt"
: >"$config_dir/nfban.lock"
: >"$unit_file"

# Build a sandboxed copy of nfban pointing at temporary paths and bypassing root check.
sed \
  -e "s|^readonly config=/etc/nfban$|readonly config=$config_dir|" \
  -e "s|^readonly unit=/etc/systemd/system/nfban.service$|readonly unit=$unit_file|" \
  -e 's|((EUID != 0))|((0))|g' \
  -e 's|^check_script_owner() {|check_script_owner() { return 0;|' \
  "$repo_root/nfban" >"$test_nfban"
chmod +x -- "$test_nfban"

# Stateful mock nft implementing the subset of commands used by nfban.
cat >"$mock_bin/nft" <<'MOCK_NFT'
#!/usr/bin/env bash
set -euo pipefail

state=${MOCK_NFT_STATE:?}
log=${MOCK_NFT_LOG:?}

printf '%s\n' "$*" >>"$log"

if [[ ${MOCK_NFT_FAIL:-} == 1 ]]; then
  printf 'Error: simulated nft failure\n' >&2
  exit 1
fi

apply_line() {
  local line=$1
  [[ -n $line ]] || return 0
  printf '  %s\n' "$line" >>"$log"
  case $line in
    'add table inet nfban')
      mkdir -p -- "$state/sets" "$state/chains"
      ;;
    'destroy set inet nfban '*)
      local set_name=${line#'destroy set inet nfban '}
      rm -f -- "$state/sets/$set_name"
      ;;
    'add set inet nfban '*)
      local rest=${line#'add set inet nfban '}
      local set_name=${rest%% *}
      mkdir -p -- "$state/sets"
      : >"$state/sets/$set_name"
      ;;
    'add chain inet nfban '*)
      local rest=${line#'add chain inet nfban '}
      local chain=${rest%% *}
      mkdir -p -- "$state/chains"
      touch -- "$state/chains/$chain"
      ;;
    'flush chain inet nfban '*)
      local chain=${line#'flush chain inet nfban '}
      : >"$state/chains/$chain"
      ;;
    'delete chain inet nfban '*)
      local chain=${line#'delete chain inet nfban '}
      rm -f -- "$state/chains/$chain"
      ;;
    'add rule inet nfban '*)
      local rest=${line#'add rule inet nfban '}
      local chain=${rest%% *}
      local rule=${rest#"$chain "}
      printf '%s\n' "$rule" >>"$state/chains/$chain"
      ;;
    'add element inet nfban '*)
      local rest=${line#'add element inet nfban '}
      local set_name=${rest%% *}
      local body=${rest#*"{ "}
      body=${body%" }"}
      [[ -f $state/sets/$set_name ]] || { printf 'Error: No such file or directory\n' >&2; exit 1; }
      local item
      IFS=',' read -r -a items <<<"$body"
      for item in "${items[@]}"; do
        item=${item# }
        item=${item% }
        [[ -n $item ]] || continue
        grep -Fxq -- "$item" "$state/sets/$set_name" || printf '%s\n' "$item" >>"$state/sets/$set_name"
      done
      ;;
    'destroy element inet nfban '*)
      local rest=${line#'destroy element inet nfban '}
      local set_name=${rest%% *}
      local body=${rest#*"{ "}
      body=${body%" }"}
      [[ -f $state/sets/$set_name ]] || { printf 'Error: No such file or directory\n' >&2; exit 1; }
      local item
      IFS=',' read -r -a items <<<"$body"
      if [[ $set_name == blocked_cidrs* ]]; then
        for item in "${items[@]}"; do
          item=${item# }
          item=${item% }
          [[ -n $item ]] || continue
          if ! grep -Fxq -- "$item" "$state/sets/$set_name"; then
            printf 'Error: element does not exist\ndestroy element inet nfban %s { %s }\n' "$set_name" "$item" >&2
            exit 1
          fi
        done
      fi
      for item in "${items[@]}"; do
        item=${item# }
        item=${item% }
        [[ -n $item ]] || continue
        grep -Fxv -- "$item" "$state/sets/$set_name" >"$state/sets/$set_name.tmp" || :
        mv -f -- "$state/sets/$set_name.tmp" "$state/sets/$set_name"
      done
      ;;
  esac
}

case ${1-} in
  -f)
    while IFS= read -r line || [[ -n $line ]]; do
      apply_line "$line"
    done
    ;;
  -n)
    if [[ ${2-} == list && ${3-} == chain && ${4-} == inet && ${5-} == nfban ]]; then
      chain=${6-}
      if [[ -f $state/chains/$chain ]]; then
        cat -- "$state/chains/$chain"
        exit 0
      fi
      printf 'Error: No such file or directory\n' >&2
      exit 1
    fi
    ;;
  -t)
    if [[ ${2-} == list && ${3-} == set && ${4-} == inet && ${5-} == nfban ]]; then
      set_name=${6-}
      if [[ -f $state/sets/$set_name ]]; then
        printf 'set %s {}\n' "$set_name"
        exit 0
      fi
      printf 'Error: No such file or directory\n' >&2
      exit 1
    fi
    ;;
  list)
    if [[ ${2-} == chain && ${3-} == inet && ${4-} == nfban ]]; then
      chain=${5-}
      [[ -f $state/chains/$chain ]] && exit 0
      exit 1
    fi
    ;;
  add | destroy)
    apply_line "$*"
    ;;
  *)
    printf 'Error: unsupported mock nft call: %s\n' "$*" >&2
    exit 1
    ;;
esac
MOCK_NFT
chmod +x -- "$mock_bin/nft"

export PATH="$mock_bin:$PATH"
export MOCK_NFT_STATE=$nft_state
export MOCK_NFT_LOG=$nft_log
export NO_COLOR=1
export LC_ALL=C

pass=0
fail=0

assert_eq() {
  local expected=$1 actual=$2 msg=$3
  if [[ $expected == "$actual" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$msg" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

assert_ok() {
  local msg=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (expected exit 0)\n' "$msg" >&2
    fail=$((fail + 1))
  fi
}

assert_fail() {
  local msg=$1
  shift
  if "$@"; then
    printf 'FAIL: %s (expected non-zero exit)\n' "$msg" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

reset_state() {
  rm -rf -- "${config_dir:?}/hosts"/* "${nft_state:?}"/*
  : >"$config_dir/cidrs.txt"
  : >"$nft_log"
}

# 1. Initial reload and status
reset_state
assert_fail 'status unavailable before reload' "$test_nfban" status >/dev/null
assert_ok 'initial reload' "$test_nfban" reload >/dev/null
out=$("$test_nfban" status)
assert_eq $'banned_hosts=0\nbanned_subnets=0\nactive=available' "$out" 'status key=value output'

# 2. Single add, normalization, /0 rejection, covering subnet, overlap rejection
assert_ok 'add host with /32 and leading zeros' "$test_nfban" add 010.0.0.5/32 >/dev/null
assert_ok 'add unaligned CIDR' "$test_nfban" add 192.0.2.77/24 >/dev/null
assert_fail 'reject /0 CIDR' "$test_nfban" add 0.0.0.0/0 2>/dev/null
assert_fail 'reject /0 non-zero CIDR' "$test_nfban" add 192.0.2.1/0 2>/dev/null
assert_fail 'reject invalid octet' "$test_nfban" add 256.0.0.1 2>/dev/null
assert_fail 'reject overlapping CIDR' "$test_nfban" add 192.0.2.128/25 2>/dev/null
out=$("$test_nfban" add 192.0.2.99)
assert_eq '+ Already banned by subnet 192.0.2.0/24' "$out" 'host covered by subnet not saved'
assert_eq $'10.0.0.5\n192.0.2.0/24' "$("$test_nfban" list)" 'list after adds'

# 3. check command
out=$("$test_nfban" check 10.0.0.5)
assert_eq $'banned=yes\nmatch=exact\nentry=10.0.0.5' "$out" 'check exact host'
out=$("$test_nfban" check 192.0.2.42)
assert_eq $'banned=yes\nmatch=subnet\nentry=192.0.2.0/24' "$out" 'check host covered by subnet'
out=$("$test_nfban" check 192.0.2.0/24)
assert_eq $'banned=yes\nmatch=exact\nentry=192.0.2.0/24' "$out" 'check exact CIDR'
out=$("$test_nfban" check 192.0.2.128/25)
assert_eq $'banned=yes\nmatch=subnet\nentry=192.0.2.0/24' "$out" 'check subnet covered by broader CIDR'
rc=0
out=$("$test_nfban" check 198.51.100.1) || rc=$?
assert_eq '1' "$rc" 'check unbanned exit code'
assert_eq 'banned=no' "$out" 'check unbanned output'

# 4. Single remove deletes empty /16 file
assert_ok 'remove last host in /16' "$test_nfban" rm 10.0.0.5 >/dev/null
assert_fail 'empty /16 file removed' test -e "$config_dir/hosts/010.000.txt"

# 5. add --batch: comments, CRLF, duplicates, covered hosts, normalization
printf '# comment\r\n\n  198.51.100.10  # inline\r\n198.51.100.10\n198.51.100.2/32\n203.0.113.55/24\n203.0.113.99\n192.0.2.5\n' \
  | "$test_nfban" add --batch >/dev/null
assert_eq $'192.0.2.0/24\n198.51.100.2\n198.51.100.10\n203.0.113.0/24' "$("$test_nfban" list)" 'list after add --batch'

# 6. add --batch: rejects invalid line and /0 atomically
err=$(printf '198.51.100.20\n0.0.0.0/0\nnot-an-ip\n' | "$test_nfban" add --batch 2>&1 >/dev/null || :)
assert_ok 'reports line 2 for /0' grep -q 'line 2:' <<<"$err"
assert_ok 'reports line 3 for invalid' grep -q 'line 3:' <<<"$err"
assert_fail 'atomic rollback on invalid batch' "$test_nfban" check 198.51.100.20 >/dev/null

# 7. add --batch: duplicate CIDR overlap reports minimum line number (2, not 10)
err=$(
  printf '10.1.0.1\n192.0.2.128/25\n10.1.0.2\n10.1.0.3\n10.1.0.4\n10.1.0.5\n10.1.0.6\n10.1.0.7\n10.1.0.8\n192.0.2.128/25\n' \
    | "$test_nfban" add --batch 2>&1 >/dev/null || :
)
assert_ok 'overlap reports earliest line 2' grep -q '192.0.2.128/25 (line 2) overlaps 192.0.2.0/24 (saved)' <<<"$err"

# 8. remove --batch: exact removal, empty /16 cleanup, missing live CIDR fallback
# Remove a CIDR from mock nft live state to force per-CIDR fallback path.
grep -Fxv '203.0.113.0/24' "$nft_state/sets/blocked_cidrs_next" >"$nft_state/sets/blocked_cidrs_next.tmp" || :
mv -f -- "$nft_state/sets/blocked_cidrs_next.tmp" "$nft_state/sets/blocked_cidrs_next"

out=$(printf '# remove batch\n198.51.100.2\n198.51.100.10\n198.51.100.99\n203.0.113.0/24\n192.0.2.0/24\n' | "$test_nfban" rm --batch)
assert_ok 'batch remove summary hosts' grep -q 'Removed hosts[[:space:]]*2' <<<"$out"
assert_ok 'batch remove summary subnets' grep -q 'Removed subnets[[:space:]]*2' <<<"$out"
assert_ok 'batch remove summary not saved' grep -q 'Not saved[[:space:]]*1' <<<"$out"
assert_eq '' "$("$test_nfban" list)" 'list empty after batch remove'
assert_fail 'empty /16 file deleted after batch remove' test -e "$config_dir/hosts/198.051.txt"

# 8a. remove --dedupe drops hosts covered by subnets, live and on disk
printf '198.51.100.7\n198.51.100.200\n203.0.113.5\n203.0.113.9\n' | "$test_nfban" add --batch >/dev/null
"$test_nfban" add 198.51.100.0/25 >/dev/null
"$test_nfban" add 203.0.113.0/24 >/dev/null
# Drop a covering subnet from the live set: dedupe must restore it before
# removing its hosts.
for set_file in "$nft_state"/sets/blocked_cidrs*; do
  grep -Fxv '203.0.113.0/24' "$set_file" >"$set_file.tmp" || :
  mv -f -- "$set_file.tmp" "$set_file"
done
out=$("$test_nfban" rm --dedupe)
assert_eq '+ Removed 3 host(s) covered by subnets' "$out" 'dedupe summary'
assert_ok 'dedupe restores missing live subnet' grep -rFxq 203.0.113.0/24 "$nft_state/sets"
assert_eq $'198.51.100.0/25\n198.51.100.200\n203.0.113.0/24' "$("$test_nfban" list)" 'list after dedupe'
assert_fail 'dedupe deletes emptied /16 file' test -e "$config_dir/hosts/203.000.txt"
assert_fail 'dedupe removes covered host from live set' grep -rFxq 203.0.113.5 "$nft_state/sets"
assert_ok 'dedupe keeps uncovered host in live set' grep -rFxq 198.51.100.200 "$nft_state/sets"
out=$("$test_nfban" rm --dedupe)
assert_eq '+ No hosts covered by subnets' "$out" 'dedupe is a no-op when nothing is covered'
printf '198.51.100.0/25\n198.51.100.200\n203.0.113.0/24\n' | "$test_nfban" rm --batch >/dev/null

# 9. list | head produces no SIGPIPE stderr noise
for i in $(seq 1 50); do
  printf '10.%d.0.1\n' "$i"
done | "$test_nfban" add --batch >/dev/null
sigpipe_err=$({ "$test_nfban" list 2>&3 | head -n 1 >/dev/null || :; } 3>&1)
assert_eq '' "$sigpipe_err" 'list | head has no stderr noise'

# 10. status suppresses nft stderr when set is missing
rm -f -- "$nft_state/sets/blocked_next"
status_err=$("$test_nfban" status >/dev/null 2>&1 || :)
assert_eq '' "$status_err" 'status produces no nft stderr when set missing'

# 11. reload switches active suffix atomically and rejects invalid/out-of-order files
assert_ok 'reload restores active sets' "$test_nfban" reload >/dev/null
assert_ok 'status available after reload' "$test_nfban" status >/dev/null
printf '0.0.0.0/0\n' >"$config_dir/cidrs.txt"
assert_fail 'reload rejects /0 in cidrs.txt' "$test_nfban" reload >/dev/null 2>&1
: >"$config_dir/cidrs.txt"
assert_ok 'previous rules stay active after failed reload' "$test_nfban" status >/dev/null

# 12. add --batch rejects non-regular file in hosts/
ln -s /dev/null "$config_dir/hosts/198.051.txt"
assert_fail 'add --batch rejects symlink in hosts/' "$test_nfban" add --batch <<<'198.51.100.1' >/dev/null 2>&1
rm -f -- "$config_dir/hosts/198.051.txt"

# 13. self-update: up-to-date, invalid payload rejection, atomic replacement
cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
out=
while (($#)); do
  case $1 in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp -- "${MOCK_UPDATE_SRC:?}" "$out"
MOCK_CURL
chmod +x -- "$mock_bin/curl"

export MOCK_UPDATE_SRC=$tmpdir/update_src
cp -- "$test_nfban" "$tmpdir/nfban.orig"
cp -- "$test_nfban" "$MOCK_UPDATE_SRC"
out=$("$test_nfban" self-update)
assert_eq '+ Already up to date' "$out" 'self-update reports already up to date'

printf '<html>404</html>\n' >"$MOCK_UPDATE_SRC"
assert_fail 'self-update rejects non-bash download' "$test_nfban" self-update >/dev/null 2>&1
assert_ok 'self-update preserves script on invalid download' cmp -s -- "$test_nfban" "$tmpdir/nfban.orig"

printf '#!/usr/bin/env bash\n# updated\necho updated\n' >"$MOCK_UPDATE_SRC"
out=$("$test_nfban" self-update)
assert_ok 'self-update reports updated path' grep -Fq "+ Updated $test_nfban" <<<"$out"
assert_ok 'self-update replaces script content' cmp -s -- "$MOCK_UPDATE_SRC" "$test_nfban"
assert_ok 'self-update keeps script executable' test -x "$test_nfban"

printf 'Passed: %d, Failed: %d\n' "$pass" "$fail"
((fail == 0))
