"""
Simulates the Swift calculateSleepPayload / buildAggregatedPayload logic
to verify the per-segment rounding against Apple Health's displayed values.
"""
from datetime import datetime

samples = [
  {"startDate":"2026-03-23T18:41:00.000Z","endDate":"2026-03-23T18:41:00.000Z","sleepStage":"awake","sourceName":"Health","value":2,"durationSeconds":0.0},
  {"startDate":"2026-03-23T18:42:00.000Z","endDate":"2026-03-23T18:42:00.000Z","sleepStage":"awake","sourceName":"Health","value":2,"durationSeconds":0.0},
  {"startDate":"2026-03-23T18:45:00.000Z","endDate":"2026-03-23T18:45:00.000Z","sleepStage":"awake","sourceName":"Health","value":2,"durationSeconds":0.0},
  {"startDate":"2026-03-23T18:48:00.000Z","endDate":"2026-03-23T18:48:00.000Z","sleepStage":"awake","sourceName":"Health","value":2,"durationSeconds":0.0},
  {"startDate":"2026-03-23T18:52:00.000Z","endDate":"2026-03-23T18:52:00.000Z","sleepStage":"awake","sourceName":"Health","value":2,"durationSeconds":0.0},
  {"startDate":"2026-03-23T18:54:00.000Z","endDate":"2026-03-23T18:54:00.000Z","sleepStage":"awake","sourceName":"Health","value":2,"durationSeconds":0.0},
  {"uuid":"670C303C","startDate":"2026-03-23T19:39:53.109Z","endDate":"2026-03-23T19:50:23.739Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":630.6300494670868},
  {"uuid":"96F2D6C3","startDate":"2026-03-23T19:50:23.739Z","endDate":"2026-03-23T20:27:25.982Z","sleepStage":"asleepDeep","sourceName":"Watch","value":4,"durationSeconds":2222.242725968361},
  {"uuid":"7755E1F8","startDate":"2026-03-23T20:27:25.982Z","endDate":"2026-03-23T20:31:26.223Z","sleepStage":"awake","sourceName":"Watch","value":2,"durationSeconds":240.2409280538559},
  {"uuid":"BF79D118","startDate":"2026-03-23T20:31:26.223Z","endDate":"2026-03-23T20:59:27.966Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":1681.7432119846344},
  {"uuid":"784E68BC","startDate":"2026-03-23T20:59:27.966Z","endDate":"2026-03-23T21:00:28.029Z","sleepStage":"asleepREM","sourceName":"Watch","value":5,"durationSeconds":60.06252205371857},
  {"uuid":"F1A339AC","startDate":"2026-03-23T21:00:28.029Z","endDate":"2026-03-23T21:00:58.060Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":30.031187057495117},
  {"uuid":"36CC4795","startDate":"2026-03-23T21:00:58.060Z","endDate":"2026-03-23T21:28:29.764Z","sleepStage":"asleepREM","sourceName":"Watch","value":5,"durationSeconds":1651.7042340040207},
  {"uuid":"A473E99B","startDate":"2026-03-23T21:28:29.764Z","endDate":"2026-03-23T22:45:04.363Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":4594.599081039429},
  {"uuid":"0DEE2754","startDate":"2026-03-23T22:45:04.363Z","endDate":"2026-03-23T23:09:35.766Z","sleepStage":"asleepREM","sourceName":"Watch","value":5,"durationSeconds":1471.4025000333786},
  {"uuid":"701E291F","startDate":"2026-03-23T23:09:35.766Z","endDate":"2026-03-24T00:01:38.826Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":3123.060021042824},
  {"uuid":"46F773C0","startDate":"2026-03-24T00:01:38.826Z","endDate":"2026-03-24T00:34:40.679Z","sleepStage":"asleepREM","sourceName":"Watch","value":5,"durationSeconds":1981.8533600568771},
  {"uuid":"84A60FA1","startDate":"2026-03-24T00:34:40.679Z","endDate":"2026-03-24T01:10:42.651Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":2161.972484946251},
  {"uuid":"3DF926D6","startDate":"2026-03-24T01:10:42.651Z","endDate":"2026-03-24T01:15:12.896Z","sleepStage":"awake","sourceName":"Watch","value":2,"durationSeconds":270.2445670366287},
  {"uuid":"42EBB05D","startDate":"2026-03-24T01:15:12.896Z","endDate":"2026-03-24T01:38:44.273Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":1411.3770070075989},
  {"uuid":"DB8BBC6C","startDate":"2026-03-24T01:38:44.273Z","endDate":"2026-03-24T02:15:46.526Z","sleepStage":"asleepREM","sourceName":"Watch","value":5,"durationSeconds":2222.2534450292587},
  {"uuid":"D6F5D643","startDate":"2026-03-24T02:15:46.526Z","endDate":"2026-03-24T02:17:46.649Z","sleepStage":"asleepCore","sourceName":"Watch","value":3,"durationSeconds":120.12215602397919},
]

