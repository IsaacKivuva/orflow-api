import sys
import json

total_requests = 0
error_count    = 0
skipped_lines  = 0

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        skipped_lines += 1
        continue

    if "status_code" not in entry:
        continue

    total_requests += 1

    status_code = entry.get("status_code", 0)
    if isinstance(status_code, int) and status_code >= 400:
        error_count += 1

if total_requests == 0:
    print("TOTAL_REQUESTS=0")
    print("ERROR_COUNT=0")
    print("ERROR_RATE=0.00")
    print(f"SKIPPED={skipped_lines}")
else:
    error_rate = (error_count / total_requests) * 100
    print(f"TOTAL_REQUESTS={total_requests}")
    print(f"ERROR_COUNT={error_count}")
    print(f"ERROR_RATE={error_rate:.2f}")
    print(f"SKIPPED={skipped_lines}")