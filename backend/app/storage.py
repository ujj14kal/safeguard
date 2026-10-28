
from __future__ import annotations

import json as _json
import logging
import os
import shutil
from pathlib import Path
from urllib.parse import quote

import httpx
from fastapi.responses import FileResponse, StreamingResponse

logger = logging.getLogger("safeguard.storage")


class StorageUnavailable(Exception):
    pass


def _http(method, url, *, headers, content=None, json=None, timeout=20.0):
    try:
        response = httpx.request(
            method, url, headers=headers, content=content, json=json, timeout=timeout
        )
    except httpx.HTTPError as exc:
        raise StorageUnavailable(type(exc).__name__) from exc
    return response.status_code, response.headers, response.content


def _stream(url, *, headers, timeout=30.0):
    client = httpx.Client(timeout=timeout)
    try:
        request = client.build_request("GET", url, headers=headers)
        response = client.send(request, stream=True)
    except httpx.HTTPError as exc:
        client.close()
        raise StorageUnavailable(type(exc).__name__) from exc

    def body():
        try:
            yield from response.iter_bytes()
        finally:
            response.close()
            client.close()

    return response.status_code, response.headers, body()


class StateFile:

    def read(self) -> str | None:
        raise NotImplementedError

    def write(self, text: str) -> None:
        raise NotImplementedError


