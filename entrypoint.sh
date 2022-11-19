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
  "UnseenInstanceForgetHours": 1,
  "RecoveryPeriodBlockSeconds": 600,
  "HostnameResolveMethod": "none",
  "MySQLHostnameResolveMethod": "",
  "ReplicationLagQuery": "",
  "CoMasterRecoveryMustPromoteOtherCoMaster": false,
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
    "echo 'Detected {failureType} on {failureCluster}. Affected replicas: {countSlaves}' >> /tmp/recovery.log",
    "/opt/orchestrator/slack.sh 'WARN' 'Detected {failureType} on {failureCluster}' 'Affected replicas: {countSlaves}'"
  ],
  "PreGracefulTakeoverProcesses": [
    "echo 'Planned takeover about to take place on {failureCluster}. Master will switch to read_only' >> /tmp/recovery.log",
    "/opt/orchestrator/slack.sh 'INFO' 'Planned takeover about to take place on {failureCluster}' 'Master will switch to read_only'"
  ],
  "PreFailoverProcesses": [
    "echo 'Will recover from {failureType} on {failureCluster}' >> /tmp/recovery.log",
    "/opt/orchestrator/slack.sh 'WARN' 'Pre failover running' 'Will recover from {failureType} on {failureCluster}'"
  ],
  "PostFailoverProcesses": [
    "echo '(for all types) Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Successor: {successorHost}:{successorPort}' >> /tmp/recovery.log",
    "/opt/orchestrator/slack.sh 'INFO' 'Post failover' 'Recovered from {failureType} on {failureCluster}\nFailed: {failedHost}:{failedPort}\nSuccessor: {successorHost}:{successorPort}'"
  ],
  "PostUnsuccessfulFailoverProcesses": [
    "echo 'Post Unsuccessful failover for {failedHost}' >> /tmp/recover.log",
    "/opt/orchestrator/slack.sh 'INFO' 'Post unsuccessful failover' 'Failed host: {failedHost}'"
  ],
  "PostMasterFailoverProcesses": [
    "echo 'Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Promoted: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostIntermediateMasterFailoverProcesses": [
    "echo 'Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Successor: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostGracefulTakeoverProcesses": [
    "echo 'Planned takeover complete' >> /tmp/recovery.log",
    "curl -s http://127.0.0.1:3000/api/start-slave/{failedHost}/3306",
    "/opt/orchestrator/slack.sh 'INFO' 'Planned takeover complete' 'Success status: {isSuccessful}\nNew master: {successorAlias}\nNew replica count: {countReplicas}'"
  ],
  "DetachLostSlavesAfterMasterFailover": true,
  "MasterFailoverDetachReplicaMasterHost": false,
  "PostponeReplicaRecoveryOnLagMinutes": 0,
  "KVClusterMasterPrefix": "mysql/master",
  "ConsulAddress": "${CONSUL_HTTP_ADDR:-127.0.0.1:8500}",
  "ConsulScheme": "https",
  "ConsulAclToken": "${CONSUL_HTTP_TOKEN}",
  "RaftEnabled": true,
  "RaftDataDir": "/opt/orchestrator",
  "RaftBind": "$PODIP",
  "DefaultRaftPort": 10008,
  "RaftNodes": [ "$PODIP" ]
}
EOF

cd /opt/orchestrator
exec ./orchestrator http