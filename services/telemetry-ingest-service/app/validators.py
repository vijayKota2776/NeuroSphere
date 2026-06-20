"""
NeuroSphere Telemetry Ingest Service — Event Validation

Validates incoming telemetry payloads before they are stored in the
circular buffer. Designed to be fast — all checks are O(1).
"""

from typing import Any, Dict, List, Tuple

from app.models import VALID_EVENT_TYPES, VALID_SOURCE_TYPES


# Maximum payload size in bytes (rough JSON estimate)
MAX_PAYLOAD_SIZE_BYTES = 64 * 1024  # 64 KiB per event
MAX_BATCH_SIZE = 1000


def validate_event(event: Dict[str, Any]) -> Tuple[bool, str]:
    """
    Validate a single telemetry event dict.

    Returns:
        (is_valid, error_message)  — error_message is empty when valid.
    """
    # Required fields -------------------------------------------------------
    required = ("source_id", "source_type", "event_type", "timestamp", "payload")
    for key in required:
        if key not in event:
            return False, f"Missing required field: '{key}'"

    # source_id -------------------------------------------------------------
    source_id = event["source_id"]
    if not isinstance(source_id, str) or not source_id.strip():
        return False, "source_id must be a non-empty string"

    # source_type -----------------------------------------------------------
    source_type = event["source_type"]
    if source_type not in VALID_SOURCE_TYPES:
        return False, (
            f"Invalid source_type '{source_type}'. "
            f"Must be one of: {', '.join(sorted(VALID_SOURCE_TYPES))}"
        )

    # event_type ------------------------------------------------------------
    event_type = event["event_type"]
    if event_type not in VALID_EVENT_TYPES:
        return False, (
            f"Invalid event_type '{event_type}'. "
            f"Must be one of: {', '.join(sorted(VALID_EVENT_TYPES))}"
        )

    # timestamp -------------------------------------------------------------
    timestamp = event["timestamp"]
    if not isinstance(timestamp, str) or not timestamp.strip():
        return False, "timestamp must be a non-empty ISO-8601 string"

    # payload ---------------------------------------------------------------
    payload = event["payload"]
    if not isinstance(payload, dict):
        return False, "payload must be a JSON object (dict)"

    return True, ""


def validate_batch(events: Any) -> Tuple[bool, str]:
    """
    Validate the top-level batch structure (must be a list, within size limit).
    Individual events are validated separately.
    """
    if not isinstance(events, list):
        return False, "Request body must be a JSON array of events"
    if len(events) == 0:
        return False, "Batch must contain at least one event"
    if len(events) > MAX_BATCH_SIZE:
        return False, f"Batch exceeds maximum size of {MAX_BATCH_SIZE} events"
    return True, ""


def validate_events(events: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """
    Validate a list of event dicts.

    Returns:
        (valid_events, errors)  — errors is a list of {index, error} dicts
    """
    valid: List[Dict[str, Any]] = []
    errors: List[Dict[str, str]] = []
    for idx, event in enumerate(events):
        ok, msg = validate_event(event)
        if ok:
            valid.append(event)
        else:
            errors.append({"index": str(idx), "error": msg})
    return valid, errors
