# Sample archive — size figures (reference)

Measured 2026-10-07 on one owner export (one device, 3 full days of 1 Hz data,
aggregates only; no raw values recorded). Full days = 2026-10-03 and 10-04,
averaged. Codec v2 (quantized hr and skin temp, 2026-10-08 re-measure of the
same export; the v1 lossy-DCT figures are kept below under History). Re-measure if the codec, quanta or signal set change.

## Storage per full day and per year

| what is stored | bytes/day | MB/year | vs archive |
|---|---|---|---|
| **Sample archive, shipped default** (hr + skin temp quantized, accel per-minute pyramid only) | 42,936 | **15.7** | 1× |
| Sample archive with lossless-at-0.004 g accel (option) | 196,367 | 71.7 | 4.6× |
| Lossless (zigzag delta + deflate) of the same 5 signals | 210,572 | 76.9 | 4.9× |
| Raw samples, 8 B each, 5 signals (hr, ax, ay, az, skin temp) | 3,455,340 | 1,261 | 80.5× |
| `decoded_onehz` as actually stored in SQLite (all columns + PK index; ≈140 B/row) | ≈12,080,000 | ≈4,410 | ≈281× |

Notes:
- `decoded_onehz` holds more columns than the five archived signals, and
  `decoded_rr` (beats) is not included in any row above; the 334× compares the
  archive to what the app keeps today for the retention window, not like for like.
- The honest like-for-like coefficient is **4.9× vs lossless** of the same five
  signals; it is lossy (hr: step 2.8 bpm, |error| ≤ 1.4, rms ≈0.81; skin temp:
  step 0.12 °C, |error| ≤ 0.06, rms ≈0.034) and accel keeps only the per-minute
  count/min/mean/max envelope (per-second acceleration is not kept).
- Per signal vs lossless (pyramid included): hr 1.35×, skin temp 3.2×.
- hr + skin temp alone: 27.3 KB/day vs 56.6 KB lossless, vs 1.38 MB raw.
- The summary pyramid is ≈3.8 KB per hr signal-day (about a quarter of the hr archive) and ≈4.0 KB per skin-temp signal-day (over a third of it).
- Measured per full day (10-03 / 10-04): hr 16,242 / 16,547 B (rms 0.81, max 1.4),
  skin temp 10,801 / 11,071 B (rms 0.035, max 0.06), accel pyramid-only 15,686 / 15,524 B.

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
- 2026-10-08: codec v2 replaces the lossy DCT for hr and skin temp with plain
  quantization. Sizes grew (hr 13.8 -> 16.4 KB, temp 6.7 -> 10.9 KB per day; total
  36.2 -> 42.9 KB/day) in exchange for a tighter worst case (1.4 bpm / 0.06 C instead
  of 3 bpm / 0.15 C), per-sample error accounting and a much simpler codec. v1
  parts still decode.
- Synthetic fixtures promised 2.7–5.5× on hr; real beat-to-beat variability is broadband ⇒ 1.6×.
- Owner narrowed the lossy codec to hr + skin temp; accel defaults to pyramid-only (2026-10-07).
- Source report: edge.research/spectral-real-data-2026-10-07.md (outside the repo; written under the old name "spectral").

## Like-for-like: the same accuracy without the DCT codec (2026-10-08)

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
| DCT archive (v1, replaced by the rms-matched plain row) | 13,800 / 14,000 | 6,577 / 6,826 | 15,662 / 15,500 | **36,039 / 36,326** | **13.2** |
| Plain, max-matched | 10,863 / 10,926 | 7,259 / 7,513 | 14,553 / 14,509 | 32,675 / 32,948 | 12.0 |
| Plain, rms-matched | 15,672 / 15,983 | 10,827 / 11,465 | 14,553 / 14,509 | 41,052 / 41,957 | 15.2 |
| Plain, lossless at native quantum (+pyramid) | 25,227 / 25,923 | 39,038 / 39,503 | 14,553 / 14,509 | 78,818 / 79,935 | 29.0 |

Reading it:
- At equal accuracy the DCT codec was within about ±12 % of plain
  quantize-and-deflate: ≈12 % smaller than rms-matched plain (which has a better
  worst case), ≈10 % larger than max-matched plain (same worst case).
- Nearly all of the saving versus lossless (≈2.2×) and versus raw comes from
  (1) storing only to the needed accuracy and (2) keeping only the per-minute
  envelope for the accelerometer — neither needs the transform.
- What the transform still offers: progressive refinement (coarse coefficients
  first, for long chart views) and a smooth reconstruction. What it costs:
  codec complexity, per-block (not per-sample) error accounting, encode time.
