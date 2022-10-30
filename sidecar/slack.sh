#!/bin/bash

# Send notification messages to a slack channel
# Slack webhook URL should be an env variable named SLACK_WEBHOOK_URL

# SLACK_CHANNEL is optional, defaults to "alarms"
SLACK_CHANNEL=${SLACK_CHANNEL:-alarms}

# Input params:
# $1 - message level: "INFO" | "WARN" | "ERROR"
# $2 - pretext
# $3 - message

# Set colors
COLOR="good"
if [ "$1" == "ERROR" ]; then COLOR="danger"; fi
if [ "$1" == "WARN" ]; then COLOR="warning"; fi

# Set message
MESSAGE="payload={\"channel\": \"#$SLACK_CHANNEL\",\"attachments\":[{\"author_name\":\"orchestrator\",\"pretext\":\"$2\",\"text\":\"$3\",\"color\":\"$COLOR\"}]}"

# Send message
curl -X POST --data-urlencode "$MESSAGE" ${SLACK_WEBHOOK_URL}
