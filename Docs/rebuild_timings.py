"""Rebuild DEFAULTS in Timings.lua from scratch from the timing readings in playtest console logs (build 3.2, D43).

Run it from the mod folder, with every log that has readings (host and client logs alike; each log's side is worked
out from its lines):

    py Docs/rebuild_timings.py [options] LOG [LOG ...]

Readings come from the debug log's "[PingComp] timing length|cue|stunned breed=... anim=... seconds=..." lines, and,
for recoils, from the host's "host swing=... recoil=... ended: ..." lines (build 3.1 on): their cue= time when it isn't
"(learned)", their stunned= time (3.2 on), and in 3.1 the time a recoil lasted when the behaviour tree ended it before
its cue (only anim_cb_stunned_finished does that). Lines the mod marked " ignored:" are left out, and so are a host's
readings of staggers it played faster (the "speed asked" line just before them). Every enemy is kept, covered or not
(D47: from build 3.2 every machine times every enemy, for later steps). The values already in DEFAULTS are not
counted: the rebuild starts clean.

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
animation isn't shipped until the key it depends on is known, and is listed; it is written as false, so no machine
learns a blend of the two either (Timings.lua). Recoils are never played faster, so all
their readings count as taken at normal speed. A stagger length needs --min-readings readings (default 2) in its
group; a recoil timing needs --min-recoil-readings (default 1), since one recoil reading is exact to a frame or two.

A recoil's timings (cue, stunned) depend on the attack it interrupted for some enemies. For each recoil animation:
if two or more attacks have values and they differ by more than 0.05 s, the values are shipped per attack; if they
agree, or the readings that don't name the attack (logs before 3.1) agree with the one attack that has a value, one
value covers every attack. With only one attack known and nothing else to go by, it is shipped for that attack alone.

Shared stagger lengths (D47): enemies that play the same stagger animations fill each other's gaps. Two enemies share
when they have at least SHARE_MIN stagger lengths in common and every one of them agrees within SHARE_TOLERANCE; then
each gets the other's lengths for the animations it has no value for, marked "from <enemy>". Only an enemy's own
values are compared and passed on. Recoil timings stay per enemy: marauders' and shielded marauders' agree for every
attack but their running attack.

The tally (D47): for each enemy in the decompiled breed files (--source), how many of its stagger animations have a
length and how many of its recoil animations have a cue or stunned cue for some attack, after sharing. Covered enemies
get a row each, the others one per faction. --handout writes it into the handout between the TALLY_START and TALLY_END
lines (rebuild the PDF afterwards); otherwise it is printed.

--dry-run prints the new table instead of writing it. Then check that the comment above DEFAULTS still names the logs
the numbers come from.
"""
import argparse
import collections
import glob
import io
import itertools
import os
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
SPLIT_NOTE = "split at normal speed"  # such an animation is written as false: no value, and none learned (Timings.lua)
SHARE_MIN = 10  # stagger lengths two enemies must have in common, all agreeing, to share the rest
SHARE_TOLERANCE = 0.035  # how far apart two of those may be and still agree (0.03 s, plus the rounding to 0.01 s)
SOURCE = "../../reference/Vermintide-2-Source-Code/scripts/settings/breeds"
STAGGER_TABLES = ("stagger_anims", "standard_stagger_anims", "shield_block_anims", "shield_stagger_anims", "shield_break_anims")
TALLY_START = "<!-- tally start: written by Docs/rebuild_timings.py --handout -->"
TALLY_END = "<!-- tally end -->"
FACTIONS = (("skaven_", "Skaven"), ("chaos_", "Chaos"), ("beastmen_", "Beastmen"))
NAMES = {
    "skaven_slave": "Slave rat",
    "skaven_clan_rat": "Clan rat",
    "skaven_clan_rat_with_shield": "Shielded clan rat",
    "skaven_plague_monk": "Plague monk",
    "skaven_storm_vermin_with_shield": "Shielded stormvermin",
    "chaos_marauder": "Marauder",
    "chaos_marauder_with_shield": "Shielded marauder",
    "chaos_fanatic": "Fanatic",
    "chaos_berzerker": "Savage",
    "beastmen_gor": "Gor",
    "beastmen_ungor": "Ungor",
}

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


