"""How fast the host has to play a client's staggers to end them on time, and what each speed-up limit cuts (D32).

Run it from the mod folder with one session's host log and one client's log:

    py Docs/stagger_speedups.py HOST.log CLIENT.log [--from NAME] [--extra SECONDS]

It reads the host's "[PingComp] host stagger=..." lines (the timing used, the speed, the lead it had to make up and
the stagger's length) and the client's "[PingComp] client stagger=... ended: ..." lines (how far its copy of the
enemy was from the host's when it handed the enemy back). Stagger ids are only unique per client, so with several
clients pass --from with this client's in-game name, as the host's log writes it.

For each limit it prints how many staggers would be cut (ended before their animation ends) at the logged lead, and
at the logged lead plus --extra seconds (default 0.1: a 250 ms session seen at 350 ms), and how much of each cut
animation would go unplayed. Then the speed the staggers need, and the hand-back distance on the client for the
staggers the host ended early and for the others.
"""
import argparse
import collections
import io
import re
import statistics

LIMITS = (1.5, 2.0, 2.5, 3.0, 4.0)
MIN_HOST_STAGGER = 0.1  # MIN_HOST_STAGGER in HostReactions.lua

HOST = re.compile(r"\[PingComp\] host stagger=(\d+) from=(.*?) enemy=([a-z_]+) anim=([a-z_0-9]+) applied=true .*?"
                  r"timing=([a-z ,]+) speed=([0-9.]+) lead=([0-9.]+)s length=([0-9.]+)s")
TIMING = re.compile(r"\[PingComp\] host stagger=\d+ from=(.*?) enemy=.*? timing=([a-z ,]+) speed=")
CLIENT = re.compile(r"\[PingComp\] client stagger=(\d+) enemy=([a-z_]+) ended: ([^,]+),.* from_host=([0-9.]+)m, lasted=([0-9.]+)s")


def share(values, part):
    return values[min(len(values) - 1, int(len(values) * part))]


def table(host, extra):
    print()
    print("Lead %s:" % ("as logged" if extra == 0 else "as logged + %.2f s" % extra))
    for limit in LIMITS:
        cut = []
        for h in host.values():
            wanted = max(h["length"] - (h["lead"] + extra), MIN_HOST_STAGGER)
            if h["length"] / wanted > limit:
                cut.append(h["length"] / limit - wanted)  # seconds of the sped-up animation left unplayed
        if cut:
            print("  limit %.1fx: %4d of %d cut (%3.0f%%), unplayed per cut stagger: median %.2f s, max %.2f s"
                  % (limit, len(cut), len(host), 100.0 * len(cut) / len(host), statistics.median(cut), max(cut)))
        else:
            print("  limit %.1fx: none cut" % limit)
    need = sorted(h["length"] / max(h["length"] - (h["lead"] + extra), MIN_HOST_STAGGER) for h in host.values())
    print("  speed needed: median %.2fx, 90%% %.2fx, 99%% %.2fx, max %.2fx"
          % (statistics.median(need), share(need, 0.9), share(need, 0.99), need[-1]))


def main():
    parser = argparse.ArgumentParser(description="Stagger speed-ups needed and cut, from one session's logs.")
    parser.add_argument("host_log")
    parser.add_argument("client_log")
    parser.add_argument("--from", dest="name", help="only the host's lines for this client (in-game name)")
    parser.add_argument("--extra", type=float, default=0.1, help="extra lead for the second table (default: %(default)s s)")
    args = parser.parse_args()

    host = {}
    timings = collections.Counter()
    names = set()
    with io.open(args.host_log, encoding="utf-8", errors="replace") as log:
        for line in log:
            match = TIMING.search(line)
            if match and (args.name is None or match.group(1) == args.name):
                names.add(match.group(1))
                timings[match.group(2)] += 1
            match = HOST.search(line)
            if match and (args.name is None or match.group(2) == args.name):
                host[int(match.group(1))] = dict(breed=match.group(3), anim=match.group(4), timing=match.group(5),
                                                 speed=float(match.group(6)), lead=float(match.group(7)),
                                                 length=float(match.group(8)))
    client = {}
    with io.open(args.client_log, encoding="utf-8", errors="replace") as log:
        for line in log:
            match = CLIENT.search(line)
            if match:
                client[int(match.group(1))] = dict(reason=match.group(3), from_host=float(match.group(4)))

    if len(names) > 1:
        print("The host log has staggers from %s; pass --from to pick this client's." % ", ".join(sorted(names)))
    if not host:
        print("No host stagger lines with a known length.")
        return
    print("Client staggers on the host: %s" % ", ".join("%s %d" % item for item in sorted(timings.items())))
    print("With a known length: %d" % len(host))
    leads = sorted(h["lead"] for h in host.values())
    lengths = sorted(h["length"] for h in host.values())
    print("Lead: median %.3f s, 90%% %.3f s, max %.3f s" % (statistics.median(leads), share(leads, 0.9), leads[-1]))
    print("Length: 10%% %.2f s, median %.2f s, 90%% %.2f s" % (share(lengths, 0.1), statistics.median(lengths), share(lengths, 0.9)))

    table(host, 0.0)
    if args.extra:
        table(host, args.extra)

    # The hand-back: the client's stagger ended because the host's reaction was over or it started a new swing.
    print()
    pairs = [(h, client[i]) for i, h in host.items() if i in client and client[i]["reason"].startswith("the host")]
    for label, ended_early in (("ended early on the host", True), ("not ended early", False)):
        values = sorted(c["from_host"] for h, c in pairs if ("ended early" in h["timing"]) == ended_early)
        if values:
            print("Hand-back distance on the client, %s: %d staggers, median %.2f m, 90%% %.2f m, max %.2f m"
                  % (label, len(values), statistics.median(values), share(values, 0.9), values[-1]))


if __name__ == "__main__":
    main()
