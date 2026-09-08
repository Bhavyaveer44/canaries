# CI/CD for Microservices — Reference Project

A minimal 2-service app (FastAPI `api` + Python `worker`, talking over Redis,
persisting to Postgres) used purely as a vehicle to build and explain a full
CI/CD pipeline: GitHub Actions → staging (docker-compose) → production
(blue-green **or** canary, both implemented).

## Project structure

```
services/
  api/            FastAPI service - accepts requests, queues jobs
  worker/         Consumes queue, writes results to Postgres
docker-compose.yml            local dev - builds images locally
docker-compose.staging.yml    staging - pulls prebuilt images from GHCR
docker-compose.prod.yml       prod - blue/green service pairs + nginx router
nginx/
  nginx.blue.conf / nginx.green.conf   single-upstream configs (blue-green)
  nginx.canary.conf.template           weighted upstream (canary stages)
  logging.conf                         per-backend request logging
scripts/
  deploy-blue-green.sh   instant-cutover deploy, health-gated
  deploy-canary.sh       staged (5/25/50/100%) rollout, error-rate gated
.github/workflows/ci.yml  test -> build&push -> staging -> prod (gated)
```

## Pipeline stages

1. **test** — matrix over `[api, worker]`, unit tests only (no live Redis/DB
   needed — fakeredis / pure functions).
2. **build-and-push** — multi-stage Docker builds, pushed to GHCR tagged
   `sha-<full commit sha>`. This exact tag is what flows through every later
   stage untouched.
3. **deploy-staging** — auto-deploys the new images to a staging VM over SSH,
   then runs a smoke test against `/health`.
4. **deploy-production** — gated behind a required-reviewer approval on the
   `production` GitHub Environment. Runs either `deploy-blue-green.sh` or
   `deploy-canary.sh` depending on the `deploy_strategy` input (manual
   `workflow_dispatch` trigger).

## One-time setup (not automated — do this yourself)

- Provision two VMs (or two directories on one box) for staging and prod,
  with Docker + the Compose plugin installed.
- On each: `mkdir -p /opt/cicd-microservices-demo`, generate an SSH keypair,
  add the public key to `~/.ssh/authorized_keys`.
- In GitHub repo Settings → Secrets and variables → Actions, add:
  `STAGING_HOST`, `STAGING_SSH_USER`, `STAGING_SSH_KEY`,
  `PROD_HOST`, `PROD_SSH_USER`, `PROD_SSH_KEY`.
- In Settings → Environments, create `staging` (no protections) and
  `production` (add yourself under **Required reviewers**).
- On the prod VM, before the very first deploy, seed
  `nginx/active.conf` as a copy of `nginx/nginx.blue.conf` — nginx needs
  *something* mounted there on first container start, before any deploy
  script has run to generate one.

## Known simplifications (be ready to name these in an interview)

- Canary error-rate detection greps nginx's own access log for the canary
  container's IP — a real system would use a metrics backend (Prometheus,
  Datadog) rather than log-scraping, especially across multiple nginx
  replicas.
- Blue-green/canary only ever duplicate the stateless tier (`api`, `worker`).
  Postgres is a singleton; schema changes need to be backward/forward
  compatible with both app versions during any cutover window — this repo
  doesn't implement migration tooling.
- Deploy target is a single VM via docker-compose, not Kubernetes. Compose
  has no built-in multi-node scheduling, self-healing, or rolling-update
  primitives — those are exactly what you'd reach for Kubernetes to get if
  this grew past one box.
