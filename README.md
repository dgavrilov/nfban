# nfban

A single Bash script for managing permanent IPv4 bans in nftables.

Bans are stored as plain text files under `/etc/nfban`, loaded into a dedicated
`inet nfban` table at boot by a systemd unit, and updated live by `nfban add` and
`nfban remove` without reloading the whole set.

## Features

- Bans single IPv4 addresses and CIDR subnets.
- Drops matching source addresses in `prerouting` at priority `raw`, before
  connection tracking, so banned traffic creates no conntrack entries and never
  reaches local services or containers.
- Uses its own `inet nfban` table and leaves the rest of the ruleset alone.
- Reloads atomically: a fresh copy of the sets is loaded in batches of 4096
  elements, then rules switch to it in a single kernel transaction. If loading
  fails, the previous rules stay active.
- Stores bans in sorted plain-text files: one file per `/16` for hosts, one file
  for subnets.
- Normalizes input: `192.0.2.77/24` is saved as `192.0.2.0/24`, and
  `192.0.2.10/32` is saved as `192.0.2.10`.
- Serializes concurrent invocations with `flock`.

IPv6 is not supported.

## Requirements

- Linux with systemd
- Bash
- `nft` and a kernel that support the `destroy` command
- `flock` (util-linux), GNU coreutils, `awk`, `xargs`, `grep`
- Root privileges for every command except `list`; `sudo` is used in hints if
  available

On Debian and Ubuntu, `nfban init` installs missing `nftables` and `util-linux`
packages with `apt-get`. On other systems install them manually.

## Installation

Install the script at a stable path. `init` writes this path into the systemd
unit, so the path must contain only letters, digits, `_`, `.`, `/` and `-`.
The unit runs the script as root at boot, so the script and every directory
above it must be owned by root and writable only by root.

```sh
sudo install -m 755 nfban /usr/local/sbin/nfban
sudo nfban init
sudo systemctl start nfban
```

`nfban init` does the following:

- installs `nftables` and `util-linux` via `apt-get` if `nft` or `flock` is
  missing, and warns if `nftables.service` is enabled after that;
- creates `/etc/nfban/hosts/` and `/etc/nfban/cidrs.txt` and makes `/etc/nfban`
  readable by all users (this also fixes installs made by older versions, which
  created it readable by root only);
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
nfban <init|reload|add|remove|rm|list|status> [argument]
```

Every command accepts `-h` or `--help`.

On a terminal, output is framed by blank lines and uses colors and Unicode
symbols. Colors are disabled when the stream is not a terminal, `TERM=dumb`, or
[`NO_COLOR`](https://no-color.org) is set. Symbols fall back to ASCII unless the
locale is UTF-8. Errors go to stderr and suggest a command to run next.

| Command               | Description                                             |
| --------------------- | ------------------------------------------------------- |
| `init`                | Install packages, create storage, enable the unit       |
| `reload`              | Rebuild live sets from saved bans and switch atomically |
| `add <IPv4\|CIDR>`    | Ban an address or subnet, live and on disk              |
| `add --batch`         | Ban addresses and subnets read from stdin               |
| `remove <IPv4\|CIDR>` | Remove an exact ban, live and on disk (alias: `rm`)     |
| `list`                | Print saved bans in numeric order (no root needed)      |
| `status`              | Show ban counts and the state of live rules             |

### Examples

```sh
sudo nfban add 192.0.2.10
sudo nfban add 198.51.100.0/24
sudo nfban add --batch < bans.txt
sudo nfban rm 192.0.2.10
sudo nfban list
sudo nfban status
```

### Adding and removing

- `add` and `remove` update the live set first and save the file only after
  that succeeds. If the live update fails, nothing on disk changes.
- Both commands also repair the live set. Running `add` for an already saved
  ban adds a missing live element; running `remove` for an unsaved ban removes
  a stray one.
- `remove` deletes only the exact entry. Removing `192.0.2.10` does not affect
  a saved `192.0.2.0/24`, and the reverse is also true.
- A new subnet must not overlap any saved subnet.
- A host inside a saved subnet is not saved again: `add` reports the covering
  subnet and only restores it in the live set if it is missing. Hosts saved
  before their subnet was added stay in the host files.
- `add` and `remove` need active rules. If none exist, run `nfban reload` or
  `systemctl start nfban`.

### Adding in batches

`nfban add --batch` reads one address or subnet per line from stdin. On a
terminal, paste the list and press Ctrl-D. Surrounding whitespace and `\r` are
trimmed; blank lines and `#` comments are skipped.

```sh
sudo nfban add --batch < bans.txt
```

- Every line is checked first. If any line is invalid or a subnet overlaps a
  saved subnet or another subnet in the list, all such lines are reported with
  their line numbers and nothing is added.
- Duplicates, already saved bans and hosts inside a saved or listed subnet are
  skipped, the same way as with a single `add`.
- The live sets are updated in batches of 4096 elements, then every `/16` file
  that gains hosts is rewritten once. If the live update fails, nothing on disk
  changes; run `nfban reload` to drop elements loaded before the failure.
- The summary shows new hosts, new subnets, already banned entries and hosts
  covered by subnets.

### Status

Ban counts come from the saved files. On a terminal, `status` prints a summary:

```text
  Banned hosts     2
  Banned subnets   1
  Live rules       ● active
```

When stdout is not a terminal, it prints stable `key=value` lines for scripts:

```text
banned_hosts=2
banned_subnets=1
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
└── nfban.lock
```

Directories are `0755` and files `0644`, so any local user can read the bans and
run `nfban list`. Only root can change them.

Every file is sorted numerically. Host files use zero-padded names so they sort
in numeric order. Subnets must be aligned to their prefix and must not overlap.

The files can be edited by hand, followed by `nfban reload`. `reload` validates
every entry and refuses to switch if an entry is malformed, misaligned or out of
order.

## nftables layout

```text
table inet nfban {
  set blocked        { type ipv4_addr; }
  set blocked_cidrs  { type ipv4_addr; flags interval; }

  chain prerouting { type filter hook prerouting priority raw; policy accept; ... drop }
}
```

`reload` alternates between two pairs of sets, `blocked`/`blocked_cidrs` and
`blocked_next`/`blocked_cidrs_next`. The chain always references exactly one
pair.

Older versions dropped bans in `input` and `forward` chains. The first `reload`
after an upgrade removes them in the same transaction that creates `prerouting`;
until then `add` and `remove` keep working with the old chains.

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
