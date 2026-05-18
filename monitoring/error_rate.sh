#!/usr/bin/env bash
# =============================================================================
# OrFlow API — monitoring/error_rate.sh
# =============================================================================
# Reads structured JSON logs from the OrFlow API pod and calculates
# the error rate over a configurable time window.
#
# Writes a summary to monitoring/monitoring.log — the file Jenkins archives
# as a build artifact and Nia can read without a monitoring dashboard.
#
# Why log-based and not Prometheus?
#   Option B from the Track A spec: log-based error rate calculation
#   following the Week 7 SLO pattern. Requires only the existing structured
#   logging in main.py — no additional tooling needed.
#
# How it works:
#   1. Pulls the last N lines of logs from the running pod via kubectl logs
#   2. Parses each JSON log line with Python (available on all target systems)
#   3. Counts total requests and error responses (status_code >= 400)
#   4. Calculates error rate as a percentage
#   5. Writes a structured summary to monitoring.log
#   6. Exits non-zero if error rate exceeds the threshold — Jenkins sees this
#
# Usage:
#   ./monitoring/error_rate.sh [namespace] [tail_lines] [threshold_percent]
#
# Defaults:
#   namespace         = orflow-production
#   tail_lines        = 200
#   threshold_percent = 5
#
# Examples:
#   ./monitoring/error_rate.sh
#   ./monitoring/error_rate.sh orflow-staging 100 10
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — defaults overridable by positional arguments
# -----------------------------------------------------------------------------
NAMESPACE="${1:-orflow-production}"
TAIL_LINES="${2:-200}"
THRESHOLD="${3:-5}"

APP_NAME="orflow-api"
LOG_FILE="monitoring/monitoring.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log() { echo "[${TIMESTAMP}] $*"; }

# Ensure the monitoring directory exists
mkdir -p monitoring

log "Starting error rate check"
log "Namespace  : ${NAMESPACE}"
log "Tail lines : ${TAIL_LINES}"
log "Threshold  : ${THRESHOLD}%"

# -----------------------------------------------------------------------------
# Step 1 — Confirm the pod is running before pulling logs
# -----------------------------------------------------------------------------
log "Checking pod status..."

POD_STATUS=$(kubectl get pods \
    -l app="${APP_NAME}" \
    -n "${NAMESPACE}" \
    --no-headers \
    -o custom-columns="STATUS:.status.phase" 2>/dev/null | head -1)

if [[ -z "${POD_STATUS}" ]]; then
    log "ERROR: No pod found for app=${APP_NAME} in namespace=${NAMESPACE}"
    log "Is the deployment running? Check: kubectl get pods -n ${NAMESPACE}"
    exit 1
fi

if [[ "${POD_STATUS}" != "Running" ]]; then
    log "WARNING: Pod status is '${POD_STATUS}', expected 'Running'"
    log "Proceeding with log pull — logs may be incomplete"
fi

log "Pod status: ${POD_STATUS}"

# -----------------------------------------------------------------------------
# Step 2 — Pull logs from the running pod
# -----------------------------------------------------------------------------
log "Pulling last ${TAIL_LINES} log lines from ${NAMESPACE}..."

RAW_LOGS=$(kubectl logs \
    -l app="${APP_NAME}" \
    -n "${NAMESPACE}" \
    --tail="${TAIL_LINES}" \
    2>/dev/null) || {
    log "ERROR: kubectl logs failed — cannot calculate error rate"
    exit 1
}

TOTAL_LINES=$(echo "${RAW_LOGS}" | wc -l | tr -d ' ')
log "Raw log lines retrieved: ${TOTAL_LINES}"

if [[ "${TOTAL_LINES}" -eq 0 ]]; then
    log "WARNING: No log lines found. Has the pod received any traffic?"
    log "Skipping error rate calculation."
    exit 0
fi

# -----------------------------------------------------------------------------
# Step 3 — Parse JSON logs and calculate error rate
# -----------------------------------------------------------------------------
# Uses Python to parse each line as JSON safely.
# Counts lines where status_code >= 400 as errors.
# Lines that are not valid JSON (e.g. gunicorn startup messages) are skipped.
# -----------------------------------------------------------------------------
log "Parsing structured logs and calculating error rate..."

RESULT=$(echo "${RAW_LOGS}" | python3 "$(dirname "$0")/parse_logs.py")

# Parse Python output into shell variables
TOTAL_REQUESTS=$(echo "${RESULT}" | grep TOTAL_REQUESTS | cut -d= -f2)
ERROR_COUNT=$(echo "${RESULT}"    | grep ERROR_COUNT    | cut -d= -f2)
ERROR_RATE=$(echo "${RESULT}"     | grep ERROR_RATE     | cut -d= -f2)
SKIPPED=$(echo "${RESULT}"        | grep SKIPPED        | cut -d= -f2)

log "Total requests : ${TOTAL_REQUESTS}"
log "Error count    : ${ERROR_COUNT}"
log "Error rate     : ${ERROR_RATE}%"
log "Skipped lines  : ${SKIPPED} (non-JSON or no status_code)"

# -----------------------------------------------------------------------------
# Step 4 — Compare against threshold
# -----------------------------------------------------------------------------
# Use Python for float comparison — Bash does not handle decimals natively
THRESHOLD_BREACHED=$(python3 -c \
    "print('yes' if float('${ERROR_RATE}') > float('${THRESHOLD}') else 'no')")

if [[ "${THRESHOLD_BREACHED}" == "yes" ]]; then
    STATUS="ALERT"
    log "ALERT: Error rate ${ERROR_RATE}% exceeds threshold ${THRESHOLD}%"
else
    STATUS="OK"
    log "OK: Error rate ${ERROR_RATE}% is within threshold ${THRESHOLD}%"
fi

# -----------------------------------------------------------------------------
# Step 5 — Write structured summary to monitoring.log
# -----------------------------------------------------------------------------
# This file is the deliverable — archived by Jenkins and readable by Nia
# without any monitoring dashboard or tooling.
# -----------------------------------------------------------------------------
cat >> "${LOG_FILE}" <<SUMMARY

==========================================
OrFlow API — Error Rate Monitoring Summary
==========================================
Timestamp         : ${TIMESTAMP}
Namespace         : ${NAMESPACE}
Pod status        : ${POD_STATUS}
Log lines sampled : ${TAIL_LINES}
JSON lines parsed : ${TOTAL_REQUESTS}
Lines skipped     : ${SKIPPED}
------------------------------------------
Total requests    : ${TOTAL_REQUESTS}
Error count       : ${ERROR_COUNT} (status_code >= 400)
Error rate        : ${ERROR_RATE}%
Threshold         : ${THRESHOLD}%
------------------------------------------
Status            : ${STATUS}
==========================================

SUMMARY

log "Summary written to ${LOG_FILE}"

# -----------------------------------------------------------------------------
# Step 6 — Exit with appropriate code
# -----------------------------------------------------------------------------
# Exit 1 if threshold breached — Jenkins marks the stage as failed
# Exit 0 if within threshold — pipeline continues normally
# -----------------------------------------------------------------------------
if [[ "${THRESHOLD_BREACHED}" == "yes" ]]; then
    log "Exiting with status 1 — error rate above threshold"
    exit 1
fi

log "Exiting with status 0 — error rate within threshold"
exit 0