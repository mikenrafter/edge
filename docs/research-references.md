# Research references

The studies the app names on screen (`citation:` fields in
`lib/ui2/screens/metric_detail.dart`, drawn by `researchCitation` in
`lib/ui2/research_refs.dart`). This file is the provenance record behind the DOI
table in `kResearchRefs`: what each short label means, where the repo says so,
and how the DOI was checked.

How a DOI gets in: fetch `https://api.crossref.org/works/<doi>` and
`https://doi.org/api/handles/<doi>` and confirm the first author, title and year
match the reference. A DOI that does not match is not added. Last checked
2026-10-03; every DOI below returned HTTP 200 from Crossref and handle
`responseCode` 1 from doi.org.

"Analytics" below means the `OpenStrap/analytics` sibling repo
(`ALGORITHMS.md`, `docs/ALGORITHM_CATALOG_1HZ.md`, and source header comments).
"Old analytics docs" means `ALGORITHMS.md` at commit `43c6d63`, which carried a
full references list with venues; the current file dropped the venues.

## Linked

| Label | Reference | DOI | Where the repo names it |
|---|---|---|---|
| Straczkiewicz 2023 | Straczkiewicz M, Huang EJ, Onnela JP. A "one-size-fits-most" walking recognition method for smartphones, smartwatches, and wearable accelerometers. npj Digit Med 6(1), 2023 | https://doi.org/10.1038/s41746-022-00745-z | DOI quoted in `lib/compute/derivation_engine.dart` and analytics `motion/steps.dart` |
| O'Connell 2017 | O'Connell S, OLaighin G, Quinlan LR. When a step is not a step! Specificity analysis of five physical activity monitors. PLoS ONE 12(1):e0169616, 2017 | https://doi.org/10.1371/journal.pone.0169616 | DOI quoted in `lib/compute/derivation_engine.dart` and analytics `motion/steps.dart` |
| Task Force 1996 | Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology. Heart rate variability: standards of measurement, physiological interpretation, and clinical use. Circulation 93(5):1043-1065, 1996 | https://doi.org/10.1161/01.CIR.93.5.1043 | Analytics `clinical/hrv_time.dart` header ("Task Force 1996 conventions"); `hrv_freq.dart` (total power); old analytics docs: "Task Force ESC/NASPE, Circulation 1996". The same report was co-published in Eur Heart J 17:354-381 (10.1093/oxfordjournals.eurheartj.a014868); the Circulation one is linked because that is the venue the old analytics docs name |
| Lipponen & Tarvainen 2019 | Lipponen JA, Tarvainen MP. A robust algorithm for heart rate variability time series artefact correction using novel beat classification. J Med Eng Technol 43(3):173-181, 2019 | https://doi.org/10.1080/03091902.2019.1640306 | Analytics `foundations/rr_correction.dart` header quotes the title and journal |
| Plews 2013 | Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring. Sports Med 43(9):773-781, 2013 | https://doi.org/10.1007/s40279-013-0071-8 | Old analytics docs: "Plews et al., Sports Med 2013" (recovery row, ln-RMSSD z-score). Analytics `readiness_lnrmssd.dart` ("Plews 2013/2014"). Same author also has a 2013 Int J Sports Physiol Perform paper (10.1123/ijspp.8.6.688); the Sports Med one is linked because the old docs name Sports Med |
| Pimentel 2017 | Pimentel MAF, Johnson AEW, Charlton PH, et al. Toward a robust estimation of respiratory rate from pulse oximeters. IEEE Trans Biomed Eng 64(8):1914-1923, 2017 | https://doi.org/10.1109/TBME.2016.2613124 | Analytics `respiration/resp_rate.dart` ("Pimentel 2017's AR-model-order surrogate"); catalog ("Pimentel 2017 AR-order robustness") |
| van Hees 2015 | van Hees VT, Sabia S, Anderson KN, et al. A novel, open access method to assess sleep duration using a wrist-worn accelerometer. PLoS ONE 10(11):e0142533, 2015 | https://doi.org/10.1371/journal.pone.0142533 | Analytics `sleep/van_hees.dart` header: "van Hees et al. 2015 (PLoS ONE)" |
| Keytel 2005 | Keytel LR, Goedecke JH, Noakes TD, et al. Prediction of energy expenditure from heart rate monitoring during submaximal exercise. J Sports Sci 23(3):289-297, 2005 | https://doi.org/10.1080/02640410470001730089 | Analytics `workout/calories.dart` header; old analytics docs: "Keytel et al., J Sports Sci 2005" |
| Cole 1999 | Cole CR, Blackstone EH, Pashkow FJ, Snader CE, Lauer MS. Heart-rate recovery immediately after exercise as a predictor of mortality. N Engl J Med 341(18):1351-1357, 1999 | https://doi.org/10.1056/NEJM199910283411804 | Analytics `workout/hr_recovery.dart` ("Cole 1999: HRR-1min < 12 bpm"); old analytics docs: "Cole, Lauer et al., NEJM 1999" (HRR60 row) |
| Laguna 1998 | Laguna P, Moody GB, Mark RG. Power spectral density of unevenly sampled data by least-square analysis: performance and application to heart rate signals. IEEE Trans Biomed Eng 45(6):698-715, 1998 | https://doi.org/10.1109/10.678605 | Analytics `clinical/hrv_freq.dart` header (Lomb-Scargle on native beat times); `ALGORITHMS.md`: "Laguna, Moody & Mark 1998"; old docs: "Laguna/Moody/Mark, IEEE TBME 1998" |
| Bigger 1992 | Bigger JT Jr, Fleiss JL, Steinman RC, Rolnitzky LM, Kleiger RE, Rottman JN. Frequency domain measures of heart period variability and mortality after myocardial infarction. Circulation 85(1):164-171, 1992 | https://doi.org/10.1161/01.CIR.85.1.164 | Analytics `clinical/hrv_freq.dart` header ("Laguna 1998 / Bigger 1992"), catalog ULF/VLF/LF/HF bands. **Chosen from context, not stated:** the repo gives only "Bigger 1992". Bigger also published "Correlations among time and frequency domain measures of heart period variability two weeks after acute myocardial infarction" in Am J Cardiol 1992 (10.1016/0002-9149(92)90788-Z). The Circulation paper is the one that defines the ULF/VLF/LF/HF bands the analytics code uses, so it is linked; confirm before treating it as settled |