class LocalStateFile(StateFile):
    def __init__(self, path: str):
        self.path = path

    def read(self):
        try:
            with open(self.path, encoding="utf-8") as handle:
                return handle.read()
        except FileNotFoundError:
            return None
        except OSError:
            return None

    def write(self, text):
        parent = os.path.dirname(self.path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        tmp = f"{self.path}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, self.path)


class SupabaseStateFile(StateFile):
    def __init__(self, supabase: "SupabaseObjects", name: str):
        self._s = supabase
        self._name = name

    def read(self):
        data = self._s.get(self._name)
        return None if data is None else data.decode("utf-8")

    def write(self, text):
        self._s.put(self._name, text.encode("utf-8"), "application/json")


def as_state_file(value) -> "StateFile | None":
    if value is None or value == "":
        return None
    if isinstance(value, StateFile):
        return value
    return LocalStateFile(str(value))


class SupabaseObjects:

    def __init__(self, url: str, service_key: str, bucket: str):
        self.base = f"{url.rstrip('/')}/storage/v1"
        self.bucket = bucket
        self._key = service_key

    def _headers(self, extra=None):
        headers = {"apikey": self._key, "Authorization": f"Bearer {self._key}"}
        headers.update(extra or {})
        return headers

    def _object_url(self, path: str) -> str:
        return f"{self.base}/object/{self.bucket}/{quote(path, safe='/')}"

    def ensure_bucket(self) -> None:
        status, _, _ = _http(
            "POST", f"{self.base}/bucket", headers=self._headers(),
            json={"id": self.bucket, "name": self.bucket, "public": False},
        )
        if status not in (200, 201, 400, 409):
            raise StorageUnavailable(f"bucket {self.bucket}: {status}")

    def get(self, path: str) -> bytes | None:
        status, _, content = _http("GET", self._object_url(path), headers=self._headers())
        if status == 200:
            return content
        if status in (400, 404):
            return None
        raise StorageUnavailable(f"read {path}: {status}")

    def put(self, path: str, data: bytes, content_type: str) -> None:
        status, _, _ = _http(
            "POST", self._object_url(path),
            headers=self._headers({"Content-Type": content_type, "x-upsert": "true"}),
            content=data,
        )
        if status not in (200, 201):
            raise StorageUnavailable(f"write {path}: {status}")

    def list_objects(self, prefix: str) -> list[dict]:
        status, _, content = _http(
            "POST", f"{self.base}/object/list/{self.bucket}", headers=self._headers(),
            json={"prefix": prefix, "limit": 1000, "offset": 0,
                  "sortBy": {"column": "name", "order": "asc"}},
        )
        if status != 200:
            raise StorageUnavailable(f"list {prefix}: {status}")
        return _json.loads(content or b"[]")

    def delete(self, paths: list[str]) -> None:
        if not paths:
            return
        status, _, _ = _http(
            "DELETE", f"{self.base}/object/{self.bucket}", headers=self._headers(),
            json={"prefixes": paths},
        )
        if status not in (200, 204):
            raise StorageUnavailable(f"delete: {status}")

    def stream(self, path: str, range_header: str | None):
        extra = {"Range": range_header} if range_header else None
        return _stream(self._object_url(path), headers=self._headers(extra))


def _epoch(iso: str | None) -> float:
    if not iso:
        return 0.0
    try:
        from datetime import datetime
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


class EvidenceBackend:
    def put(self, session: str, name: str, data: bytes) -> None: ...
    def segments(self, session: str) -> list[dict] | None: ...
    def delete_session(self, session: str) -> bool: ...
    def exists(self, session: str, name: str) -> bool: ...
    def response(self, session: str, name: str, media_type: str, range_header: str | None): ...
    def read(self, session: str, name: str) -> bytes | None: ...


class LocalEvidence(EvidenceBackend):
    def __init__(self, root: Path):
        self.root = Path(root)

    def put(self, session, name, data):
        folder = self.root / session
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_bytes(data)

    def read(self, session, name):
        path = self.root / session / name
        return path.read_bytes() if path.is_file() else None

    def segments(self, session):
        folder = self.root / session
        if not folder.is_dir():
            return None
        return [
            {"name": f.name, "bytes": f.stat().st_size, "mtime": f.stat().st_mtime}
            for f in sorted(folder.iterdir())
        ]

    def delete_session(self, session):
        folder = self.root / session
        if not folder.is_dir():
            return False
        shutil.rmtree(folder)
        return True

    def exists(self, session, name):
        return (self.root / session / name).is_file()

    def response(self, session, name, media_type, range_header):
        return FileResponse(self.root / session / name, media_type=media_type, filename=None)


class SupabaseEvidence(EvidenceBackend):
    def __init__(self, objects: SupabaseObjects):
        self._o = objects

    def put(self, session, name, data):
        if name.endswith(".m4a"):
            content_type = "audio/mp4"
        elif name.endswith(".jpg"):
            content_type = "image/jpeg"
        else:
            content_type = "video/mp4"
        self._o.put(f"{session}/{name}", data, content_type)

    def read(self, session, name):
        return self._o.get(f"{session}/{name}")

    def segments(self, session):
        items = [i for i in self._o.list_objects(session) if i.get("id")]
        if not items:
            return None
        return [
            {
                "name": i["name"],
                "bytes": int((i.get("metadata") or {}).get("size") or 0),
                "mtime": _epoch(i.get("updated_at") or i.get("created_at")),
            }
            for i in sorted(items, key=lambda i: i["name"])
        ]

    def delete_session(self, session):
        items = self.segments(session)
        if not items:
            return False
        self._o.delete([f"{session}/{i['name']}" for i in items])
        return True

    def exists(self, session, name):
        items = self.segments(session) or []
        return any(i["name"] == name for i in items)

    def response(self, session, name, media_type, range_header):
        status, headers, body = self._o.stream(f"{session}/{name}", range_header)
        if status not in (200, 206):
            for _ in body:
                pass
            return None
        out = {"Accept-Ranges": "bytes"}
        for key in ("Content-Length", "Content-Range"):
            if key in headers:
                out[key] = headers[key]
        return StreamingResponse(body, status_code=status, media_type=media_type, headers=out)


def make_state_file(settings, name: str, local_path: str):
    if settings.storage_backend == "supabase":
        return SupabaseStateFile(
            SupabaseObjects(settings.supabase_url, settings.supabase_service_role_key,
                            settings.state_bucket),
            name,
        )
    return local_path


def make_evidence(settings) -> EvidenceBackend:
    if settings.storage_backend == "supabase":
        return SupabaseEvidence(
            SupabaseObjects(settings.supabase_url, settings.supabase_service_role_key,
                            settings.evidence_bucket)
        )
    return LocalEvidence(Path(settings.evidence_dir))


class AvatarStore:

    def __init__(self, objects: "SupabaseObjects | None" = None, root: Path | None = None):
        self._objects = objects
        self._root = root

    @staticmethod
    def _key(user_id: str) -> str:
        return f"avatars/{user_id}.jpg"

    def get(self, user_id: str) -> bytes | None:
        if self._objects is not None:
            return self._objects.get(self._key(user_id))
        path = self._root / f"{user_id}.jpg"
        return path.read_bytes() if path.is_file() else None

    def put(self, user_id: str, data: bytes) -> None:
        if self._objects is not None:
            self._objects.put(self._key(user_id), data, "image/jpeg")
            return
        self._root.mkdir(parents=True, exist_ok=True)
        tmp = self._root / f"{user_id}.jpg.tmp"
        tmp.write_bytes(data)
        os.replace(tmp, self._root / f"{user_id}.jpg")

    def delete(self, user_id: str) -> None:
        if self._objects is not None:
            self._objects.delete([self._key(user_id)])
            return
        (self._root / f"{user_id}.jpg").unlink(missing_ok=True)


def make_avatars(settings) -> AvatarStore:
    if settings.storage_backend == "supabase":
        return AvatarStore(objects=SupabaseObjects(
            settings.supabase_url, settings.supabase_service_role_key, settings.state_bucket
        ))
    return AvatarStore(root=Path(settings.avatar_dir))
