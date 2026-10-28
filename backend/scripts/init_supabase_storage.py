
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.config import SETTINGS  # noqa: E402
from app.storage import StorageUnavailable, SupabaseObjects  # noqa: E402


def main() -> int:
    if not (SETTINGS.supabase_url and SETTINGS.supabase_service_role_key):
        print("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.")
        return 1
    for bucket in (SETTINGS.state_bucket, SETTINGS.evidence_bucket):
        try:
            SupabaseObjects(
                SETTINGS.supabase_url, SETTINGS.supabase_service_role_key, bucket
            ).ensure_bucket()
            print(f"bucket ready: {bucket}")
        except StorageUnavailable as exc:
            print(f"could not create {bucket}: {exc}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
