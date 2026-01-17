#!/bin/sh
# Auto-stop monitor - Stops EC2 instance after idle period
# Runs inside Docker container, monitors OpenRAG API activity

IDLE_THRESHOLD=${AUTO_STOP_IDLE_SECONDS:-900}  # 15 minutes default
CHECK_INTERVAL=60  # Check every minute
OPENRAG_URL="http://openrag:8080"
LAST_ACTIVITY_FILE="/tmp/last_activity"

echo "Auto-stop monitor started"
echo "Idle threshold: ${IDLE_THRESHOLD}s"
echo "Check interval: ${CHECK_INTERVAL}s"

# Initialize last activity
date +%s > "$LAST_ACTIVITY_FILE"

while true; do
    sleep "$CHECK_INTERVAL"

    # Check if OpenRAG has had recent activity via metrics endpoint
    RESPONSE=$(curl -sf "${OPENRAG_URL}/metrics" 2>/dev/null || echo "")

    if [ -n "$RESPONSE" ]; then
        # Parse request count from metrics (if available)
        # Or just use health check success as activity indicator
        HEALTH=$(curl -sf "${OPENRAG_URL}/health" 2>/dev/null)

        if [ -n "$HEALTH" ]; then
            # Check for recent requests by looking at logs or metrics
            # For simplicity, we'll update activity on any successful health check
            # In production, you'd parse actual request metrics

            # Check if there were recent API calls (simplified check)
            RECENT_LOGS=$(docker logs openrag --since 1m 2>&1 | grep -c "POST\|GET" || echo "0")

            if [ "$RECENT_LOGS" -gt 0 ]; then
                echo "Activity detected ($RECENT_LOGS requests in last minute)"
                date +%s > "$LAST_ACTIVITY_FILE"
            fi
        fi
    fi

    # Calculate idle time
    LAST_ACTIVITY=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || date +%s)
    NOW=$(date +%s)
    IDLE_TIME=$((NOW - LAST_ACTIVITY))

    echo "Idle time: ${IDLE_TIME}s / ${IDLE_THRESHOLD}s"

    if [ "$IDLE_TIME" -ge "$IDLE_THRESHOLD" ]; then
        echo "Idle threshold reached, initiating shutdown..."

        # Get instance ID from metadata
        INSTANCE_ID=$(curl -sf http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")

        if [ -n "$INSTANCE_ID" ]; then
            echo "Stopping instance: $INSTANCE_ID"

            # Send CloudWatch metric before stopping
            aws cloudwatch put-metric-data \
                --namespace "OpenRAG" \
                --metric-name "AutoStop" \
                --value 1 \
                --unit Count \
                2>/dev/null || true

            # Stop the instance
            aws ec2 stop-instances --instance-ids "$INSTANCE_ID" 2>/dev/null

            echo "Stop command sent, exiting monitor"
            exit 0
        else
            echo "Could not get instance ID, skipping auto-stop"
        fi
    fi
done
