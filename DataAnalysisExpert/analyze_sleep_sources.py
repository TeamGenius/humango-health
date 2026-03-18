#!/usr/bin/env python3
"""
Sleep Data Source Analysis
- Identify distinct sources
- What happens when 2 sources write the same session (overlap detection)
- Evaluate the proposed payload keys vs actual data
"""

import json
from collections import defaultdict
from datetime import datetime, timezone, timedelta

DATA_FILE = "/Users/vinayvudatala/Downloads/sleep_data_2026-02-01_to_2026-03-17.json"

# ─────────────────────────────────────────────────────────────────────────────
# Load
# ─────────────────────────────────────────────────────────────────────────────
with open(DATA_FILE) as f:
    samples = json.load(f)

print(f"Total samples: {len(samples)}\n")

def parse_dt(s):
    """Parse ISO-8601 UTC string → aware datetime."""
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)

# ─────────────────────────────────────────────────────────────────────────────
# 1. DISTINCT SOURCES
# ─────────────────────────────────────────────────────────────────────────────
source_counts  = defaultdict(int)   # sourceName → count
stage_per_src  = defaultdict(lambda: defaultdict(float))   # src → stage → seconds

for s in samples:
    name  = s.get("sourceName", "UNKNOWN")
    stage = s.get("sleepStage", "UNKNOWN")
    dur   = s.get("durationSeconds", 0)
    source_counts[name] += 1
    stage_per_src[name][stage] += dur

print("=" * 60)
print("1. DISTINCT SOURCES")
print("=" * 60)
for src, cnt in sorted(source_counts.items(), key=lambda x: -x[1]):
    print(f"  {src!r:45s}  {cnt:4d} samples")

print()
print("  Stages per source (total seconds):")
for src in sorted(source_counts):
    print(f"\n  [{src}]")
    for stage, secs in sorted(stage_per_src[src].items()):
        print(f"    {stage:20s}: {secs:>10.0f}s  ({secs/60:.1f} min)")

# ─────────────────────────────────────────────────────────────────────────────
# 2. SESSIONS PER SOURCE  (group by "day" = night starting 18:00 IST prior day)
#    IST = UTC+5:30  →  18:00 IST = 12:30 UTC
# ─────────────────────────────────────────────────────────────────────────────
IST = timezone(timedelta(hours=5, minutes=30))

def night_key(dt_utc):
    """Return YYYY-MM-DD of the morning the sleep belongs to (IST)."""
    dt_ist = dt_utc.astimezone(IST)
    # If before 18:00 IST we're still on "last night"
    if dt_ist.hour < 18:
        return dt_ist.date().isoformat()
    else:
        return (dt_ist.date() + timedelta(days=1)).isoformat()

sessions_per_src_day = defaultdict(lambda: defaultdict(list))
# sessions_per_src_day[night_key][sourceName] = [list of samples]

for s in samples:
    dt = parse_dt(s["startDate"])
    nk = night_key(dt)
    src = s.get("sourceName", "UNKNOWN")
    sessions_per_src_day[nk][src].append(s)

print("\n\n" + "=" * 60)
print("2. MULTI-SOURCE NIGHTS (same night, 2+ sources)")
print("=" * 60)

multi_source_nights = {nk: srcs for nk, srcs in sessions_per_src_day.items() if len(srcs) > 1}
single_source_nights = {nk: srcs for nk, srcs in sessions_per_src_day.items() if len(srcs) == 1}

print(f"  Nights with ONLY 1 source : {len(single_source_nights)}")
print(f"  Nights with 2+ sources    : {len(multi_source_nights)}")
print()