def read_log(path, normal_speed, no_host_cues, readings, counts):
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
                if attack == "nil":
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
            return None, len(trusted), SPLIT_NOTE + ": " + ", ".join("%d around %.2f" % (len(g), statistics.median(g)) for g in big)
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
                if note.startswith(SPLIT_NOTE):
                    table[kind].setdefault(breed, {})[anim] = (None, count, note)
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
            if note.startswith(SPLIT_NOTE):
                table[kind].setdefault(breed, {})[anim] = (None, count, note)
            continue
        table[kind].setdefault(breed, {})[anim] = (value, count, note)
        report.append("every attack %s = %.2f (%d readings%s%s)" % (name, value, count, ", attacks: " + ", ".join(sorted(named)) if named else ", attacks not named in these logs", ", " + note if note else ""))
    return table


def share(table, report):
    """Fills each enemy's missing stagger lengths from the enemies whose lengths all agree with its own (D47)."""
    lengths = table["length"]
    own = {breed: {anim: entry for anim, entry in by_anim.items() if entry[0] is not None} for breed, by_anim in lengths.items()}
    mates = collections.defaultdict(list)
    for a, b in itertools.combinations(sorted(own), 2):
        common = set(own[a]) & set(own[b])
        if len(common) < SHARE_MIN:
            continue
        differ = sorted(anim for anim in common if abs(own[a][anim][0] - own[b][anim][0]) > SHARE_TOLERANCE)
        report.append("compared     length %s and %s: %d agree, %d differ%s" % (a, b, len(common) - len(differ), len(differ), " (%s)" % ", ".join("%s %.2f/%.2f" % (anim, own[a][anim][0], own[b][anim][0]) for anim in differ[:4]) if differ else ""))
        if not differ:
            mates[a].append((len(common), b))
            mates[b].append((len(common), a))
    for breed in sorted(mates):
        for _, mate in sorted(mates[breed], reverse=True):
            added = 0
            for anim, (value, count, note) in sorted(own[mate].items()):
                if anim not in lengths[breed]:
                    lengths[breed][anim] = (value, count, "from " + mate)
                    added += 1
            if added:
                report.append("shared       length %s: %d from %s" % (breed, added, mate))


def strings(text):
    return re.findall(r'"([a-z_0-9]+)"', text)


def block_at(text, start):
    """The text of the {...} that starts at text[start] == '{'."""
    depth = 0
    in_string = False
    i = start
    while i < len(text):
        c = text[i]
        if in_string:
            if c == "\\":
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    return text[start:]


def breed_animations(source):
    """breed -> (stagger animations, recoil animations) from the decompiled breed files. A file's tables count for
    every breed it defines (a stormvermin commander shares the stormvermin's). Rough, but it is only a tally."""
    found = {}
    for path in sorted(glob.glob(os.path.join(source, "breed_*.lua"))):
        with io.open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        staggers, recoils = set(), set()
        for key in STAGGER_TABLES:
            for match in re.finditer(r"\b%s = \{" % key, text):
                staggers.update(strings(block_at(text, match.end() - 1)))
        for match in re.finditer(r"\bblocked_anims = \{", text):
            recoils.update(strings(block_at(text, match.end() - 1)))
        if not staggers and not recoils:
            continue
        for breed in set(re.findall(r"^Breeds\.([a-z_0-9]+) = ", text, re.M)):
            found[breed] = (staggers, recoils)
    return found


