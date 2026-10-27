# Safeguard backend for Google Cloud Run (or any container host).
# Build from this folder: gcloud run deploy --source .
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    STORAGE_BACKEND=supabase

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Cloud Run sets PORT; one worker keeps the in-memory state consistent
# (the deploy uses --max-instances 1 for the same reason).
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1"]
