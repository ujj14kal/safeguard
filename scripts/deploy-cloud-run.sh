#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${1:?usage: deploy-cloud-run.sh <gcp-project-id> [region]}"
REGION="${2:-asia-south1}"
SERVICE="safeguard-backend"

[ -f .env ] || { echo ".env not found" >&2; exit 1; }
set -a; . ./.env; set +a
for var in META_MODEL_API_KEY SAFEGUARD_APP_TOKEN SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY; do
  [ -n "${!var:-}" ] || { echo "$var is missing from .env" >&2; exit 1; }
done

NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
PUBLIC_URL="https://${SERVICE}-${NUMBER}.${REGION}.run.app"

ENVFILE="$(mktemp)"
trap 'rm -f "$ENVFILE"' EXIT
PUBLIC_URL="$PUBLIC_URL" python3 - > "$ENVFILE" <<'PY'
import json, os
names = ["META_MODEL_API_KEY", "SAFEGUARD_APP_TOKEN", "SUPABASE_URL", "SUPABASE_ANON_KEY",
         "SUPABASE_SERVICE_ROLE_KEY", "NOTIFY_MODE", "TELEGRAM_BOT_TOKEN", "TELEGRAM_BOT",
         "MUSE_MODEL", "GUARDIAN_RETENTION_DAYS"]
values = {n: os.environ[n] for n in names if os.environ.get(n)}
values.update(STORAGE_BACKEND="supabase", PUBLIC_BASE_URL=os.environ["PUBLIC_URL"])
for key, value in values.items():
    print(f"{key}: {json.dumps(value)}")
PY

echo "Making sure the Supabase buckets exist..."
(cd backend && .venv/bin/python scripts/init_supabase_storage.py)

echo "Cost before this deploy:"
./scripts/cost-check.sh "$PROJECT" "$SERVICE" || echo "(cost check unavailable)"

echo "Deploying $SERVICE to $PROJECT ($REGION)..."
gcloud run deploy "$SERVICE" \
  --project "$PROJECT" --region "$REGION" --source backend \
  --allow-unauthenticated \
  --min-instances 0 --max-instances 1 \
  --cpu 1 --memory 512Mi --concurrency 20 --timeout 900 --no-cpu-boost \
  --env-vars-file "$ENVFILE"

echo "Removing old container images..."
REPO="$REGION-docker.pkg.dev/$PROJECT/cloud-run-source-deploy/$SERVICE"
LIVE_DIGEST="$(gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
  --format='value(spec.template.spec.containers[0].image)' | sed 's/.*@//')"
if [ -n "$LIVE_DIGEST" ]; then
  gcloud artifacts docker images list "$REPO" --project "$PROJECT" --format='value(version)' 2>/dev/null |
    while read -r digest; do
      [ -n "$digest" ] && [ "$digest" != "$LIVE_DIGEST" ] &&
        gcloud artifacts docker images delete "$REPO@$digest" --project "$PROJECT" --quiet >/dev/null 2>&1 || true
    done
fi

echo
echo "Cost after this deploy:"
./scripts/cost-check.sh "$PROJECT" "$SERVICE" || echo "(cost check unavailable)"

echo
echo "Live at: $PUBLIC_URL"
echo "Guardian page: $PUBLIC_URL/guardian"
echo "Build the app with: BACKEND_BASE_URL=$PUBLIC_URL SAFEGUARD_APP_TOKEN=... ./scripts/build.sh device"