for nk in sorted(multi_source_nights):
    srcs = multi_source_nights[nk]
    print(f"  Night {nk}:")
    for src, slist in srcs.items():
        stages = defaultdict(float)
        for s in slist:
            stages[s.get("sleepStage","?")] += s.get("durationSeconds",0)
        total_sleep = stages.get("asleepCore",0) + stages.get("asleepDeep",0) + stages.get("asleepREM",0)
        print(f"    {src!r}: {len(slist)} samples  |  TOTAL_SLEEP={total_sleep/60:.0f} min"
              f"  (Core={stages.get('asleepCore',0)/60:.0f}"
              f"  Deep={stages.get('asleepDeep',0)/60:.0f}"
              f"  REM={stages.get('asleepREM',0)/60:.0f})")

# ─────────────────────────────────────────────────────────────────────────────
# 3. OVERLAP ANALYSIS — do two sources write overlapping time segments?
# ─────────────────────────────────────────────────────────────────────────────
print("\n\n" + "=" * 60)
print("3. TEMPORAL OVERLAP ANALYSIS")
print("=" * 60)
print("  When 2 sources cover the same night, do their segments overlap?")
print()

def segments_overlap(a_start, a_end, b_start, b_end):
    return a_start < b_end and b_start < a_end

overlap_nights = []

for nk in sorted(multi_source_nights):
    srcs = multi_source_nights[nk]
    src_names = list(srcs.keys())

    # Build interval list per source
    intervals = {}
    for src in src_names:
        intervals[src] = [(parse_dt(s["startDate"]), parse_dt(s["endDate"])) for s in srcs[src]]

    # Check every pair
    has_overlap = False
    for i in range(len(src_names)):
        for j in range(i+1, len(src_names)):
            sa, sb = src_names[i], src_names[j]
            for (a_s, a_e) in intervals[sa]:
                for (b_s, b_e) in intervals[sb]:
                    if segments_overlap(a_s, a_e, b_s, b_e):
                        has_overlap = True
                        overlap_secs = (min(a_e, b_e) - max(a_s, b_s)).total_seconds()
                        print(f"  Night {nk}: OVERLAP between [{sa}] & [{sb}]")
                        print(f"    Overlap: {max(a_s,b_s).isoformat()} → {min(a_e,b_e).isoformat()} ({overlap_secs/60:.1f} min)")

    if not has_overlap:
        print(f"  Night {nk}: no temporal overlap between {src_names}")

# ─────────────────────────────────────────────────────────────────────────────
# 4. PAYLOAD SIMULATION — what would we send for each night?
#    Pick source with highest TOTAL_SLEEP (Core+Deep+REM)
# ─────────────────────────────────────────────────────────────────────────────
print("\n\n" + "=" * 60)
print("4. SIMULATED PAYLOAD PER NIGHT")
print("=" * 60)
print("  (Source selected = highest TOTAL_SLEEP)")
print()

VALUE_MAP = {
    "inBed": "SLEEP_IN_BED",
    "asleepUnspecified": "SLEEP_UNSPECIFIED",
    "awake": "SLEEP_AWAKE",
    "asleepCore": "SLEEP_LIGHT",
    "asleepDeep": "SLEEP_DEEP",
    "asleepREM": "SLEEP_REM",
}

def build_payload_for_source(night_key, src_name, slist):
    totals = defaultdict(float)
    min_start = None
    max_end = None
    for s in slist:
        stage = s.get("sleepStage", "")
        key   = VALUE_MAP.get(stage)
        if key:
            totals[key] += s.get("durationSeconds", 0)
        sd = parse_dt(s["startDate"])
        ed = parse_dt(s["endDate"])
        if min_start is None or sd < min_start:
            min_start = sd
        if max_end is None or ed > max_end:
            max_end = ed

    total_sleep = (totals.get("SLEEP_LIGHT",0)
                 + totals.get("SLEEP_DEEP",0)
                 + totals.get("SLEEP_REM",0))
    return {
        "SOURCE": src_name,
        "TOTAL_SLEEP": int(total_sleep),
        "SLEEP_IN_BED": int(totals.get("SLEEP_IN_BED",0)),
        "SLEEP_LIGHT": int(totals.get("SLEEP_LIGHT",0)),
        "SLEEP_DEEP": int(totals.get("SLEEP_DEEP",0)),
        "SLEEP_REM": int(totals.get("SLEEP_REM",0)),
        "SLEEP_UNSPECIFIED": int(totals.get("SLEEP_UNSPECIFIED",0)),
        "SLEEP_AWAKE": int(totals.get("SLEEP_AWAKE",0)),
        "START_DATE": min_start.isoformat() if min_start else None,
        "END_DATE":   max_end.isoformat() if max_end else None,
    }

