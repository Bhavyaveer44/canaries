import fakeredis
from fastapi.testclient import TestClient

from app import main

# Swap the real Redis client for an in-memory fake before any request
# hits it. This is what makes this a *unit* test: it verifies our
# code's logic without needing a live Redis container - fast enough
# to run on every push. Real Redis is exercised separately by the
# staging smoke test we'll add later, which is closer to an
# integration test.
main.r = fakeredis.FakeStrictRedis(decode_responses=True)

client = TestClient(main.app)


def test_health_ok():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_root_reports_service_name():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["service"] == "api-service"


def test_create_job_queues_payload():
    response = client.post("/jobs", json={"payload": "hello"})
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "queued"
    assert "job_id" in body

    # Confirm it actually landed on the queue, not just returned a
    # 200 - testing the side effect, not just the HTTP response shape.
    queued_raw = main.r.lpop("jobs")
    assert queued_raw is not None
