#!/usr/bin/env bash
# Month-to-date cost check for the Cloud Run backend. Run it before and after
# every deploy (deploy-cloud-run.sh runs it for you), and whenever you wonder.
#
#   ./scripts/cost-check.sh [gcp-project-id] [service]
#
# It reads Cloud Monitoring (free) for the service's billable instance time and
# request count, compares them with Cloud Run's monthly free allowance, and
# prints a rough dollar figure for what is OVER the free allowance. Rates and
# allowances are from Google's public pricing as I remember it (CPU $0.000024
# per vCPU-second and memory $0.0000025 per GiB-second beyond 180,000 and
# 360,000 free), so treat the dollars as an estimate and confirm in the
# billing console. It cannot see other products or other apps that share the
# billing account's free allowance.
set -euo pipefail

PROJECT="${1:-safeguard-512917}"
SERVICE="${2:-safeguard-backend}"
FREE_VCPU_S=180000
FREE_GIB_S=360000
VCPUS=1
GIB=0.5

TOKEN="$(gcloud auth print-access-token)"
START="$(date -u +%Y-%m-01T00:00:00Z)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

query() {  # $1 metric type -> summed value this month
  curl -s -G "https://monitoring.googleapis.com/v3/projects/${PROJECT}/timeSeries" \
    -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT}" \
    --data-urlencode "filter=metric.type=\"$1\" AND resource.labels.service_name=\"${SERVICE}\"" \
    --data-urlencode "interval.startTime=${START}" --data-urlencode "interval.endTime=${END}" \
    --data-urlencode "aggregation.alignmentPeriod=2678400s" \
    --data-urlencode "aggregation.perSeriesAligner=ALIGN_SUM" \
    --data-urlencode "aggregation.crossSeriesReducer=REDUCE_SUM" |
  python3 -c '
import json, sys
d = json.load(sys.stdin)
total = 0.0
for series in d.get("timeSeries", []):
    for p in series.get("points", []):
        v = p["value"]
        total += float(v.get("doubleValue", v.get("int64Value", 0)))
print(total)'
}

BILLABLE_S="$(query run.googleapis.com/container/billable_instance_time)"
REQUESTS="$(query run.googleapis.com/request_count)"

python3 - "$BILLABLE_S" "$REQUESTS" "$FREE_VCPU_S" "$FREE_GIB_S" "$VCPUS" "$GIB" "$PROJECT" "$SERVICE" <<'PY'
import sys
billable, requests, free_cpu, free_mem, vcpus, gib = map(float, sys.argv[1:7])
project, service = sys.argv[7:9]
cpu_s, mem_s = billable * vcpus, billable * gib
over_cpu, over_mem = max(0, cpu_s - free_cpu), max(0, mem_s - free_mem)
dollars = over_cpu * 0.000024 + over_mem * 0.0000025
print(f"Cost check for {service} in {project} (month to date)")
print(f"  requests:            {int(requests):,}   (free: about 2,000,000 a month)")
print(f"  billable time:       {billable/3600:.1f} h   -> {cpu_s:,.0f} vCPU-s of 180,000 free ({100*cpu_s/free_cpu:.0f}%)")
print(f"                          {mem_s:,.0f} GiB-s of 360,000 free ({100*mem_s/free_mem:.0f}%)")
print(f"  estimated over free: about ${dollars:.2f}")
if cpu_s > 0.8 * free_cpu or mem_s > 0.8 * free_mem:
    print("  WARNING: more than 80% of the free allowance is used. Turn off the cloud ear's 'always on' demo setting.")
elif dollars == 0:
    print("  OK: inside the free allowance.")
PY

# Container images pile up on every deploy.
SIZE_MB="$(gcloud artifacts repositories list --project "$PROJECT" --format='value(sizeBytes)' 2>/dev/null | head -1 | python3 -c 'import sys; v=sys.stdin.read().strip(); print(round(float(v or 0)))' 2>/dev/null || echo "?")"
echo "  container images:    ${SIZE_MB} MB stored (free: 500 MB)"
