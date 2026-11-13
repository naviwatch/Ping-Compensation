"""Rebuild DEFAULTS in Timings.lua from scratch from the timing readings in playtest console logs (build 3.2, D43).

Run it from the mod folder, with every log that has readings (host and client logs alike; each log's side is worked
out from its lines):

    py Docs/rebuild_timings.py [options] LOG [LOG ...]

Readings come from the debug log's "[PingComp] timing length|cue|stunned breed=... anim=... seconds=..." lines, and,
for recoils, from the host's "host swing=... recoil=... ended: ..." lines (build 3.1 on): their cue= time when it isn't
"(learned)", their stunned= time (3.2 on), and in 3.1 the time a recoil lasted when the behaviour tree ended it before
its cue (only anim_cb_stunned_finished does that). Lines the mod marked " ignored:" are left out, and so are a host's
readings of staggers it played faster (the "speed asked" line just before them). Only breeds in REACTION_BREEDS
(Shared.lua) are kept. The values already in DEFAULTS are not counted: the rebuild starts clean.

Which readings count:
  * A reading that names its speed (3.2 on) counts only at normal speed (speed=1.00).
  * --normal-speed LOG: the readings of that log, which doesn't name speeds, were all taken at normal speed (the build
    3.1 playtest's: one client, so no other client's sped-up staggers on its screen, and the host's are left out
    above). Repeatable.
  * Other logs that don't name speeds may hold staggers timed at a speed they didn't reach, which only ever come out
    too long. For those, only an animation's lowest group of readings counts (see below).
  * --no-host-cues LOG: leave out that host log's recoil cue readings (hosts before build 3 timed some from the wrong
    start). Repeatable.

Per animation (and for a recoil, per blocked attack): readings under 0.3 s are dropped, then those under half the
median (an earlier animation's callback). The rest are put in groups, a new group starting wherever two readings in a
row are more than max(0.03 s, 2.5%) apart. The value is the median of the lowest group with at least a twentieth of
the readings, with how many readings it has. Higher groups are listed, and so is a chosen group wider than 8%, which
may run into readings taken too fast. If the readings taken at normal speed split into groups of their own, the
animation isn't shipped until the key it depends on is known, and is listed. Recoils are never played faster, so all
their readings count as taken at normal speed. A stagger length needs --min-readings readings (default 2) in its
group; a recoil timing needs --min-recoil-readings (default 1), since one recoil reading is exact to a frame or two.

A recoil's timings (cue, stunned) depend on the attack it interrupted for some enemies. For each recoil animation:
if two or more attacks have values and they differ by more than 0.05 s, the values are shipped per attack; if they
agree, or the readings that don't name the attack (logs before 3.1) agree with the one attack that has a value, one
value covers every attack. With only one attack known and nothing else to go by, it is shipped for that attack alone.

--dry-run prints the new table instead of writing it. Then check that the comment above DEFAULTS still names the logs
the numbers come from.
"""
import argparse
import collections
import io
import re
import statistics

TIMINGS = "scripts/mods/Ping Compensation/Timings.lua"
SHARED = "scripts/mods/Ping Compensation/Shared.lua"
KINDS = ("length", "cue", "stunned")
BY_ATTACK = ("cue", "stunned")
FLOOR = 0.3  # MIN_SECONDS in Timings.lua
SHARE = 0.5  # MIN_SHARE in Timings.lua
GAP_SECONDS = 0.03
GAP_SHARE = 0.025
WIDE_SHARE = 0.08  # a chosen group wider than this is flagged: it may run into readings taken too fast
MIN_GROUP_SHARE = 0.05
SPLIT_SHARE = 0.15  # a group of normal-speed readings this big beside the lowest one is a split
ATTACK_TOLERANCE = 0.05

