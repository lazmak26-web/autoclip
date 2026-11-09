#!/usr/bin/env bash
# Production image entrypoint; database creation shares the supported backend path.
set -euo pipefail
cd /app
export PYTHONPATH=/app PYTHONUNBUFFERED=1
mkdir -p data/projects data/uploads data/temp data/output logs
python init_database.py
# Wait for the broker instead of failing on the first try: on hosts like Railway the
# Redis service can come up (or resolve over the private network) a few seconds
# after this container does. AUTOCLIP_REDIS_WAIT is the total wait in seconds.
python - <<'PY'
import os
import sys
import time
import redis

url = os.getenv('REDIS_URL', 'redis://redis:6379/0')
deadline = time.time() + int(os.getenv('AUTOCLIP_REDIS_WAIT', '60'))
while True:
    try:
        redis.Redis.from_url(url, socket_connect_timeout=5, socket_timeout=5).ping()
        break
    except Exception as error:
        if time.time() >= deadline:
            print(f'Redis unavailable ({type(error).__name__}); Celery requires a working broker.', file=sys.stderr)
            sys.exit(1)
        time.sleep(2)
print('Redis connected')
PY
# Single-container hosts (Railway: volumes cannot be shared between services) run the
# Celery worker next to the API. docker-compose keeps its separate worker service.
if [ "${AUTOCLIP_START_WORKER:-0}" = "1" ]; then
    celery -A backend.core.celery_app worker --loglevel=info \
        --concurrency="${AUTOCLIP_WORKER_CONCURRENCY:-2}" \
        -Q celery,processing,video,notification,upload &
fi
exec "$@"