def p(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00'))

def ep(d):
    return int(d.timestamp())  # mirrors Swift `Int(date.timeIntervalSince1970)` truncation

# ── Step 1: calculateSleepPayload — sort + group (gap ≤ 2h) + filter (span ≥ 3h)
ss = sorted(samples, key=lambda s: p(s['startDate']))
groups, cur = [], [ss[0]]
for s in ss[1:]:
    gap = (p(s['startDate']) - p(cur[-1]['endDate'])).total_seconds()
    if gap <= 7200:
        cur.append(s)
    else:
        groups.append(cur)
        cur = [s]
groups.append(cur)

print("── Step 1: Session groups ──────────────────────────────────────────────")
valid = []
for i, g in enumerate(groups):
    max_end = max(p(s['endDate']) for s in g)
    span = (max_end - p(g[0]['startDate'])).total_seconds()
    keep = span >= 3 * 3600
    status = "KEEP ✓" if keep else "DROP (< 3h) ✗"
    print(f"  Group {i+1}: {len(g):2d} samples  span={span/3600:.2f}h  {status}")
    if keep:
        valid += g
print(f"\n  {len(valid)} samples forwarded to buildAggregatedPayload\n")

# ── Step 2: buildAggregatedPayload — group by source, integer-epoch rounding
watch = [s for s in valid if s['sourceName'] == 'Watch']

print("── Step 2: Integer-epoch rounding per Watch segment ────────────────────")
print(f"  {'Stage':<14} {'UUID':8}  {'rawSec':>8}  {'intSec':>6}  {'(n+30)//60':>10}  min")
print("  " + "-"*63)

core = deep = rem = awake = 0
for s in watch:
    n = ep(p(s['endDate'])) - ep(p(s['startDate']))
    rm = (n + 30) // 60
    flag = "  *** TIE: 30s = exactly 0.5 min ***" if n == 30 else ""
    print(f"  {s['sleepStage']:<14} {s.get('uuid','?')[:8]}  "
          f"{s['durationSeconds']:>8.3f}  {n:>6}  {rm:>10}  {rm:>3}{flag}")
    v = s['value']
    if   v == 3: core  += rm
    elif v == 4: deep  += rm
    elif v == 5: rem   += rm
    elif v == 2: awake += rm

total = core + deep + rem

print()
print("── Step 3: Final payload (current code with +30) ───────────────────────")
print(f"  SLEEP_LIGHT (Core) = {core:3d} min = {core*60:5d} s")
print(f"  SLEEP_DEEP         = {deep:3d} min = {deep*60:5d} s")
print(f"  SLEEP_REM          = {rem:3d} min = {rem*60:5d} s")
print(f"  SLEEP_AWAKE        = {awake:3d} min")
print(f"  TOTAL_SLEEP        = {total:3d} min = {total//60}h {total%60}m")
print()
print(f"  Apple Health shows : 391 min = 6h 31m")
print(f"  Current code gives : {total} min = {total//60}h {total%60}m")
print(f"  Difference         : {total-391:+d} min")

# ── Root cause ────────────────────────────────────────────────────────────────
print()
print("── Root cause ──────────────────────────────────────────────────────────")
s = next(x for x in watch if x.get('uuid') == 'F1A339AC')
n = ep(p(s['endDate'])) - ep(p(s['startDate']))
print(f"  Segment F1A339AC (asleepCore)")
print(f"    startDate  = {s['startDate']}")
print(f"    endDate    = {s['endDate']}")
print(f"    intSec     = {n}s  (exactly 30 = 0.500 min — a tie)")
print(f"    (30+30)//60 = 1  ← our +30 rule rounds ties UP   → 1 min")
print(f"    Apple      = 0  ← Apple rounds ties DOWN (floor)  → 0 min")

# ── Fix: +29 instead of +30 rounds ties down ──────────────────────────────────
print()
print("── Fix: change (n + 30) // 60  to  (n + 29) // 60 ─────────────────────")
print("   (+29 = ties-round-down; has no effect on any non-tie segment)")
print()
print(f"  {'UUID':8}  {'intSec':>6}  {'+30 → min':>10}  {'+29 → min':>10}  changed?")
core2 = deep2 = rem2 = 0
for s in watch:
    n = ep(p(s['endDate'])) - ep(p(s['startDate']))
    r30 = (n + 30) // 60
    r29 = (n + 29) // 60
    changed = "  ← CHANGED" if r30 != r29 else ""
    print(f"  {s.get('uuid','?')[:8]}  {n:>6}  {r30:>10}  {r29:>10}{changed}")
    v = s['value']
    if   v == 3: core2 += r29
    elif v == 4: deep2 += r29
    elif v == 5: rem2  += r29

total2 = core2 + deep2 + rem2
print()
print(f"  With +29:  Core={core2}  Deep={deep2}  REM={rem2}  TOTAL={total2} = {total2//60}h {total2%60}m")
verdict = "✓ MATCHES Apple Health" if total2 == 391 else f"✗ still off by {total2-391} min"
print(f"  Apple Health: 391 min  →  {verdict}")