STAMP = r"^(\d\d:\d\d:\d\d\.\d+)"
READING = re.compile(STAMP + r".*\[PingComp\] timing (length|cue|stunned) breed=([a-z_0-9]+) anim=([a-z_0-9]+) seconds=([0-9.]+)(?: after=([a-z_0-9]+))?(?: speed=([0-9.]+))?(.*)$")
SPEED_LINE = re.compile(STAMP + r".*\[PingComp\] host stagger=\d+ from=.* enemy=([a-z_0-9]+) anim=([a-z_0-9]+) speed asked=")
RECOIL_END = re.compile(r"\[PingComp\] host swing=\d+ recoil=([a-z_0-9]+) enemy=([a-z_0-9]+) ended: ([^;]*); kind=(.+?) blocker=.*? after=([a-z_0-9]+) from_frame=\S+ lasted=([0-9.]+)s timer_left=\S+ cue=(not reached|[0-9.]+s(?: \(learned\))?) known_cue=\S+(?: stunned=(not reached|[0-9.]+s(?: \(learned\))?))?")
TIME = re.compile(r"^([0-9.]+)s$")


def breed_set(path, name):
    """The breed names in the table pc.<name> in Shared.lua, or an empty set if there is none."""
    with io.open(path, encoding="utf-8") as f:
        text = f.read()
    match = re.search(r"\b%s = \{(.*?)\}" % name, text, re.S)
    return set(re.findall(r"([a-z_0-9]+) = true", match.group(1))) if match else set()


def side_of(path):
    host = client = 0
    with io.open(path, encoding="utf-8", errors="replace") as log:
        for line in log:
            if "[PingComp] host " in line:
                host += 1
            elif "[PingComp] client " in line:
                client += 1
    return "host" if host > client else "client"


def read_log(path, breeds, normal_speed, no_host_cues, readings, counts):
    """Adds the log's readings to readings[(kind, breed, anim, attack)] as (seconds, trusted)."""
    side = side_of(path)
    last_speed = None
    found = 0
    with io.open(path, encoding="utf-8", errors="replace") as log:
        for line in log:
            match = SPEED_LINE.search(line)
            if match:
                last_speed = match.groups()
                continue
            match = READING.search(line)
            if match:
                stamp, kind, breed, anim, seconds, attack, speed, rest = match.groups()
                if breed not in breeds:
                    continue
                # An earlier animation's callback. Readings the mod ignored as "far longer" than the shipped value
                # (builds before 3.2) are kept: some were real, such as the marauder's cues after its slower attacks.
                if " ignored: not this animation's own" in rest:
                    counts["ignored by the mod as an earlier animation's"] += 1
                    continue
                if side == "host" and kind != "length" and no_host_cues:
                    counts["host cues left out"] += 1
                    continue
                if speed is None and side == "host" and kind == "length" and last_speed == (stamp, breed, anim):
                    counts["host readings of sped-up staggers"] += 1
                    continue
                if speed is not None and abs(float(speed) - 1) > 0.01:
                    counts["not at normal speed"] += 1
                    continue
                # Recoils are never played faster, so their readings count as taken at normal speed: groups in them are
                # attacks that differ, not speeds.
                trusted = speed is not None or normal_speed or kind in BY_ATTACK
                readings[(kind, breed, anim, attack if kind in BY_ATTACK else None)].append((float(seconds), trusted))
                found += 1
                continue
            match = RECOIL_END.search(line)
            if match and side == "host" and not no_host_cues:
                recoil, breed, why, kind, attack, lasted, cue, stunned = match.groups()
                if breed not in breeds or attack == "nil":
                    continue
                trusted = True
                time = TIME.match(cue)
                if time:
                    readings[("cue", breed, recoil, attack)].append((float(time.group(1)), trusted))
                    counts["cues from recoil-end lines"] += 1
                    found += 1
                time = stunned and TIME.match(stunned)
                if time:
                    readings[("stunned", breed, recoil, attack)].append((float(time.group(1)), trusted))
                    counts["stunned cues from recoil-end lines"] += 1
                    found += 1
                elif stunned is None and cue == "not reached" and why == "the behaviour tree (failed)":
                    # Build 3.1 didn't watch anim_cb_stunned_finished, which ends the recoil by clearing
                    # blackboard.blocked: only it and BTBlockedAction.leave clear that flag.
                    readings[("stunned", breed, recoil, attack)].append((float(lasted), trusted))
                    counts["stunned cues from 3.1 recoil ends"] += 1
                    found += 1
    return side, found


