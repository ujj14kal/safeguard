# Running Safeguard's backend without a Mac: Google Cloud Run + Supabase

Goal: the live link, guardian page, accounts and SOS alerts keep working
while your Mac is off. Cloud Run runs the backend (scales to zero, so it
costs nothing when idle); Supabase keeps the data and the recordings.

## What it costs

Nothing, as long as you stay inside Google's and Supabase's free
allowances. Cloud Run needs a billing account with a card on file, but its
monthly free allowance (about 2 million requests, 180,000 vCPU-seconds,
360,000 GiB-seconds, 1 GiB outgoing; check
https://cloud.google.com/run/pricing, I could not load the page when I
wrote this) is far above a demo. Supabase Free: 1 GB of recordings
(about 2.5 hours of video), 5 GB outgoing, 500 MB database.
**Budget alert:** a budget of INR 400 (about $5) with email alerts at 50%, 90%
and 100% is set on the billing account, limited to the Safeguard project
("Safeguard demo budget"). Budgets only ALERT, they never stop spending.
`./scripts/cost-check.sh` prints month-to-date usage against the free
allowance, and `deploy-cloud-run.sh` runs it before and after every deploy.

## One-time setup

1. A Google Cloud project with billing linked. A new one for this keeps it
   clean: https://console.cloud.google.com/projectcreate
2. `gcloud auth login` and `gcloud config set project <id>` (gcloud is
   installed). Enable the APIs once:
   `gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com`
3. Put the values in `.env` (git-ignored): `META_MODEL_API_KEY`,
   `SAFEGUARD_APP_TOKEN`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
   `SUPABASE_SERVICE_ROLE_KEY`, optionally `TELEGRAM_BOT_TOKEN` with
   `NOTIFY_MODE=telegram`.
4. Supabase SQL editor: run `supabase/migrations/20261027000000_profiles.sql`
   (accounts).

## Deploy

    ./scripts/deploy-cloud-run.sh <gcp-project-id> [region]

It creates the two private Storage buckets if they are missing, builds the
container in Google's cloud (no Docker needed here), deploys with at most one
instance and none kept warm, and prints the public address, for example
`https://safeguard-backend-123456789.asia-south1.run.app`. That address
is permanent: it does not change on redeploys.

Region: `asia-south1` (Mumbai) is closest to you; confirm on the pricing page
that it is covered by the free tier, otherwise use `us-central1`.

## Point the app at it

    BACKEND_BASE_URL=https://<your address> SAFEGUARD_APP_TOKEN=<token> DEVELOPMENT_TEAM=<team> ./scripts/build.sh device

(or Settings > Developer > backend URL on the phone without rebuilding).

## Keep Supabase awake

Free Supabase projects pause after a week of no activity. `/keepalive`
reads the state bucket and runs a tiny database query. Call it daily:

    gcloud scheduler jobs create http safeguard-keepalive \
      --project <id> --location <region> --schedule "0 6 * * *" \
      --uri https://<your address>/keepalive --http-method GET

(Cloud Scheduler has a small free allowance of jobs per billing account.)

## Telegram

In this mode there is no polling loop (it could not run while scaled to
zero). The backend registers a webhook with Telegram at start-up, using the
public address, so contacts pressing Start still link.

## Limits worth knowing

- First request after idle waits a few seconds for the container to start.
- One instance only: state is held in memory and saved to Supabase on
  change, so two instances would overwrite each other.
- Request timeout is 15 minutes, the longest one connection can stay open (the speech WebSocket reconnects by itself). Cloud Run bills CPU while a request is open, so a phone that keeps the cloud ear connected all day uses the free allowance (about 50 hours of one open connection a month); turn "Cloud ear always on (demo)" off when you are not demoing.
- Recordings are deleted by "Delete all my data" and kept 30 days when a
  guardian is attached; there is no automatic clean-up of other sessions yet,
  so watch the 1 GB.
