import json
import os
import time

import psycopg2
import redis

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql://postgres:postgres@postgres:5432/jobsdb"
)


def get_db_connection(retries=10, delay=2):
    """Containers start in parallel, so postgres might not be ready
    the instant the worker starts. This retry loop is a cheap version
    of what docker-compose 'depends_on: condition: service_healthy'
    solves properly (we'll wire that into the compose file)."""
    for attempt in range(retries):
        try:
            return psycopg2.connect(DATABASE_URL)
        except psycopg2.OperationalError:
            print(f"Postgres not ready, retry {attempt + 1}/{retries}...")
            time.sleep(delay)
    raise RuntimeError("Could not connect to Postgres")


def ensure_table(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS job_results (
                id UUID PRIMARY KEY,
                payload TEXT NOT NULL,
                result TEXT NOT NULL,
                processed_at TIMESTAMP DEFAULT now()
            )
            """
        )
        conn.commit()


def process(payload: str) -> str:
    """Stand-in for real work. Reversing the string is enough to
    prove data flowed api -> redis -> worker -> postgres."""
    return payload[::-1]


def main():
    r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    conn = get_db_connection()
    ensure_table(conn)
    print("worker-service started, waiting for jobs...")

    while True:
        """BLPOP blocks until a job is available instead of polling in
        a tight loop - cheaper on CPU and near-instant pickup."""
        _, raw_job = r.blpop("jobs")
        job = json.loads(raw_job)
        result = process(job["payload"])

        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO job_results (id, payload, result) VALUES (%s, %s, %s)",
                (job["id"], job["payload"], result),
            )
            conn.commit()

        print(f"processed job {job['id']}: {job['payload']} -> {result}")


if __name__ == "__main__":
    main()