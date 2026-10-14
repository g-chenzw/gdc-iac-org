import os
from pathlib import Path
from google.cloud import storage
from fastapi import UploadFile, HTTPException

INPUT_BUCKET = os.getenv("INPUT_BUCKET", "gemini-gui-files-test-project")
if INPUT_BUCKET.startswith("gs://"):
    INPUT_BUCKET = INPUT_BUCKET[5:]

LOCAL_STORAGE_ROOT = Path(os.getenv("LOCAL_STORAGE_DIR", "/tmp/gemma-uploads"))
LOCAL_STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
ENABLE_GCS_UPLOAD = os.getenv("ENABLE_GCS_UPLOAD", "true").lower() == "true"

# Initialize GCS Client (primary object storage backend via GKE Workload Identity / GDC Object Storage)
try:
    storage_client = storage.Client() if ENABLE_GCS_UPLOAD else None
except Exception as e:
    print(f"Warning: Could not initialize Storage Client: {e}")
    storage_client = None


def _sanitize_segment(name: str) -> str:
    safe = os.path.basename((name or "").replace("\\", "/")).strip()
    if not safe or safe in (".", ".."):
        raise HTTPException(status_code=400, detail="Invalid file or user path segment")
    return safe


def _local_file_path(rel_path: str) -> Path:
    parts = [p for p in rel_path.split("/") if p]
    if not parts or ".." in parts:
        raise HTTPException(status_code=400, detail="Invalid storage path")
    target = (LOCAL_STORAGE_ROOT / Path(*parts)).resolve()
    if not str(target).startswith(str(LOCAL_STORAGE_ROOT.resolve())):
        raise HTTPException(status_code=400, detail="Invalid storage path")
    return target


async def upload_file_to_gcs(file: UploadFile, user_id: str, is_shared: bool) -> str:
    safe_filename = _sanitize_segment(file.filename or "upload.bin")
    safe_user = _sanitize_segment(user_id) if not is_shared else ""

    prefix = "shared" if is_shared else f"users/{safe_user}"
    blob_name = f"{prefix}/{safe_filename}"

    data = await file.read()

    # Always persist to shared pod storage (/tmp/gemma-uploads) for air-gapped & staging resilience
    local_target = _local_file_path(blob_name)
    local_target.parent.mkdir(parents=True, exist_ok=True)
    local_target.write_bytes(data)

    if storage_client and INPUT_BUCKET and "PLACEHOLDER" not in INPUT_BUCKET:
        try:
            bucket = storage_client.bucket(INPUT_BUCKET)
            blob = bucket.blob(blob_name)
            blob.upload_from_string(data, content_type=file.content_type)
            return f"gs://{INPUT_BUCKET}/{blob_name}"
        except Exception as e:
            print(f"Notice: GCS upload failed ({e}); using local pod storage for {blob_name}")

    return f"local://{blob_name}"


async def delete_file_from_gcs(gcs_path: str):
    if gcs_path.startswith("local://"):
        rel_path = gcs_path[len("local://"):]
        local_target = _local_file_path(rel_path)
        if local_target.exists():
            local_target.unlink()
        return

    if not gcs_path.startswith("gs://"):
        return

    parts = gcs_path.replace("gs://", "").split("/", 1)
    if len(parts) != 2:
        return

    bucket_name, blob_name = parts
    if ".." in blob_name.split("/"):
        raise HTTPException(status_code=400, detail="Invalid storage path")

    local_target = _local_file_path(blob_name)
    if local_target.exists():
        local_target.unlink()

    if storage_client:
        try:
            bucket = storage_client.bucket(bucket_name)
            blob = bucket.blob(blob_name)
            blob.delete()
        except Exception as e:
            print(f"Notice: GCS delete skipped ({e})")


def get_blob_content(gcs_path: str) -> bytes:
    if gcs_path.startswith("local://"):
        rel_path = gcs_path[len("local://"):]
        local_target = _local_file_path(rel_path)
        if not local_target.exists():
            raise FileNotFoundError(f"Local file not found: {rel_path}")
        return local_target.read_bytes()

    if gcs_path.startswith("gs://"):
        parts = gcs_path.replace("gs://", "").split("/", 1)
        if len(parts) != 2:
            raise ValueError("Invalid storage path")
        bucket_name, blob_name = parts
        if ".." in blob_name.split("/"):
            raise ValueError("Invalid storage path")

        local_target = _local_file_path(blob_name)
        if local_target.exists():
            return local_target.read_bytes()

        if not storage_client:
            raise Exception("Storage service unavailable")
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        return blob.download_as_bytes()

    raise ValueError(f"Unsupported storage path: {gcs_path}")
