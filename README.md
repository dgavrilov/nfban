# nfban

A single Bash script for managing permanent IPv4 bans and an allowlist in
nftables.

Bans and the allowlist are stored as plain text files under `/etc/nfban`,
loaded into a dedicated `inet nfban` table at boot by a systemd unit, and
updated live by `nfban block` and `nfban allow` without reloading the whole set.

## Features

- Bans single IPv4 addresses and CIDR subnets.
- Drops matching source addresses in `prerouting` at priority `raw`, before
  connection tracking, so banned traffic creates no conntrack entries and never
  reaches local services or containers.
- Uses its own `inet nfban` table and leaves the rest of the ruleset alone.
- Allowlisted addresses and subnets are accepted before bans are checked, so
  they override bans without changing them: a host can be allowed inside a
  banned subnet, and removing it from the allowlist makes the ban effective
  again.
- Reloads atomically: a fresh copy of the sets is loaded in batches of 16384
  elements, then rules switch to it in a single kernel transaction. If loading
  fails, the previous rules stay active.
- Stores bans in sorted plain-text files: one file per `/16` for hosts, one file
  for subnets.
- Normalizes input: `192.0.2.77/24` is saved as `192.0.2.0/24`, and
  `192.0.2.10/32` is saved as `192.0.2.10`. Prefix `/0` is rejected to prevent
  accidentally blocking all IPv4 traffic.
- Serializes concurrent invocations with `flock`.

IPv6 is not supported.

## Requirements

- Linux with systemd
- Bash
- `nft` and a kernel that support the `destroy` command
- `flock` (util-linux), GNU coreutils, `awk`, `xargs`, `grep`
- `curl` or `wget` (for `setup.sh` and `self-update`)
- Root privileges for every command except `block list`, `allow list` and
  `check`; `sudo` is used in hints if available

On Debian and Ubuntu, `nfban init` installs missing `nftables` and `util-linux`
packages with `apt-get`. On other systems install them manually.

## Installation

Quick install (downloads `nfban` to `/usr/local/sbin/nfban`, runs `nfban init`,
and starts `nfban.service`):

```sh
curl -fsSL https://raw.githubusercontent.com/dgavrilov/nfban/master/setup.sh | sudo sh
```

Or install manually from a local copy. Place the script at a stable path: `init`
writes this path into the systemd unit, so the path must contain only letters,
digits, `_`, `.`, `/` and `-`. The unit runs the script as root at boot, so the
script and every directory above it must be owned by root and writable only by
root.

```sh
sudo install -m 755 nfban /usr/local/sbin/nfban
sudo nfban init
sudo systemctl start nfban
```

`nfban init` does the following:

- installs `nftables` and `util-linux` via `apt-get` if `nft` or `flock` is
  missing, and warns if `nftables.service` is enabled after that;
- creates `/etc/nfban/hosts/`, `/etc/nfban/cidrs.txt` and
  `/etc/nfban/allow.txt` and makes `/etc/nfban` readable by all users (this
  also fixes installs made by older versions, which created it readable by root
  only);
- writes `/etc/systemd/system/nfban.service`, replacing a unit written by an
  older version for the same script;
- enables the unit without starting it.

`init` can be run again safely. It refuses to continue if:

- the script or a directory above it is not owned by root or is writable by
  others;
- the unit file exists but was not written by nfban for this script path;
- an `inet nfban` table already exists before the unit is installed;
- storage from an older layout (`bans`, `blocked.nft`, `table.nft`) is present
  in `/etc/nfban`.

The unit is ordered `Before=network-online.target`. The network comes up in
parallel with loading the bans, but services that wait for the network, such as
Angie or Docker, start only after the bans are active. With about a million bans
this delays them by several seconds. Services ordered only after
`network.target`, such as sshd, are not delayed.

The unit is also ordered `After=nftables.service` and declared
`PartOf=nftables.service`, so restarting nftables reloads the bans as well. It
does not pull in `nftables.service`: that service loads `/etc/nftables.conf`,
which usually starts with `flush ruleset` and wipes rules managed by ufw, Docker
or fail2ban. On such hosts keep `nftables.service` disabled or masked; nfban
creates its own table and does not need it.

## Usage

```text
nfban <init|reload|block|allow|check|status|self-update> [subcommand] [argument]
```

Every command accepts `-h` or `--help`.

