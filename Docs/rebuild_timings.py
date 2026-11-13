"""Rebuild DEFAULTS in Timings.lua from the timing readings in playtest console logs.

Run it from the mod folder:

    py Docs/rebuild_timings.py --host HOST.log --client CLIENT.log [--client OTHER.log ...]

It reads the "[PingComp] timing length|cue breed=... anim=... seconds=..." lines that the debug log writes (on by
default in playtest builds), and skips the readings the mod itself ignored. Clients also time the staggers the host
plays on enemies the mod doesn't cover, so only the breeds in REACTION_BREEDS (Shared.lua) are kept, unless
--all-breeds is given. Each entry already in DEFAULTS counts as
earlier readings: "0.82, -- 23" as 23 readings of 0.82, a "saved average" as one. Per animation, readings under
0.3 s are dropped, then those under half the median, and the median of the rest is kept, with how many readings it
came from. An entry with no new readings is left as it is.

Hosts before build 2.2 also timed recoils they had started late (see "Step 2.2 notes" in the brief), so for their
logs add --no-host-cues. --dry-run prints the new table instead of writing it.

Recoil cues of the breeds in VARIABLE_CUE_BREEDS (Shared.lua) are left out: their cue depends on the attack that was
blocked, which build 3.1's cue lines name with "after=...", and the host doesn't use a cue for them.

--host-lengths-only BREED,BREED takes those breeds' stagger lengths from the host logs only. Build 3 clients timed the
Chaos staggers the host had asked to play faster at the speed asked, which those animations never reach, so their
readings of them came out too long; the host left such staggers out (its speed check). For build 3 logs, give it the
breeds in FIXED_SPEED_STAGGER_BREEDS.
"""
import argparse
import collections
import io
import re
import statistics

TIMINGS = "scripts/mods/Ping Compensation/Timings.lua"
SHARED = "scripts/mods/Ping Compensation/Shared.lua"
FLOOR = 0.3  # MIN_SECONDS in Timings.lua
SHARE = 0.5  # MIN_SHARE in Timings.lua
KINDS = ("length", "cue")

# Build 3.1 adds " after=<the blocked attack's animation>" to cue lines. Lines the mod ignored go on with " ignored:".
READING = re.compile(r"\[PingComp\] timing (length|cue) breed=([a-z_0-9]+) anim=([a-z_0-9]+) seconds=([0-9.]+)(?: after=[a-z_0-9]+)?\s*$")
KIND = re.compile(r"^\t(length|cue) = \{$")
BREED = re.compile(r"^\t\t([a-z_0-9]+) = \{$")
ENTRY = re.compile(r"^\t\t\t([a-z_0-9]+) = ([0-9.]+),(?: -- (saved average|[0-9]+))?$")


def breed_set(path, name):
    """The breed names in the table pc.<name> in Shared.lua, or an empty set if there is none."""
    with io.open(path, encoding="utf-8") as f:
        text = f.read()
    match = re.search(r"\b%s = \{(.*?)\}" % name, text, re.S)
    return set(re.findall(r"([a-z_0-9]+) = true", match.group(1))) if match else set()


def read_log(path, kinds, breeds, variable_cues, readings, skipped, no_lengths=frozenset()):
    count = 0
    with io.open(path, encoding="utf-8", errors="replace") as log:
        for line in log:
            match = READING.search(line)
            if match and match.group(1) in kinds:
                kind, breed, anim, seconds = match.groups()
                if breeds is not None and breed not in breeds:
                    skipped[breed] += 1
                    continue
                if kind == "cue" and breed in variable_cues:
                    skipped[breed + " cue (varies)"] += 1
                    continue
                if kind == "length" and breed in no_lengths:
                    skipped[breed + " length (host only)"] += 1
                    continue
                readings[(kind, breed, anim)].append(float(seconds))
                count += 1
    return count


def parse_defaults(text):
    """DEFAULTS as {(kind, breed, anim): (value as written, number of readings, or None for a saved average)}."""
    entries = {}
    kind = breed = None
    for line in text.split("\n"):
        match = KIND.match(line)
        if match:
            kind, breed = match.group(1), None
            continue
        match = BREED.match(line)
        if match and kind:
            breed = match.group(1)
            continue
        match = ENTRY.match(line)
        if match and kind and breed:
            anim, value, note = match.groups()
            entries[(kind, breed, anim)] = (value, int(note) if note and note.isdigit() else None)
    return entries


