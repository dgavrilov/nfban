# nfban

A single Bash script for managing permanent IPv4 bans in nftables.

Bans are stored as plain text files under `/etc/nfban`, loaded into a dedicated
`inet nfban` table at boot by a systemd unit, and updated live by `nfban add` and
`nfban remove` without reloading the whole set.

## Features

- Bans single IPv4 addresses and CIDR subnets.
- Drops matching source addresses in both the `input` and `forward` hooks.
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
- `jq`, only for `nfban status --check`
- Root privileges; `sudo` is used in hints if available

## Installation

Install the script at a stable path. `init` writes this path into the systemd
unit, so the path must contain only letters, digits, `_`, `.`, `/` and `-`.

```sh
sudo install -m 755 nfban /usr/local/sbin/nfban
sudo nfban init
sudo systemctl start nfban
```

`nfban init` does the following:

- creates `/etc/nfban/hosts/` and `/etc/nfban/cidrs.txt`;
- writes `/etc/systemd/system/nfban.service`;
- enables the unit without starting it.

`init` can be run again safely. It refuses to continue if:

- the unit file exists with different contents;
- an `inet nfban` table already exists before the unit is installed;
- storage from an older layout (`bans`, `blocked.nft`, `table.nft`) is present
  in `/etc/nfban`.

The unit is ordered `After=nftables.service` and declared `PartOf=nftables.service`,
so restarting nftables, which usually flushes the ruleset, reloads the bans as
well.

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
| `init`                | Create storage and enable `nfban.service`               |
| `reload`              | Rebuild live sets from saved bans and switch atomically |
| `add <IPv4\|CIDR>`    | Ban an address or subnet, live and on disk              |
| `remove <IPv4\|CIDR>` | Remove an exact ban, live and on disk (alias: `rm`)     |
| `list`                | Print saved bans in numeric order                       |
| `status [--check]`    | Show ban counts and the state of live rules             |

### Examples

```sh
sudo nfban add 192.0.2.10
sudo nfban add 198.51.100.0/24
sudo nfban rm 192.0.2.10
sudo nfban list
sudo nfban status --check
```

### Adding and removing

- `add` and `remove` update the live set first and save the file only after
  that succeeds. If the live update fails, nothing on disk changes.
- Both commands also repair the live set. Running `add` for an already saved
  ban adds a missing live element; running `remove` for an unsaved ban removes
  a stray one.
- `remove` deletes only the exact entry. Removing `192.0.2.10` does not affect
  a saved `192.0.2.0/24`, and the reverse is also true.
- A new subnet must not overlap any saved subnet. Single hosts are stored
  separately and may lie inside a saved subnet.
- `add` and `remove` need active rules. If none exist, run `nfban reload` or
  `systemctl start nfban`.

### Status

Ban counts come from the saved files. On a terminal, `status` prints a summary:

```text
  Banned hosts     2
  Banned subnets   1
  Live rules       ● active, use --check to compare
```

When stdout is not a terminal, it prints stable `key=value` lines for scripts:

```text
banned_hosts=2
banned_subnets=1
active=available
```

| `active` value | Meaning                                       | Exit code |
| -------------- | --------------------------------------------- | --------- |
| `available`    | Live rules and sets exist                     | 0         |
| `in_sync`      | `--check`: live sets match saved bans exactly | 0         |
| `out_of_sync`  | `--check`: live sets differ from saved bans   | 1         |
| `unavailable`  | Live rules or sets are missing                | 1         |

If the state is `out_of_sync`, run `nfban reload`.

## Storage

```text
/etc/nfban/
├── hosts/
│   ├── 192.000.txt    # hosts in 192.0.0.0/16, one per line
│   └── 198.051.txt
├── cidrs.txt          # subnets, one per line
└── nfban.lock
```

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

  chain input   { type filter hook input   priority -10; policy accept; ... drop }
  chain forward { type filter hook forward priority -10; policy accept; ... drop }
}
```

`reload` alternates between two pairs of sets, `blocked`/`blocked_cidrs` and
`blocked_next`/`blocked_cidrs_next`. The chains always reference exactly one
pair.

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
