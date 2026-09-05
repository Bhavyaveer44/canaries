import json
import os
import uuid

import redis
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="api-service")

"""
Service discovery via docker-compose: "redis" is the container's service name,
docker-compose puts every service on the same virtual network, 
so containers reach each other by service name instead of an IP address/localhost.
"""
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


class JobRequest(BaseModel):
    payload: str


@app.get("/health")
def health():
    """Health check endpoint. CI/CD pipelines and load balancers hit
    this to decide if a container is ready to receive traffic."""
    try:
        r.ping()
        return {"status": "ok", "redis": "connected"}
    except redis.exceptions.ConnectionError:
        return {"status": "degraded", "redis": "unreachable"}


@app.post("/jobs")
def create_job(job: JobRequest):
    """Accepts work and hands it off to the queue instead of doing it inline. 
    Core microservices idea: the api-service stays fast and only responsible for 
    accepting requests; the worker-service, a separate deployable unit, does the slow part."""
    job_id = str(uuid.uuid4())
    r.rpush("jobs", json.dumps({"id": job_id, "payload": job.payload}))
    return {"job_id": job_id, "status": "queued"}


@app.get("/")
def root():
    return {"service": "api-service", "version": os.getenv("APP_VERSION", "dev")}