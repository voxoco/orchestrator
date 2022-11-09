#!/bin/sh

# LAST_RAFT_CHECK_TIME is the last time we checked raft follower status
LAST_RAFT_CHECK_TIME=$(date +%s)

exit_script() {
  echo "Tearing down..."
  trap - SIGINT SIGTERM # clear the trap

  LEADER=$(curl -s http://127.0.0.1:3000/api/raft-leader | jq -r . | sed 's/:.*//')
  echo "Removing this node $PODIP from leader ${LEADER}"
  curl -s http://$LEADER:3000/api/raft-remove-peer/$PODIP:10008
}

bootstrap() {
  echo "Bootstrapping..."

  # Make sure the web server responds with 200
  while ! curl -m 1 -s http://127.0.0.1:3000 > /dev/null; do
    echo "Waiting for Orchestrator web server to start..."
    sleep 1
  done

  # Make sure this node is actually online first
  while ! curl -m 1 -s http://127.0.0.1:3000/api/raft-status | jq -r .IsPartOfQuorum; do
    sleep 1
    echo "Waiting for node to be online and part of quorum"
  done

  echo "Checking if there is more than one node in the cluster"

  # Only continue if there is only one node in the cluster
  if [ "$(curl -m 1 -s http://127.0.0.1:3000/api/raft-status | jq -r '.Peers | length')" -gt "1" ]; then 
    echo "Cluster already bootstrapped, returning..."
    return
  fi

  echo "Sleeping for 5 seconds"
  sleep 5

  # Build array of alive orchestrator nodes by looping over the regions
  RAFT_LEADER=""
  for REGION in ${REGIONS}; do
    NODE="${HOSTNAME::-2}-${HOSTNAME##*-}.${HOSTNAME::-2}.$POD_NAMESPACE.svc.$REGION"
    HEALTHY=$(curl -m 1 -s http://$NODE:3000/api/raft-status)

    echo "Checking if $NODE is healthy"

    # Make sure we have some data before proceeding
    if [ -z "$HEALTHY" ]; then continue; fi

    # If the node is not part of the quorum, just skip it
    if ! echo $HEALTHY | jq -r .IsPartOfQuorum; then continue; fi

    # If we are here the node is healthy so check if it is this node
    if [ "$(echo $HEALTHY | jq -r .Leader | sed 's/:.*//')" == "$PODIP" ]; then continue; fi

    # Node is not this node and is part of the quorum, so it is the leader
    RAFT_LEADER=$(echo $HEALTHY | jq -r .Leader | sed 's/:.*//')
    
    # Add this node to the raft cluster
    echo "Adding this node to the raft cluster via leader: $RAFT_LEADER"
    curl -m 2 -s http://$RAFT_LEADER:3000/api/raft-add-peer/$PODIP:10008
    break

    # If we get here, something went wrong
    echo "Something is wrong.. No leader found?"
  done
}

check_healthy_raft() {
  echo "Checking if raft is healthy"

  # Orchestrator api becomes unresponsive it seems if time has passed and 'request-health-report' returns 500
  # So we need to check first if we are a follower and if so, check the 'health' endpoint of the leader
  # to make sure our IP is in the array of 'RaftHealthyMembers'
  # If not, we need to call the 'reelect' enpoint to force a new leader election (so the token is updated)

  # Check if we are a follower
  RAFT_STATUS=$(curl -m 1 -s http://127.0.0.1:3000/api/raft-status)
  if [ "$(echo $RAFT_STATUS | jq -r .State)" != "Follower" ]; then return; fi
  
  # Get the leader
  LEADER=$(echo $RAFT_STATUS | jq -r .Leader | sed 's/:.*//')
  echo "Checking if follower $PODIP is healthy in the raft cluster via leader: $LEADER"

  # Check to make sure our IP is in the array of 'RaftHealthyMembers' of the Leader
  if curl -m 1 -s http://$LEADER:3000/api/health | jq -r '.Details.RaftHealthyMembers[]' | grep -q $PODIP; then return; fi
  
  echo "Our IP is not in the array of 'RaftHealthyMembers' of the Leader, forcing a new leader election"
  curl -m 1 -s http://$LEADER:3000/api/reelect
}

# catch kill signals
trap exit_script SIGINT SIGTERM

# Bootstrap the cluster
bootstrap

while true; do
  sleep 1
  # Check raft follower status every minute
  if [ $(($(date +%s) - $LAST_RAFT_CHECK_TIME)) -gt 60 ]; then
    check_healthy_raft
    LAST_RAFT_CHECK_TIME=$(date +%s)
  fi
done