## Not linked: no DOI

| Label | Reference | Why no link | Where the repo names it |
|---|---|---|---|
| Banister 1975 | Banister EW, Calvert TW, Savage MV, Bach T. A systems model of training for athletic performance. Aust J Sports Med 7:57-61, 1975 | The journal article was never issued a DOI; a Crossref search for it finds nothing (the nearest hit, Calvert et al. 1976 IEEE Trans Syst Man Cybern, is a different paper) | Analytics `clinical/load_trimp.dart` ("Banister 1975 impulse-response") for CTL/ATL/TSB. Analytics cites **Banister 1991** (not 1975) for the TRIMP weighting `y = c * e^(b*x)` that the strain score uses; the on-screen label says 1975 |
| Edwards 1993 | Edwards S. The Heart Rate Monitor Book. Fleet Feet Press, Sacramento, 1993 | Trade book, no DOI. Crossref returns only a 1994 book review in Med Sci Sports Exerc (10.1249/00005768-199405000-00020), which is not the book, so it is not linked | Analytics `clinical/load_trimp.dart` header ("Edwards 1993's 50/60/70/80/90 cut-offs"); `ALGORITHMS.md` |
| Baevsky 2008 | Baevsky RM, Berseneva AP. Introduction to heart rate variability analysis: use of the KARDiVAR system for determination of the stress level and estimation of the body's adaptability. Standards of measurements and physiological interpretation. Moscow-Prague, 2008 | A booklet, no DOI that Crossref knows. The repo only says "Baevsky & Berseneva 2008"; the full title above is from memory and is not verified against a source. Not to be confused with Baevsky & Chernikova 2017, Cardiometry 10:66-76 (10.12710/cardiometry.2017.10.6676), a different and later paper | Analytics `ALGORITHMS.md`, old docs ("Baevsky & Berseneva 2008"), `clinical/stress_si.dart` header |

## Label-only citations (no year shown, not in `kResearchRefs`)

These appear on screen without a year, and some name two papers in one label, so
they are not linked. DOIs found and verified the same way, in case a year is added
later:

| On-screen text | Reference | DOI |
|---|---|---|
| Hopkins smallest-worthwhile-change gate | Hopkins WG. Measures of reliability in sports medicine and science. Sports Med 30(1):1-15, 2000 (analytics catalog cites "Hopkins 2000" for SWC; `ALGORITHMS.md` row for readiness cites "Hopkins 2004", Sportscience, which has no DOI) | https://doi.org/10.2165/00007256-200030010-00001 |
| Webster / Cole-Kripke rescoring | Webster JB, Kripke DF, Messin S, Mullaney DJ, Wyborney G. An activity-based sleep monitor system for ambulatory use. Sleep 5(4):389-399, 1982 | https://doi.org/10.1093/sleep/5.4.389 |
| | Cole RJ, Kripke DF, Gruen W, Mullaney DJ, Gillin JC. Automatic sleep/wake identification from wrist activity. Sleep 15(5):461-469, 1992 | https://doi.org/10.1093/sleep/15.5.461 |
| Harris-Benedict / Mifflin BMR floor | Mifflin MD, St Jeor ST, Hill LA, et al. A new predictive equation for resting energy expenditure in healthy individuals. Am J Clin Nutr 51(2):241-247, 1990. (Harris-Benedict, 1918 and the revised 1984 version, not looked up) | https://doi.org/10.1093/ajcn/51.2.241 |
| Tanaka (HRmax, in `lib/compute/hr_max.dart`, not in a citation line) | Tanaka H, Monahan KD, Seals DR. Age-predicted maximal heart rate revisited. J Am Coll Cardiol 37(1):153-156, 2001 | https://doi.org/10.1016/S0735-1097(00)01054-8 |