def write_block(table):
    lines = ["local DEFAULTS = {"]
    for kind in KINDS:
        lines.append("\t%s = {" % kind)
        for breed in sorted({key[1] for key in table if key[0] == kind}):
            lines.append("\t\t%s = {" % breed)
            for anim in sorted(key[2] for key in table if key[0] == kind and key[1] == breed):
                value, count = table[(kind, breed, anim)]
                lines.append("\t\t\t%s = %s, -- %s" % (anim, value, "saved average" if count is None else count))
            lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Rebuild DEFAULTS in Timings.lua from playtest console logs.")
    parser.add_argument("--host", action="append", default=[], help="a host's console log (repeatable)")
    parser.add_argument("--client", action="append", default=[], help="a client's console log (repeatable)")
    parser.add_argument("--no-host-cues", action="store_true", help="skip the hosts' recoil cue readings (builds before 2.2)")
    parser.add_argument("--all-breeds", action="store_true", help="keep breeds the mod doesn't cover too")
    parser.add_argument("--host-lengths-only", default="", help="comma-separated breeds whose stagger lengths come from the host logs only")
    # A wrong shipped value is worse than none: the host ends that stagger or recoil by it, and a machine ignores a
    # reading over 1.5 times the shipped value, so it can never learn the true one.
    parser.add_argument("--min-new", type=int, default=1, help="readings an animation not yet in DEFAULTS needs to be added (default: %(default)s)")
    parser.add_argument("--timings", default=TIMINGS, help="path to Timings.lua (default: %(default)s)")
    parser.add_argument("--shared", default=SHARED, help="path to Shared.lua (default: %(default)s)")
    parser.add_argument("--dry-run", action="store_true", help="print the new table instead of writing it")
    args = parser.parse_args()
    if not args.host and not args.client:
        parser.error("give at least one --host or --client log")

    breeds = None if args.all_breeds else breed_set(args.shared, "REACTION_BREEDS")
    variable_cues = breed_set(args.shared, "VARIABLE_CUE_BREEDS")
    readings = collections.defaultdict(list)
    skipped = collections.Counter()
    for path in args.host:
        kinds = ("length",) if args.no_host_cues else KINDS
        print("%s: %d readings" % (path, read_log(path, kinds, breeds, variable_cues, readings, skipped)))
    host_only = frozenset(name.strip() for name in args.host_lengths_only.split(",") if name.strip())
    for path in args.client:
        print("%s: %d readings" % (path, read_log(path, KINDS, breeds, variable_cues, readings, skipped, host_only)))
    if skipped:
        print("skipped: %s" % ", ".join("%s %d" % item for item in sorted(skipped.items())))

    with io.open(args.timings, encoding="utf-8", newline="") as f:
        source = f.read()
    newline = "\r\n" if "\r\n" in source else "\n"
    source = source.replace("\r\n", "\n")
    start = source.index("local DEFAULTS = {")
    end = source.index("\n}\n", start) + 3
    old = parse_defaults(source[start:end])

    table = dict(old)
    dropped = 0
    changes = []
    too_few = []
    for key in sorted(readings):
        values = list(readings[key])
        if key in old:
            value, count = old[key]
            values.extend([float(value)] * (count or 1))
        kept = [v for v in values if v >= FLOOR]
        if not kept:
            dropped += len(values)
            continue
        median = statistics.median(kept)
        kept = [v for v in kept if v >= median * SHARE]
        dropped += len(values) - len(kept)
        name = "%s %s %s" % key
        if key not in old and len(kept) < args.min_new:
            too_few.append("%s (%d)" % (name, len(kept)))
            continue
        value = "%.2f" % statistics.median(kept)
        table[key] = (value, len(kept))
        if key not in old:
            changes.append("new      %s = %s (%d readings)" % (name, value, len(kept)))
        elif abs(float(old[key][0]) - float(value)) >= 0.02:
            changes.append("changed  %s = %s -> %s" % (name, old[key][0], value))

    for line in changes:
        print(line)
    if too_few:
        print("not added, fewer than %d readings: %s" % (args.min_new, ", ".join(too_few)))
    for kind in KINDS:
        print("%s: %d animations" % (kind, sum(1 for key in table if key[0] == kind)))
    print("readings dropped (under %.1f s, or under half the median): %d" % (FLOOR, dropped))

    block = write_block(table)
    if args.dry_run:
        print()
        print(block)
        return
    with io.open(args.timings, "w", encoding="utf-8", newline="") as f:
        f.write((source[:start] + block + source[end:]).replace("\n", newline))
    print("Wrote %s. Check that the comment above DEFAULTS still names the playtests the numbers come from." % args.timings)


if __name__ == "__main__":
    main()
