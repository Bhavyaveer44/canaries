#!/usr/bin/env bash
set -euo pipefail

# Required env vars, passed in by the CI job that invokes this script:
#   IMAGE_NAMESPACE   e.g. ghcr.io/yourname/cicd-microservices-demo
#   NEW_TAG           the freshly built, already-staging-tested image tag
: "${IMAGE_NAMESPACE:?must be set}"
: "${NEW_TAG:?must be set}"

STATE_FILE="deploy-state.env"
COMPOSE="docker compose -f docker-compose.prod.yml"

# --- 1. Figure out which color is live right now ---
# Defaults to blue on a fresh server with nothing deployed yet.
CURRENT_COLOR="blue"
BLUE_TAG=""
GREEN_TAG=""
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
fi

if [ "$CURRENT_COLOR" = "blue" ]; then
    IDLE_COLOR="green"
else
    IDLE_COLOR="blue"
fi

echo "Currently live: $CURRENT_COLOR. Deploying $NEW_TAG to idle color: $IDLE_COLOR"

# --- 2. Point the idle color's tag at the new image, keep the live
#        color's tag exactly as it was (that's our rollback target) ---
if [ "$IDLE_COLOR" = "blue" ]; then
    BLUE_TAG="$NEW_TAG"
else
    GREEN_TAG="$NEW_TAG"
fi

cat > .env <<EOF
IMAGE_NAMESPACE=${IMAGE_NAMESPACE}
BLUE_TAG=${BLUE_TAG}
GREEN_TAG=${GREEN_TAG}
EOF

# --- 3. Bring up ONLY the idle color. The live color, and nginx, are
#        untouched and keep serving traffic the entire time. ---
$COMPOSE --profile "$IDLE_COLOR" pull "api-$IDLE_COLOR" "worker-$IDLE_COLOR"
$COMPOSE --profile "$IDLE_COLOR" up -d "api-$IDLE_COLOR" "worker-$IDLE_COLOR"

# --- 4. Health-check the idle color directly, INSIDE the compose
#        network - never through nginx, since nginx isn't pointed at
#        it yet. This is the actual go/no-go gate for the release. ---
echo "Health-checking $IDLE_COLOR before sending it any real traffic..."
HEALTHY=false
for i in $(seq 1 15); do
    if $COMPOSE exec -T "api-$IDLE_COLOR" python -c \
        "import urllib.request,sys; sys.exit(0 if b'\"status\":\"ok\"' in urllib.request.urlopen('http://localhost:8000/health').read() else 1)" \
        2>/dev/null; then
        HEALTHY=true
        break
    fi
    echo "  ...not healthy yet ($i/15)"
    sleep 3
done

if [ "$HEALTHY" != "true" ]; then
    echo "$IDLE_COLOR failed its health check. Rolling back: tearing it down, leaving $CURRENT_COLOR live."
    $COMPOSE --profile "$IDLE_COLOR" stop "api-$IDLE_COLOR" "worker-$IDLE_COLOR"
    exit 1
fi

# --- 5. Flip traffic. `nginx -s reload` re-reads config gracefully -
#        it finishes in-flight requests on the old upstream and sends
#        every NEW connection to the new one. No dropped connections,
#        no downtime window. ---
echo "$IDLE_COLOR is healthy. Flipping nginx to $IDLE_COLOR..."
cp "nginx/nginx.$IDLE_COLOR.conf" nginx/active.conf
$COMPOSE exec -T nginx nginx -s reload

# --- 6. Persist the new live color so the NEXT deploy knows which
#        side is idle. ---
cat > "$STATE_FILE" <<EOF
CURRENT_COLOR=${IDLE_COLOR}
BLUE_TAG=${BLUE_TAG}
GREEN_TAG=${GREEN_TAG}
EOF

# --- 7. Stop (don't remove) the now-old color. Stopped containers
#        keep their image cached locally, so rolling back is just:
#        flip nginx back, `docker compose --profile <old> start`. ---
echo "Stopping old color: $CURRENT_COLOR"
$COMPOSE --profile "$CURRENT_COLOR" stop "api-$CURRENT_COLOR" "worker-$CURRENT_COLOR"

echo "Blue-green deploy complete. Live color is now: $IDLE_COLOR ($NEW_TAG)"