def tally(table, source, covered):
    """The Markdown tally of timed animations, or None if the breed files aren't there."""
    animations = breed_animations(source)
    if not animations:
        return None
    rows = []
    groups = collections.OrderedDict((name, [0, 0, 0, 0, 0]) for _, name in FACTIONS)

    def counts(breed):
        staggers, recoils = animations[breed]
        lengths = {anim for anim, entry in table["length"].get(breed, {}).items() if entry[0] is not None}
        timed_recoils = {anim for kind in BY_ATTACK for anim, entry in table[kind].get(breed, {}).items() if isinstance(entry, dict) or entry[0] is not None}
        return len(staggers & lengths), len(staggers), len(recoils & timed_recoils), len(recoils)

    for breed in sorted(covered, key=lambda b: NAMES.get(b, b)):
        if breed in animations:
            a, b, c, d = counts(breed)
            rows.append("| %s | %d of %d | %d of %d |" % (NAMES.get(breed, breed), a, b, c, d))
    for breed in sorted(animations):
        if breed in covered:
            continue
        for prefix, name in FACTIONS:
            if breed.startswith(prefix):
                totals = groups[name]
                for i, n in enumerate(counts(breed)):
                    totals[i] += n
                totals[4] += 1
    for name, (a, b, c, d, n) in groups.items():
        if n:
            rows.append("| Other %s (%d types) | %d of %d | %d of %d |" % (name, n, a, b, c, d))
    return "\n".join(["| Enemy | Staggers timed | Recoils timed |", "|---|---|---|"] + rows)


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
                    if value is None:
                        lines.append("\t\t\t%s = false, -- %s" % (anim, note.replace(SPLIT_NOTE, "split")))
                    else:
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
    parser.add_argument("--source", default=SOURCE, help="the decompiled breed files, for the tally (default: %(default)s)")
    parser.add_argument("--handout", help="write the tally into this handout, between its tally lines")
    parser.add_argument("--dry-run", action="store_true", help="print the new table instead of writing it")
    args = parser.parse_args()

    covered = breed_set(args.shared, "REACTION_BREEDS")
    normal = {path.replace("\\", "/") for path in args.normal_speed}
    no_cues = {path.replace("\\", "/") for path in args.no_host_cues}
    readings = collections.defaultdict(list)
    counts = collections.Counter()
    for path in args.logs:
        key = path.replace("\\", "/")
        side, found = read_log(path, key in normal, key in no_cues, readings, counts)
        print("%s (%s%s%s): %d readings" % (path, side, ", normal speed" if key in normal else "", ", no host cues" if key in no_cues else "", found))
    for name, count in sorted(counts.items()):
        print("  %s: %d" % (name, count))

    report = []
    table = build(readings, args.min_readings, args.min_recoil_readings, report)
    share(table, report)
    for line in report:
        print(line)
    for kind in KINDS:
        values = sum(len(entry) if isinstance(entry, dict) else int(entry[0] is not None) for by_anim in table[kind].values() for entry in by_anim.values())
        print("%s: %d values for %d breeds" % (kind, values, len(table[kind])))

    tally_text = tally(table, args.source, covered)
    if tally_text is None:
        print("No tally: no breed files in %s" % args.source)
    elif args.handout and not args.dry_run:
        with io.open(args.handout, encoding="utf-8", newline="") as f:
            handout = f.read()
        handout_newline = "\r\n" if "\r\n" in handout else "\n"
        handout = handout.replace("\r\n", "\n")
        if TALLY_START not in handout or TALLY_END not in handout:
            print("No tally lines in %s: add %s and %s around the table first." % (args.handout, TALLY_START, TALLY_END))
        else:
            before, rest = handout.split(TALLY_START, 1)
            _, after = rest.split(TALLY_END, 1)
            handout = before + TALLY_START + "\n" + tally_text + "\n" + TALLY_END + after
            with io.open(args.handout, "w", encoding="utf-8", newline="") as f:
                f.write(handout.replace("\n", handout_newline))
            print("Wrote the tally into %s. Rebuild its PDF." % args.handout)
    else:
        print()
        print(tally_text)

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
