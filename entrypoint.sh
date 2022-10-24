#!/bin/bash

set -x

# Add config
cat <<EOF > /opt/orchestrator/orchestrator.conf.json
{
  "Debug": true,
  "EnableSyslog": false,
  "MySQLTopologyUser": "${ORC_TOPOLOGY_USER:-orchestrator}",
  "MySQLTopologyPassword": "${ORC_TOPOLOGY_PASSWORD:-orchestrator}",
  "MySQLTopologyCredentialsConfigFile": "",
  "MySQLTopologySSLSkipVerify": true,
  "MySQLTopologySSLPrivateKeyFile": "",
  "MySQLTopologySSLCertFile": "",
  "MySQLTopologySSLCAFile": "",
  "BackendDB": "sqlite",
  "SQLite3DataFile": "/opt/orchestrator/orchestrator.sqlite3",
  "DiscoverByShowSlaveHosts": true,
  "InstancePollSeconds": 5,
  "HostnameResolveMethod": "none",
  "MySQLHostnameResolveMethod": "",
  "ReplicationLagQuery": "",
  "DetectClusterAliasQuery": "select cluster_alias from meta.cluster where anchor=1",
  "DetectClusterDomainQuery": "select cluster_domain from meta.cluster where anchor=1",
  "DetectInstanceAliasQuery": "select instance_alias from meta.cluster where anchor=1",
  "DetectDataCenterQuery": "select dc from meta.cluster where anchor=1",
  "StatusSimpleHealth": true,
  "AutoPseudoGTID": true,
  "PseudoGTIDMonotonicHint": "asc:",
  "ApplyMySQLPromotionAfterMasterFailover": true,
  "RecoverMasterClusterFilters": [".*"],
  "RecoverIntermediateMasterClusterFilters": [".*"],
  "OnFailureDetectionProcesses": [
    "echo 'Detected {failureType} on {failureCluster}. Affected replicas: {countSlaves}' >> /tmp/recovery.log"
  ],
  "PreGracefulTakeoverProcesses": [
    "echo 'Planned takeover about to take place on {failureCluster}. Master will switch to read_only' >> /tmp/recovery.log"
  ],
  "PreFailoverProcesses": [
    "echo 'Will recover from {failureType} on {failureCluster}' >> /tmp/recovery.log"
  ],
  "PostFailoverProcesses": [
    "echo '(for all types) Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Successor: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostUnsuccessfulFailoverProcesses": [],
  "PostMasterFailoverProcesses": [
    "echo 'Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Promoted: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostIntermediateMasterFailoverProcesses": [
    "echo 'Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Successor: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostGracefulTakeoverProcesses": [
    "echo 'Planned takeover complete and started slave on {failedHost}' >> /tmp/recovery.log",
    "curl -s http://127.0.0.1:3000/api/start-slave/{failedHost}/3306"
  ],
  "DetachLostSlavesAfterMasterFailover": true,
  "MasterFailoverDetachReplicaMasterHost": false,
  "PostponeReplicaRecoveryOnLagMinutes": 0,
  "RaftEnabled": true,
  "RaftDataDir": "/opt/orchestrator",
  "RaftBind": "$PODIP",
  "DefaultRaftPort": 10008,
  "RaftNodes": [ "$PODIP" ]
}
EOF

cd /opt/orchestrator
exec ./orchestrator http