def groups_of(values):
    """Sorted values split into groups wherever two in a row are more than max(GAP_SECONDS, GAP_SHARE) apart."""
    values = sorted(values)
    groups = [[values[0]]]
    for value in values[1:]:
        last = groups[-1][-1]
        if value - last > max(GAP_SECONDS, last * GAP_SHARE):
            groups.append([value])
        else:
            groups[-1].append(value)
    return groups


def choose(entries, min_readings):
    """(value, count, note) for one key's readings, or (None, count, why not)."""
    values = [seconds for seconds, _ in entries if seconds >= FLOOR]
    if not values:
        return None, 0, "no readings over %.1f s" % FLOOR
    median = statistics.median(values)
    values = [v for v in values if v >= median * SHARE]
    trusted = sorted(seconds for seconds, ok in entries if ok and seconds >= FLOOR and seconds >= median * SHARE)
    if len(trusted) >= min_readings:
        trusted_groups = groups_of(trusted)
        big = [g for g in trusted_groups if len(g) >= max(2, SPLIT_SHARE * len(trusted))]
        if len(big) > 1:
            return None, len(trusted), "split at normal speed: " + ", ".join("%d around %.2f" % (len(g), statistics.median(g)) for g in big)
        values = trusted
    groups = groups_of(values)
    need = max(min(2, min_readings), MIN_GROUP_SHARE * len(values))
    for index, group in enumerate(groups):
        if len(group) >= need:
            higher = groups[index + 1:]
            notes = []
            if higher:
                notes.append("lowest of %d groups (also %s)" % (len(groups) - index, ", ".join("%d around %.2f" % (len(g), statistics.median(g)) for g in higher)))
            if group[-1] > group[0] * (1 + WIDE_SHARE):
                notes.append("wide group %.2f to %.2f" % (group[0], group[-1]))
            note = "; ".join(notes)
            if len(group) < min_readings:
                return None, len(group), "only %d readings" % len(group)
            return statistics.median(group), len(group), note
    return None, len(values), "no group of %d readings" % need


def build(readings, min_lengths, min_recoils, report):
    table = {kind: {} for kind in KINDS}
    keys = collections.defaultdict(dict)  # (kind, breed, anim) -> {attack: entries}
    for (kind, breed, anim, attack), entries in readings.items():
        keys[(kind, breed, anim)][attack] = entries

    for (kind, breed, anim), by_attack in sorted(keys.items(), key=lambda item: item[0]):
        name = "%s %s %s" % (kind, breed, anim)
        min_readings = min_recoils if kind in BY_ATTACK else min_lengths
        if kind not in BY_ATTACK:
            value, count, note = choose(by_attack[None], min_readings)
            if value is None:
                report.append("not shipped  %s: %s" % (name, note))
                continue
            table[kind].setdefault(breed, {})[anim] = (value, count, note)
            if note:
                report.append("shipped      %s = %.2f (%d readings, %s)" % (name, value, count, note))
            continue

        named = {}
        for attack, entries in sorted(by_attack.items(), key=lambda item: item[0] or ""):
            if attack is None:
                continue
            value, count, note = choose(entries, min_readings)
            if value is None:
                report.append("not shipped  %s after=%s: %s" % (name, attack, note))
            else:
                named[attack] = (value, count, note)
        unnamed = by_attack.get(None, [])
        unnamed_value = choose(unnamed, min_readings) if unnamed else (None, 0, "")
        everything = [entry for entries in by_attack.values() for entry in entries]

        if len(named) >= 2:
            spread = max(v[0] for v in named.values()) - min(v[0] for v in named.values())
            if spread > ATTACK_TOLERANCE:
                table[kind].setdefault(breed, {})[anim] = named
                report.append("by attack    %s: %s%s" % (name, ", ".join("%s %.2f" % (a, v[0]) for a, v in sorted(named.items())), " (%d readings without the attack left out)" % len(unnamed) if unnamed else ""))
                continue
        elif len(named) == 1:
            attack, (value, count, note) = next(iter(named.items()))
            if unnamed_value[0] is None or abs(unnamed_value[0] - value) > ATTACK_TOLERANCE:
                table[kind].setdefault(breed, {})[anim] = named
                report.append("one attack   %s after=%s = %.2f (nothing shows whether other attacks differ)" % (name, attack, value))
                continue
        elif unnamed_value[0] is None:
            report.append("not shipped  %s: %s" % (name, unnamed_value[2] or "no readings"))
            continue

        value, count, note = choose(everything, min_readings)
        if value is None:
            report.append("not shipped  %s (every attack): %s" % (name, note))
            continue
        table[kind].setdefault(breed, {})[anim] = (value, count, note)
        report.append("every attack %s = %.2f (%d readings%s%s)" % (name, value, count, ", attacks: " + ", ".join(sorted(named)) if named else ", attacks not named in these logs", ", " + note if note else ""))
    return table


