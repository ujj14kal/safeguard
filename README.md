# safeguard

Safeguard: a personal-safety iOS app (Meta AI hackathon). On-device behaviour
detection, voice check-in, and four parallel escalation tracks.
Full README (run instructions, architecture, ethics) lands with later phases.

## Keys and secrets

All API keys and tokens come from environment variables — see `.env.example`
(copy it to `.env` locally and fill it in). Never commit `.env` files or real
credentials; a pre-commit hook (`scripts/pre-commit.sh`) blocks them.