On a terminal, output is framed by blank lines and uses colors and Unicode
symbols. Colors are disabled when the stream is not a terminal, `TERM=dumb`, or
[`NO_COLOR`](https://no-color.org) is set. Symbols fall back to ASCII unless the
locale is UTF-8. Errors and warnings go to stderr; errors suggest a command to
run next.

| Command                    | Description                                               |
| -------------------------- | --------------------------------------------------------- |
| `init`                     | Install packages, create storage, enable the unit         |
| `reload`                   | Rebuild live sets from saved files and switch atomically  |
| `block [add] <IPv4\|CIDR>` | Ban an address or subnet, live and on disk                |
| `block [add] --batch`      | Ban addresses and subnets read from stdin                 |
| `block rm <IPv4\|CIDR>`    | Remove an exact ban, live and on disk (alias: `remove`)   |
| `block rm --batch`         | Remove exact bans read from stdin                         |
| `block rm --dedupe`        | Remove hosts covered by saved subnets                     |
| `block list`               | Print saved bans in numeric order (no root needed)        |
| `allow [add] <IPv4\|CIDR>` | Allowlist an address or subnet, live and on disk          |
| `allow [add] --batch`      | Allowlist addresses and subnets read from stdin           |
| `allow rm <IPv4\|CIDR>`    | Remove an exact allowlist entry (alias: `remove`)         |
| `allow rm --batch`         | Remove exact allowlist entries read from stdin            |
| `allow list`               | Print the allowlist in numeric order (no root needed)     |
| `check <IPv4\|CIDR>`       | Check if an address or subnet is blocked (no root needed) |
| `status`                   | Show counts and the state of live rules                   |
| `self-update`              | Download the latest version and replace the script        |

Versions before the allowlist used top-level `add`, `remove`/`rm` and `list`;
these are now `block add`, `block rm` and `block list`. After upgrading, run
`nfban init && nfban reload` to create `allow.txt` and the allowlist set.

`add` may be omitted: `nfban block 192.0.2.10` is `nfban block add 192.0.2.10`,
and the same holds for `allow`.

### Examples

```sh
sudo nfban block add 192.0.2.10
sudo nfban block add 198.51.100.0/24
sudo nfban block add --batch < bans.txt
sudo nfban block rm 192.0.2.10
sudo nfban block rm --batch < unbans.txt
sudo nfban block rm --dedupe
sudo nfban allow add 198.51.100.42
sudo nfban allow rm 198.51.100.42
nfban check 198.51.100.42
nfban block list
nfban allow list
sudo nfban status
sudo nfban self-update
```

### Adding and removing

- `add` and `rm` update the live set first and save the file only after that
  succeeds. If the live update fails, nothing on disk changes.
- Both commands also repair the live set. Running `add` for an already saved
  entry adds a missing live element; running `rm` for an unsaved entry removes
  a stray one.
- `rm` deletes only the exact entry. Removing `192.0.2.10` does not affect a
  saved `192.0.2.0/24`, and the reverse is also true. When the last host in a
  `/16` file is removed, the empty file is deleted.
- A new banned subnet must not overlap any saved banned subnet.
- A host inside a saved subnet is not banned again: `block add` reports the
  covering subnet and only restores it in the live set if it is missing. Hosts
  saved before their subnet was added stay in the host files until
  `nfban block rm --dedupe` removes them from the live set and the host files.
  It first restores the covering subnets in the live set if they are missing,
  so the hosts stay banned throughout.
- `block add` saves a ban even if an allowlist entry fully covers it, and warns
  that the ban has no effect. It takes effect once the allowlist entry is
  removed.
- `add` and `rm` need active rules. If none exist, run `nfban reload` or
  `systemctl start nfban`.

### Allowlist

The allowlist overrides bans only. Its `accept` ends the `inet nfban` chain;
other tables, such as those of ufw, Docker or fail2ban, still see the packet.

- Hosts and subnets share one file and one live interval set.
- Entries must not overlap: `allow add 192.0.2.0/24` is rejected while
  `192.0.2.5` is allowlisted, and the reverse is also true.
- `allow rm` keeps `allow.txt` even when it becomes empty.

### Batch operations

`nfban block add --batch`, `nfban block rm --batch`, `nfban allow add --batch`
and `nfban allow rm --batch` read one address or subnet per line from stdin.
On a terminal, paste the list and press Ctrl-D. Surrounding whitespace and `\r`
are trimmed; blank lines and `#` comments are skipped.

```sh
sudo nfban block add --batch < bans.txt
sudo nfban block rm --batch < unbans.txt
sudo nfban allow add --batch < allow.txt
```

- Every line is checked first. If any line is invalid or (for `add --batch`) an
  entry overlaps a saved entry or another entry in the list, all such lines
  are reported with their line numbers and nothing changes. For bans, only
  subnets are checked for overlaps.
- `block add --batch` skips duplicates, already saved bans and hosts inside a
  saved or listed subnet, the same way as a single `block add`. It warns how
  many listed bans the allowlist overrides.
- `rm --batch` removes only exact matches; `block rm --batch` also deletes
  `/16` files that become empty.
- The live sets are updated in batches of 16384 elements, then every touched
  file is rewritten once. If the live update fails, nothing on disk changes;
  run `nfban reload` to resync the live sets.

### Checking an address

`nfban check <IPv4|CIDR>` checks saved bans and the allowlist without requiring
root. It exits `0` if the address or subnet is blocked, that is, banned
directly or by a covering subnet and not fully covered by an allowlist entry,
and `1` otherwise. A subnet only partly covered by the allowlist counts as
blocked.

On a terminal, it prints the result with the matching ban and allowlist
entries. When stdout is not a terminal, it prints `key=value` lines:

```text
blocked=no
banned=yes
ban_match=subnet
ban_entry=198.51.100.0/24
allowed=yes
allow_match=exact
allow_entry=198.51.100.42
```

`ban_match`/`ban_entry` appear only with `banned=yes`, and
`allow_match`/`allow_entry` only with `allowed=yes`. A match is `exact` or
`subnet`.

### Status

Counts come from the saved files. On a terminal, `status` prints a summary:

```text
  Banned hosts     2
  Banned subnets   1
  Allowlisted      1
  Live rules       ● active
```

When stdout is not a terminal, it prints stable `key=value` lines for scripts:

```text
banned_hosts=2
banned_subnets=1
allowlisted=1
active=available
```

| `active` value | Meaning                        | Exit code |
| -------------- | ------------------------------ | --------- |
| `available`    | Live rules and sets exist      | 0         |
| `unavailable`  | Live rules or sets are missing | 1         |

If the state is `unavailable`, run `nfban reload`.

## Storage

```text
/etc/nfban/
├── hosts/
│   ├── 192.000.txt    # hosts in 192.0.0.0/16, one per line
│   └── 198.051.txt
├── cidrs.txt          # subnets, one per line
├── allow.txt          # allowlisted hosts and subnets, one per line
└── nfban.lock
```

Directories are `0755` and files `0644`, so any local user can read the bans and
the allowlist and run `nfban block list` and `nfban allow list`. Only root can
change them.

Every file is sorted numerically. Host files use zero-padded names so they sort
in numeric order. Subnets must be aligned to their prefix. Subnets in
`cidrs.txt` must not overlap, and neither may entries in `allow.txt`.

The files can be edited by hand, followed by `nfban reload`. `reload` validates
every entry and refuses to switch if an entry is malformed, misaligned,
overlapping or out of order.

## nftables layout

```text
table inet nfban {
  set blocked        { type ipv4_addr; }
  set blocked_cidrs  { type ipv4_addr; flags interval; }
  set allowed        { type ipv4_addr; flags interval; }

  chain prerouting {
    type filter hook prerouting priority raw; policy accept;
    ip saddr @allowed accept
    ip saddr @blocked drop
    ip saddr @blocked_cidrs drop
  }
}
```

`reload` alternates between two sets of sets, `blocked`/`blocked_cidrs`/`allowed`
and `blocked_next`/`blocked_cidrs_next`/`allowed_next`. The chain always
references exactly one of them.

Older versions dropped bans in `input` and `forward` chains. The first `reload`
after an upgrade removes them in the same transaction that creates `prerouting`;
until then `block add` and `block rm` keep working with the old chains.

## Uninstall

Stopping the service does not remove the rules. To remove nfban completely:

```sh
sudo systemctl disable --now nfban
sudo nft delete table inet nfban
sudo rm /etc/systemd/system/nfban.service
sudo systemctl daemon-reload
sudo rm -r /etc/nfban            # deletes all saved bans
sudo rm /usr/local/sbin/nfban
```