def comment(count, note):
    return "-- %d%s" % (count, ", " + note.split(" (")[0] if note else "")


def write_block(table):
    lines = ["local DEFAULTS = {"]
    for kind in KINDS:
        lines.append("\t%s = {" % kind)
        for breed in sorted(table[kind]):
            lines.append("\t\t%s = {" % breed)
            for anim in sorted(table[kind][breed]):
                entry = table[kind][breed][anim]
                if isinstance(entry, dict):
                    lines.append("\t\t\t%s = {" % anim)
                    for attack in sorted(entry):
                        value, count, note = entry[attack]
                        lines.append("\t\t\t\t%s = %.2f, %s" % (attack, value, comment(count, note)))
                    lines.append("\t\t\t},")
                else:
                    value, count, note = entry
                    lines.append("\t\t\t%s = %.2f, %s" % (anim, value, comment(count, note)))
            lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Rebuild DEFAULTS in Timings.lua from scratch from playtest console logs.")
    parser.add_argument("logs", nargs="+", help="console logs, host or client")
    parser.add_argument("--normal-speed", action="append", default=[], help="a log without speeds whose readings were all taken at normal speed (repeatable)")
    parser.add_argument("--no-host-cues", action="append", default=[], help="a host log whose recoil cue readings are left out (repeatable)")
    parser.add_argument("--min-readings", type=int, default=2, help="readings a stagger length needs (default: %(default)s)")
    parser.add_argument("--min-recoil-readings", type=int, default=1, help="readings a recoil timing needs, per attack (default: %(default)s)")
    parser.add_argument("--timings", default=TIMINGS, help="path to Timings.lua (default: %(default)s)")
    parser.add_argument("--shared", default=SHARED, help="path to Shared.lua (default: %(default)s)")
    parser.add_argument("--dry-run", action="store_true", help="print the new table instead of writing it")
    args = parser.parse_args()

    breeds = breed_set(args.shared, "REACTION_BREEDS")
    normal = {path.replace("\\", "/") for path in args.normal_speed}
    no_cues = {path.replace("\\", "/") for path in args.no_host_cues}
    readings = collections.defaultdict(list)
    counts = collections.Counter()
    for path in args.logs:
        key = path.replace("\\", "/")
        side, found = read_log(path, breeds, key in normal, key in no_cues, readings, counts)
        print("%s (%s%s%s): %d readings" % (path, side, ", normal speed" if key in normal else "", ", no host cues" if key in no_cues else "", found))
    for name, count in sorted(counts.items()):
        print("  %s: %d" % (name, count))

    report = []
    table = build(readings, args.min_readings, args.min_recoil_readings, report)
    for line in report:
        print(line)
    for kind in KINDS:
        values = sum(len(entry) if isinstance(entry, dict) else 1 for by_anim in table[kind].values() for entry in by_anim.values())
        print("%s: %d values for %d breeds" % (kind, values, len(table[kind])))

    with io.open(args.timings, encoding="utf-8", newline="") as f:
        source = f.read()
    newline = "\r\n" if "\r\n" in source else "\n"
    source = source.replace("\r\n", "\n")
    start = source.index("local DEFAULTS = {")
    end = source.index("\n}\n", start) + 3
    block = write_block(table)
    if args.dry_run:
        print()
        print(block)
        return
    with io.open(args.timings, "w", encoding="utf-8", newline="") as f:
        f.write((source[:start] + block + source[end:]).replace("\n", newline))
    print("Wrote %s. Check that the comment above DEFAULTS still names the logs the numbers come from." % args.timings)


if __name__ == "__main__":
    main()
