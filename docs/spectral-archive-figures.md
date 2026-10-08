# Spectral archive — size figures (reference)

Measured 2026-10-07 on one owner export (one device, 3 full days of 1 Hz data,
aggregates only; no raw values recorded). Full days = 2026-10-03 and 10-04,
averaged. Codec v1. Re-measure if the codec, quanta or signal set change.

## Storage per full day and per year

| what is stored | bytes/day | MB/year | vs archive |
|---|---|---|---|
| **Spectral archive, shipped default** (hr + skin temp lossy DCT, accel per-minute pyramid only) | 36,183 | **13.2** | 1× |
| Spectral archive with lossless-at-0.004 g accel (option) | 189,614 | 69.2 | 5.2× |
| Lossless (zigzag delta + deflate) of the same 5 signals | 210,572 | 76.9 | 5.8× |
| Raw samples, 8 B each, 5 signals (hr, ax, ay, az, skin temp) | 3,455,340 | 1,261 | 95.5× |
| `decoded_onehz` as actually stored in SQLite (all columns + PK index; ≈140 B/row) | ≈12,080,000 | ≈4,410 | ≈334× |

Notes:
- `decoded_onehz` holds more columns than the five archived signals, and
  `decoded_rr` (beats) is not included in any row above; the 334× compares the
  archive to what the app keeps today for the retention window, not like for like.
- The honest like-for-like coefficient is **5.8× vs lossless** of the same five
  signals; it is lossy (hr/temp within the codec's bounds: hr rms ≈0.8 bpm, max
  ≤3 bpm; temp rms ≈0.034 °C, max ≤0.15 °C) and accel keeps only the per-minute
  count/min/mean/max envelope (per-second acceleration is not kept).
- Per signal vs lossless: skin temp 5.1–5.3×, hr 1.6×, accel lossy DCT 0.98–1.10× (no gain ⇒ not used).
- hr + skin temp alone: 20.6 KB/day vs 56.6 KB lossless (2.75×), vs 1.38 MB raw (67×).
- The summary pyramid is ≈3.8 KB per hr signal-day (about a quarter of the hr archive).

## Compute and memory

| item | figure | how known |
|---|---|---|
| Encode time per signal-day | 0.1–0.9 s, on a worker isolate | measured (dev harness) |
| Restore carve before round 5 | ≈360 ms on the UI isolate | measured by review; moved to `Isolate.run` in round 5 |
| One day, 5 signals, held as raw doubles | 3.46 MB | calculated (86,400 × 8 B × 5) |
| One day, 5 signals, 60 s pyramid (count/min/mean/max) | ≈230 KB | calculated (1,440 cells × 4 × 8 B × 5) ⇒ ≈15× less |
| One year of the 60 s pyramid, 5 signals | ≈84 MB as doubles in memory (never loaded at once; coarser 900 s / 1 h / day levels are ≈15×/60×/1,440× smaller) | calculated |

Memory figures are calculated from sizes, not profiled. A heap measurement of a
chart load (raw vs pyramid) has not been done yet.

## History
- Synthetic fixtures promised 2.7–5.5× on hr; real beat-to-beat variability is broadband ⇒ 1.6×.
- Owner narrowed the lossy codec to hr + skin temp; accel defaults to pyramid-only (2026-10-07).
- Source report: edge.research/spectral-real-data-2026-10-07.md (outside the repo).

## Like-for-like: the same accuracy without the spectral codec (2026-10-08)

Same export, same full days. "Plain" = quantize each sample to a step that gives
the codec's error, then zigzag-delta varint + deflate -9, gaps as run-lengths;
plus the same per-minute/15-min/hour/day count/min/mean/max pyramid the archive
carries (the archive's hr/temp bytes include theirs). Script:
edge.research/scripts/like_for_like.py (aggregates only).

Two ways to match accuracy:
- **max-matched**: step = 2 × the codec's max bound (hr 6 bpm ⇒ |err| ≤ 3 bpm,
  rms ≈1.8; temp 0.3 °C ⇒ |err| ≤ 0.15 °C, rms ≈0.087) — same worst case,
  worse average than the codec.
- **rms-matched**: step = codec rms × √12 (hr 2.8 bpm ⇒ rms ≈0.81, |err| ≤ 1.4;
  temp 0.12 °C ⇒ rms ≈0.035, |err| ≤ 0.06) — same average, BETTER worst case
  than the codec (codec max is 3 bpm / 0.15 °C).

| B/day (10-03 / 10-04) | hr | skin temp | accel pyramid | total | MB/yr |
|---|---|---|---|---|---|
| Spectral archive (shipped) | 13,800 / 14,000 | 6,577 / 6,826 | 15,662 / 15,500 | **36,039 / 36,326** | **13.2** |
| Plain, max-matched | 10,863 / 10,926 | 7,259 / 7,513 | 14,553 / 14,509 | 32,675 / 32,948 | 12.0 |
| Plain, rms-matched | 15,672 / 15,983 | 10,827 / 11,465 | 14,553 / 14,509 | 41,052 / 41,957 | 15.2 |
| Plain, lossless at native quantum (+pyramid) | 25,227 / 25,923 | 39,038 / 39,503 | 14,553 / 14,509 | 78,818 / 79,935 | 29.0 |

Reading it:
- At equal accuracy the spectral codec is within about ±12 % of plain
  quantize-and-deflate: ≈12 % smaller than rms-matched plain (which has a better
  worst case), ≈10 % larger than max-matched plain (same worst case).
- Nearly all of the saving versus lossless (≈2.2×) and versus raw comes from
  (1) storing only to the needed accuracy and (2) keeping only the per-minute
  envelope for the accelerometer — neither needs the spectral transform.
- What the transform still offers: progressive refinement (coarse coefficients
  first, for long chart views) and a smooth reconstruction. What it costs:
  codec complexity, per-block (not per-sample) error accounting, encode time.
