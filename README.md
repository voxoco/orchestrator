# orchestrator
Orchestrator for MySQL replication topology management made to run globally in geo-distributed regions.

This repo includes 2 containers:
1. `orchestrator` - Includes sane production config tailored for Kubernetes
2. `sidecar` - Includes a `proxysql`, `mysql` and `orchestrator` sidecar script to manage the lifecycle of each application

Handles backups/restores using [go-mydumber](https://github.com/xelabs/go-mydumper), seamless master failover, and more.

The complimentary kubernetes manifests used to deploy this environment can be found [here](https://github.com/voxoco/k8s).