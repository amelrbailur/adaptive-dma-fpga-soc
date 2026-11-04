
### LOW

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.365 | 20 | 31 | 47 | 30 / 32 / 47 | 99% / 99% / 99% | 1.000 | 0 | 42% | 1.00 | PASS |
| RR | 0.365 | 27 | 70 | 80 | 46 / 65 / 80 | 99% / 99% / 99% | 1.000 | 0 | 34% | 1.00 | PASS |
| ADAPTIVE | 0.365 | 20 | 33 | 36 | 34 / 36 / 35 | 99% / 99% / 99% | 1.000 | 0 | 40% | 1.00 | PASS |
| ADAPT_V2 | 0.365 | 19 | 29 | 34 | 34 / 28 / 33 | 99% / 99% / 99% | 1.000 | 0 | 43% | 1.00 | PASS |

### LIGHT

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.407 | 49 | 116 | 4991 | 36 / 128 / 35 | 99% / 31% / 0% | 0.526 | 6731 | 54% | 1.00 | PASS |
| RR | 0.370 | 120 | 137 | 142 | 137 / 140 / 142 | 19% / 20% / 22% | 0.997 | 7060 | 28% | 1.00 | PASS |
| ADAPTIVE | 0.411 | 107 | 135 | 146 | 140 / 135 / 146 | 23% / 27% / 24% | 0.995 | 6242 | 31% | 1.00 | PASS |
| ADAPT_V2 | 0.447 | 95 | 115 | 124 | 117 / 116 / 124 | 28% / 30% / 30% | 0.999 | 5474 | 46% | 1.00 | PASS |

### BALANCED

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.427 | 51 | 182 | 4998 | 33 / 193 / 40 | 99% / 12% / 0% | 0.414 | 8499 | 61% | 1.00 | PASS |
| RR | 0.368 | 123 | 141 | 146 | 142 / 146 / 142 | 16% / 17% / 15% | 0.998 | 9576 | 27% | 1.00 | PASS |
| ADAPTIVE | 0.411 | 109 | 135 | 143 | 143 / 135 / 139 | 18% / 21% / 17% | 0.992 | 8959 | 29% | 1.00 | PASS |
| ADAPT_V2 | 0.484 | 91 | 108 | 114 | 112 / 109 / 114 | 23% / 25% / 22% | 0.997 | 7918 | 45% | 1.00 | PASS |

### HEAVY

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.553 | 33 | 39 | 4999 | 42 / 0 / 0 | 62% / 0% / 0% | 0.333 | 12158 | 100% | 1.00 | PASS |
| RR | 0.368 | 126 | 144 | 148 | 148 / 146 / 142 | 13% / 14% / 15% | 0.995 | 11461 | 27% | 1.00 | PASS |
| ADAPTIVE | 0.408 | 113 | 143 | 153 | 136 / 150 / 153 | 16% / 16% / 15% | 0.999 | 11208 | 31% | 1.00 | PASS |
| ADAPT_V2 | 0.489 | 93 | 113 | 128 | 113 / 117 / 128 | 17% / 19% / 21% | 0.993 | 10350 | 45% | 1.00 | PASS |

### SLOW_DRAM

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.335 | 62 | 1023 | 4998 | 87 / 3081 / 80 | 97% / 0% / 0% | 0.337 | 9885 | 97% | 1.00 | PASS |
| RR | 0.181 | 255 | 291 | 306 | 293 / 306 / 290 | 6% / 7% / 6% | 1.000 | 12266 | 28% | 1.00 | PASS |
| ADAPTIVE | 0.187 | 246 | 299 | 317 | 295 / 317 / 311 | 7% / 7% / 6% | 0.999 | 12186 | 28% | 1.00 | PASS |
| ADAPT_V2 | 0.261 | 175 | 208 | 215 | 209 / 211 / 215 | 10% / 10% / 10% | 0.999 | 11128 | 45% | 1.00 | PASS |

Thr = requests (step 2) or completed beats (step 3) per cycle. Latency in cycles from request ready at the accelerator to grant (includes source stalls). Srv/Off = served / demand cycles. Max* includes requests still queued at the end. Jain over served/offered per channel.