all_payloads = {}
for nk in sorted(sessions_per_src_day):
    srcs = sessions_per_src_day[nk]
    best_src  = None
    best_payload = None
    candidates = {}
    for src, slist in srcs.items():
        p = build_payload_for_source(nk, src, slist)
        candidates[src] = p
    # pick winner
    best_src = max(candidates, key=lambda s: candidates[s]["TOTAL_SLEEP"])
    best_payload = candidates[best_src]
    all_payloads[nk] = {"winner": best_payload, "all": candidates}

for nk, info in sorted(all_payloads.items()):
    w = info["winner"]
    contested = len(info["all"]) > 1
    marker = "  [MULTI-SOURCE] " if contested else "  "
    print(f"{marker}Night {nk}: winner={w['SOURCE']!r}")
    print(f"    TOTAL={w['TOTAL_SLEEP']//60}min  "
          f"Light={w['SLEEP_LIGHT']//60}m  "
          f"Deep={w['SLEEP_DEEP']//60}m  "
          f"REM={w['SLEEP_REM']//60}m  "
          f"Awake={w['SLEEP_AWAKE']//60}m  "
          f"InBed={w['SLEEP_IN_BED']//60}m  "
          f"Unspec={w['SLEEP_UNSPECIFIED']//60}m")
    if contested:
        losers = {s: p for s, p in info["all"].items() if s != w["SOURCE"]}
        for src, p in losers.items():
            print(f"    DROPPED [{src}]: TOTAL={p['TOTAL_SLEEP']//60}m")

# ─────────────────────────────────────────────────────────────────────────────
# 5. PAYLOAD KEY AUDIT — extra fields we can derive vs missing fields
# ─────────────────────────────────────────────────────────────────────────────
print("\n\n" + "=" * 60)
print("5. PAYLOAD KEY AUDIT")
print("=" * 60)

# Check metadata keys
all_meta_keys = set()
for s in samples:
    if s.get("metadata"):
        all_meta_keys.update(s["metadata"].keys())
print(f"\n  Metadata keys found in samples: {sorted(all_meta_keys)}")

# Check actual sourceBundle values
bundles = set(s.get("sourceBundle","") for s in samples)
print(f"\n  Unique sourceBundle values: {sorted(bundles)}")

# Timezone distribution from metadata
tz_dist = defaultdict(int)
for s in samples:
    tz = (s.get("metadata") or {}).get("HKTimeZone","MISSING")
    tz_dist[tz] += 1
print(f"\n  HKTimeZone distribution: {dict(sorted(tz_dist.items()))}")

# SLEEP_EFFICIENCY = TOTAL_SLEEP / SLEEP_IN_BED
print("\n  Derived field opportunities:")
print("    SLEEP_EFFICIENCY  = TOTAL_SLEEP / SLEEP_IN_BED  (0–1 ratio)")
print("    BED_TIME          = START_DATE of earliest inBed segment")
print("    WAKE_TIME         = END_DATE of latest inBed segment")
print("    SOURCE_BUNDLE     = sourceBundle (e.g. com.apple.health.xxx)")
print("    TIMEZONE          = HKTimeZone from metadata")
print("    SAMPLE_COUNT      = number of HealthKit segments used")

print("\n  Keys in proposed payload that may need revision:")
print("    END_DATE: currently max(endDate) — but old app fixed it to '6PM today'")
print("    → should it be the last actual segment's endDate or the query end?")
print("    START_DATE: currently min(startDate) — same concern.")
print("    → Proposal: keep actual segment bounds, add fixed QUERY_START/QUERY_END if needed")
