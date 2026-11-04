
### LOW

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.365 | 20 | 32 | 45 | 32 / 35 / 45 | 99% / 99% / 99% | 1.000 | 0 | 41% | 1.00 | PASS |
| RR | 0.365 | 23 | 46 | 55 | 38 / 55 / 52 | 99% / 99% / 99% | 1.000 | 0 | 36% | 1.01 | PASS |
| ADAPTIVE | 0.365 | 20 | 33 | 36 | 35 / 36 / 36 | 99% / 99% / 99% | 1.000 | 0 | 40% | 1.01 | PASS |
| ADAPT_V2 | 0.365 | 19 | 30 | 39 | 39 / 30 / 35 | 99% / 99% / 99% | 1.000 | 0 | 42% | 1.01 | PASS |

### LIGHT

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.412 | 51 | 115 | 4991 | 42 / 133 / 35 | 99% / 34% / 0% | 0.540 | 6618 | 42% | 1.12 | PASS |
| RR | 0.460 | 88 | 161 | 170 | 66 / 165 / 170 | 99% / 16% / 17% | 0.567 | 5321 | 21% | 1.45 | PASS |
| ADAPTIVE | 0.479 | 95 | 140 | 154 | 107 / 137 / 154 | 54% / 28% / 23% | 0.879 | 4857 | 24% | 1.34 | PASS |
| ADAPT_V2 | 0.552 | 70 | 118 | 135 | 66 / 121 / 135 | 99% / 31% / 32% | 0.748 | 3358 | 35% | 1.37 | PASS |

### BALANCED

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.463 | 51 | 139 | 4998 | 40 / 152 / 40 | 99% / 18% / 0% | 0.455 | 7954 | 45% | 1.27 | PASS |
| RR | 0.502 | 94 | 156 | 161 | 80 / 156 / 161 | 63% / 15% / 13% | 0.638 | 7554 | 16% | 1.50 | PASS |
| ADAPTIVE | 0.486 | 97 | 138 | 156 | 109 / 148 / 156 | 37% / 20% / 17% | 0.888 | 7806 | 24% | 1.36 | PASS |
| ADAPT_V2 | 0.553 | 82 | 126 | 145 | 82 / 145 / 145 | 54% / 21% / 19% | 0.805 | 6856 | 34% | 1.39 | PASS |

### HEAVY

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.830 | 32 | 36 | 4999 | 37 / 0 / 0 | 90% / 0% / 0% | 0.333 | 10767 | 100% | 2.50 | PASS |
| RR | 0.442 | 117 | 180 | 186 | 107 / 186 / 184 | 26% / 11% / 11% | 0.845 | 11412 | 15% | 1.50 | PASS |
| ADAPTIVE | 0.489 | 103 | 168 | 183 | 109 / 173 / 183 | 28% / 14% / 12% | 0.876 | 11002 | 19% | 1.48 | PASS |
| ADAPT_V2 | 0.566 | 87 | 137 | 145 | 80 / 139 / 145 | 32% / 14% / 15% | 0.865 | 10446 | 32% | 1.51 | PASS |

### SLOW_DRAM

| Arbiter | Thr | Lat avg | p99 | Max* | Max F/M/S | Srv/Off F/M/S | Jain | Stalls | RowHit | Burst | Check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FIXED | 0.377 | 77 | 371 | 4998 | 78 / 420 / 80 | 98% / 5% / 0% | 0.369 | 9222 | 60% | 1.69 | PASS |
| RR | 0.295 | 170 | 276 | 281 | 163 / 279 / 281 | 24% / 7% / 7% | 0.732 | 10568 | 16% | 1.49 | PASS |
| ADAPTIVE | 0.245 | 205 | 332 | 351 | 211 / 351 / 341 | 17% / 7% / 6% | 0.815 | 11283 | 20% | 1.45 | PASS |
| ADAPT_V2 | 0.350 | 138 | 233 | 237 | 139 / 235 / 237 | 32% / 9% / 9% | 0.712 | 9755 | 31% | 1.50 | PASS |

Thr = requests (step 2) or completed beats (step 3) per cycle. Latency in cycles from request ready at the accelerator to grant (includes source stalls). Srv/Off = served / demand cycles. Max* includes requests still queued at the end. Jain over served/offered per channel.
