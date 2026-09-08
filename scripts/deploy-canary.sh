#!/usr/bin/env bash
set -euo pipefail

# Required env vars, same as the blue-green script:
#   IMAGE_NAMESPACE   e.g. ghcr.io/yourname/cicd-microservices-demo
#   NEW_TAG           the freshly built, already-staging-tested image tag
# Optional:
#   SOAK_SECONDS      how long to watch each stage before deciding
#                      (default 30s here for a demo; real deployments
#                      would use minutes to hours per stage)
#   ERROR_THRESHOLD   max acceptable error rate per stage, as a
#                      percentage (default 5)
: "${IMAGE_NAMESPACE:?must be set}"
: "${NEW_TAG:?must be set}"
SOAK_SECONDS="${SOAK_SECONDS:-30}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-5}"
STAGES=(5 25 50 100)

STATE_FILE="deploy-state.env"
COMPOSE="docker compose -f docker-compose.prod.yml"

# --- 1. Same idle-color determination as blue-green ---
CURRENT_COLOR="blue"
BLUE_TAG=""
GREEN_TAG=""
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
fi
if [ "$CURRENT_COLOR" = "blue" ]; then IDLE_COLOR="green"; else IDLE_COLOR="blue"; fi
echo "Stable: $CURRENT_COLOR. Canary target: $IDLE_COLOR -> $NEW_TAG"

if [ "$IDLE_COLOR" = "blue" ]; then BLUE_TAG="$NEW_TAG"; else GREEN_TAG="$NEW_TAG"; fi
cat > .env <<EOF
IMAGE_NAMESPACE=${IMAGE_NAMESPACE}
BLUE_TAG=${BLUE_TAG}
GREEN_TAG=${GREEN_TAG}
EOF

# --- 2. Bring up the canary containers, but nginx isn't pointed at
#        them yet - identical starting point to blue-green. ---
$COMPOSE --profile "$IDLE_COLOR" pull "api-$IDLE_COLOR" "worker-$IDLE_COLOR"
$COMPOSE --profile "$IDLE_COLOR" up -d "api-$IDLE_COLOR" "worker-$IDLE_COLOR"

# --- 3. Resolve the canary container's IP on the compose network.
#        nginx logs $upstream_addr as an IP:port, not a service name,
#        so this is how we later tell "which log lines were the
#        canary's" apart from the stable version's. ---
CANARY_IP=$($COMPOSE exec -T "api-$IDLE_COLOR" hostname -i | tr -d '[:space:]')
if [ -z "$CANARY_IP" ]; then
    echo "Could not resolve canary container IP, aborting."
    $COMPOSE --profile "$IDLE_COLOR" stop "api-$IDLE_COLOR" "worker-$IDLE_COLOR"
    exit 1
fi
echo "Canary ($IDLE_COLOR) is at $CANARY_IP"

rollback() {
    echo "Rolling back: restoring 100% traffic to $CURRENT_COLOR, stopping $IDLE_COLOR."
    cp "nginx/nginx.$CURRENT_COLOR.conf" nginx/active.conf
    $COMPOSE exec -T nginx nginx -s reload
    $COMPOSE --profile "$IDLE_COLOR" stop "api-$IDLE_COLOR" "worker-$IDLE_COLOR"
}

# --- 4. Walk the traffic stages ---
for STAGE in "${STAGES[@]}"; do
    STABLE_WEIGHT=$((100 - STAGE))
    CANARY_WEIGHT=$STAGE
    echo "--- Stage: ${STAGE}% to canary ($IDLE_COLOR), ${STABLE_WEIGHT}% to stable ($CURRENT_COLOR) ---"

    if [ "$STAGE" -lt 100 ]; then
        sed -e "s/__STABLE_COLOR__/${CURRENT_COLOR}/g" \
            -e "s/__CANARY_COLOR__/${IDLE_COLOR}/g" \
            -e "s/__STABLE_WEIGHT__/${STABLE_WEIGHT}/g" \
            -e "s/__CANARY_WEIGHT__/${CANARY_WEIGHT}/g" \
            nginx/nginx.canary.conf.template > nginx/active.conf
    else
        # 100% stage = full cutover, same clean single-upstream conf
        # blue-green uses. No point weighting traffic to a 0% stable
        # backend.
        cp "nginx/nginx.$IDLE_COLOR.conf" nginx/active.conf
    fi
    $COMPOSE exec -T nginx nginx -s reload

    echo "Soaking for ${SOAK_SECONDS}s to collect real traffic..."
    sleep "$SOAK_SECONDS"

    # --- 5. Compute the canary's error rate from THIS stage's
    #        traffic only, by grepping nginx's log for its IP. ---
    LOG_LINES=$($COMPOSE exec -T nginx sh -c "grep '$CANARY_IP' /var/log/nginx/canary.log | tail -n 500" || true)
    TOTAL=$(echo "$LOG_LINES" | grep -c . || true)
    ERRORS=$(echo "$LOG_LINES" | grep -cE 'status=5[0-9]{2}' || true)

    if [ "$TOTAL" -eq 0 ]; then
        echo "No traffic reached the canary yet this stage - treating as pass (nothing to fail on)."
        continue
    fi

    ERROR_RATE=$(( ERRORS * 100 / TOTAL ))
    echo "Canary saw $TOTAL requests, $ERRORS errors -> ${ERROR_RATE}% error rate (threshold: ${ERROR_THRESHOLD}%)"

    if [ "$ERROR_RATE" -gt "$ERROR_THRESHOLD" ]; then
        echo "Canary error rate exceeded threshold. Aborting rollout."
        rollback
        exit 1
    fi
done

# --- 6. Every stage passed and we're at 100% - finalize exactly like
#        blue-green: persist state, retire the old version. ---
cat > "$STATE_FILE" <<EOF
CURRENT_COLOR=${IDLE_COLOR}
BLUE_TAG=${BLUE_TAG}
GREEN_TAG=${GREEN_TAG}
EOF
echo "Stopping old stable: $CURRENT_COLOR"
$COMPOSE --profile "$CURRENT_COLOR" stop "api-$CURRENT_COLOR" "worker-$CURRENT_COLOR"

echo "Canary rollout complete. Stable is now: $IDLE_COLOR ($NEW_TAG)"
