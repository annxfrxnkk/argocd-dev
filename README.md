# Kubernetes Repository

Source of truth for the SciGames Kubernetes cluster.
Replaces `/root/k8s/` on `sgkube-control101`. Structured for ArgoCD GitOps.

## Structure

```plaintext
.
├── apps/
│   ├── helm/                          # Helm-deployed apps (values overrides only)
│   │   └── <release-name>/
│   │       ├── Chart.yaml             # upstream repo URL, chart name, pinned version
│   │       ├── values.yaml            # primary values override
│   │       └── values-<variant>.yaml  # optional alternative values
│   └── manifests/                     # Plain-YAML apps and post-Helm extras
│       └── <app-name>/
│           ├── <resource>.yaml        # Kubernetes resources
│           └── <name>.yaml.example    # secret template (CHANGE_ME placeholders)
├── argo/                              # ArgoCD Application / ApplicationSet CRDs
├── infra/                             # cluster-level config, not managed by ArgoCD
│   ├── k3s/                           # K3s node config (registries, ...)
│   └── tls/                           # wildcard cert rotation tooling
├── README.md
└── .gitignore
```

## Naming Rules

- Lowercase with hyphens. Never underscores in directory or file names.
- Helm dirs match the **Helm release name**: release `vault-ha` -> dir `vault-ha/`.
- Manifest dirs match the **logical app name**: shared vault resources -> `manifests/vault/`.
- Kubernetes resource names: `<app>-<type>` (`awx-ingress`, `filebrowser-service`).
- Namespace names: plain noun (`harbor`, `vault`) or `<app>-system` for operators (`cnpg-system`).
- One application per namespace. Never mix unrelated workloads.
- File extension: `.yaml` for new files. Existing `.yml` is fine, don't rename.
- Shell scripts: `<verb>-<subject>.sh` (`update-wildcard-cert.sh`).
- Secret templates: `<name>.yaml.example` with `CHANGE_ME` placeholder values.

## Cluster

| Property | Value |
|----------|-------|
| Distribution | K3s v1.34.3 (HA, embedded etcd) |
| Nodes | 3x control-plane, no dedicated workers |
| OS | RHEL 9.5 |
| CNI | Calico (IPIP, pod CIDR 172.31.0.0/16) |
| Service CIDR | 10.43.0.0/16 |
| Load Balancer | MetalLB L2, VIP 10.11.70.50 |
| Ingress | Traefik v3 (DaemonSet) |
| Storage | Longhorn (distributed block, default StorageClass) |
| TLS | Wildcard *.scigames.at (HostEurope) |
| Container Runtime | containerd 2.1.5-k3s1 |
| Docker Cache | Harbor proxy via `infra/k3s/registries.yaml` |

## Deployed Services

| Service | Namespace | Type | Chart / Version | Ingress |
|---------|-----------|------|-----------------|---------|
| ArgoCD | argocd | manifests | - | argo.scigames.at |
| AWX | awx | helm + manifests | awx-operator 3.2.0 | awx.scigames.at |
| Calico | - (cluster-scoped) | manifests | - | - |
| CloudNativePG | cnpg-system | helm + manifests | cloudnative-pg 0.27.1 | - |
| FileBrowser | filebrowser | manifests | - | files.scigames.at |
| GitLab Runner | gitlab-runner | helm + manifests | gitlab-runner 0.85.0 | - |
| Harbor | harbor | helm + manifests | harbor 1.18.2 | harbor.scigames.at |
| Longhorn | longhorn-system | helm + manifests | longhorn 1.11.0 | long.scigames.at |
| MetalLB | metallb-system | helm + manifests | metallb 0.15.3 | - |
| SeaweedFS | seaweedfs | helm + manifests | seaweedfs 4.0.413 | s3.scigames.at |
| Snipe-IT | snipeit | helm (ArgoCD) | snipeit 3.4.1 | snipeit.scigames.at |
| PostgreSQL (CNPG) | cnpg-system | manifests | pg cluster (3 instances) | - |
| Traefik | traefik-system | helm + manifests | traefik 39.0.1 | - |
| Valkey | valkey | helm + manifests | valkey 5.2.0 | - |
| Vault HA | vault | helm + manifests | vault 0.32.0 | vault.scigames.at |
| Vault Transit | vault | helm | vault 0.32.0 | - |

## Adding New Content

### New Helm app

- Create `apps/helm/<release-name>/`.
- Add `Chart.yaml` with the upstream repo, chart name, and pinned version in comments.
- Add `values.yaml` containing only overrides (not a full defaults dump).
- If the chart does not create everything (custom Ingress, ConfigMap, RBAC), add extras under `apps/manifests/<app-name>/`.

### New manifest app

- Create `apps/manifests/<app-name>/`.
- Every resource must have explicit `metadata.namespace`.
- Simple apps: single file with `---` separators is fine.
- Complex apps: split by resource type (`deployment.yaml`, `service.yaml`, ...).
- Images must be pinned to a version tag. Never `:latest`.
- StorageClass must be `longhorn`, always explicit. Exception: SeaweedFS uses `local-path` for performance (latency-sensitive volume/master data that must stay node-local).

### New Ingress

Every Ingress follows this template. Traefik handles SSL redirect globally
(web entrypoint redirects to websecure). The shared retry middleware provides
HA failover across backends.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app>-ingress
  namespace: <namespace>
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: traefik-system-retry@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - <subdomain>.scigames.at
    secretName: wildcard-scigames
  rules:
  - host: <subdomain>.scigames.at
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: <service-name>
            port:
              number: <port>
```

For session stickiness add:
```yaml
traefik.ingress.kubernetes.io/service.sticky.cookie: "true"
traefik.ingress.kubernetes.io/service.sticky.cookie.name: route
```

### New secret

- Never commit real credentials. The `.gitignore` blocks `**/secrets/`, `*.key`, `*.pfx`.
- Create a `.yaml.example` file next to the manifest that references the secret.
- Use `CHANGE_ME` as the placeholder value for every sensitive field.
- When ArgoCD is active, migrate to Vault + External Secrets Operator.

### New infra script

- Place in `infra/` or a subdirectory (`infra/tls/`, `infra/k3s/`).
- Start with `#!/bin/bash` and `set -euo pipefail`.
- Must be idempotent (safe to run twice).
- Use `--dry-run=client -o yaml | kubectl apply -f -` for secret creation.
- Runtime secrets go in a local `secrets/` directory (gitignored).

### Chart version upgrade

1. Update `targetRevision` in the `Chart.yaml` comments.
2. Adjust `values.yaml` if the new version has breaking changes.

## Chart.yaml Format

Every Helm app has a `Chart.yaml` that doubles as the ArgoCD source reference:

```yaml
apiVersion: v2
name: <release-name>
description: <One line> Helm deployment
type: application
version: 0.1.0

# Helm source reference for ArgoCD
# repo: <upstream-helm-repo-url>
# chart: <chart-name>
# targetRevision: <chart-version>
```

The commented block is the single source of truth for which upstream chart version is deployed.

## YAML Conventions

- 2-space indent, no tabs.
- `---` between multiple documents in one file.
- Quote strings with special chars: `"5s"`, `"0"`, `"true"`.
- Resource order within a file: Namespace, RBAC, ConfigMap/Secret, PVC, Deployment, Service, Ingress.
- Labels: at minimum `app: <app-name>` on custom workloads, matching selectors.

## ArgoCD

ArgoCD is deployed in the `argocd` namespace and exposed at `argo.scigames.at`.
The `argo/` directory holds Application and ApplicationSet CRDs for GitOps-managed workloads.

| Directory | ArgoCD source type |
|-----------|--------------------|
| `apps/helm/<app>/` | `helm` (external chart repo + values from this repo) |
| `apps/manifests/<app>/` | `directory` (this git repo, path-based) |
| `argo/` | bootstrapped directly or via app-of-apps |

## High Availability

Each control-plane node runs on separate physical hardware. Goal: any single node
can die without service interruption.

### Failover Timing

K3s is configured for aggressive failover via `/etc/rancher/k3s/config.yaml`:

| Parameter | Value | Effect |
|-----------|-------|--------|
| `node-monitor-period` | 2s | How often kubelet health is checked |
| `node-monitor-grace-period` | 16s | Time before a node is marked NotReady |
| `default-not-ready-toleration-seconds` | 30s | Pod eviction delay after NotReady |
| `default-unreachable-toleration-seconds` | 30s | Pod eviction delay after Unreachable |

Total worst-case failover: ~46s (detection) + pod startup time.

### Longhorn Storage HA

All volumes maintain 3 replicas across nodes. Key settings in `apps/helm/longhorn/values.yaml`:

| Setting | Value | Purpose |
|---------|-------|---------|
| `nodeDownPodDeletionPolicy` | `delete-both-statefulset-and-deployment-pod` | Force-delete pods on dead nodes so they reschedule |
| `replicaAutoBalance` | `best-effort` | Rebalance replicas when nodes join/leave |
| `defaultDataLocality` | `best-effort` | Prefer placing a replica on the workload's node |

### Topology Spread

All multi-replica workloads use `topologySpreadConstraints` with `maxSkew: 1` and
`whenUnsatisfiable: DoNotSchedule` on `kubernetes.io/hostname` to guarantee pods
spread across all 3 nodes. Applies to: CoreDNS, Harbor (core, registry, portal,
jobservice), AWX, MetalLB speaker (DaemonSet), Traefik (DaemonSet), Valkey.

### PodDisruptionBudgets

PDBs prevent voluntary disruptions (rolling upgrades, node drain) from taking down
too many replicas at once:

| PDB | minAvailable | Workload |
|-----|-------------|----------|
| `awx-web-pdb` | 2 | AWX web pods |
| `awx-task-pdb` | 2 | AWX task pods |
| `harbor-core-pdb` | 2 | Harbor API/auth core |
| `harbor-registry-pdb` | 2 | Harbor container registry |
| `harbor-portal-pdb` | 1 | Harbor web UI |
| `harbor-jobservice-pdb` | 2 | Harbor async jobs |

### Non-HA Components

| Component | Reason | Mitigation |
|-----------|--------|------------|
| FileBrowser | Single-instance app, RWO PVC | Probes + Recreate strategy + fast reschedule via Longhorn policy |
| GitLab Runner | Stateless job executor | Pods reschedule automatically |
| MetalLB controller | Singleton by design (no leader election, multiple instances cause IP conflicts) | Speaker DaemonSet provides per-service HA via leader election among speakers |

## Infrastructure Scripts

| Script | Purpose |
|--------|---------|
| `infra/vault-setup.sh` | Full Vault bootstrap (transit + HA + auto-unseal) |
| `infra/tls/update-wildcard-cert.sh` | Rotate wildcard TLS cert across all namespaces |
| `infra/fix-default-storageclass.sh` | Remove default annotation from local-path (Longhorn is default) |
| `infra/k3s/coredns-ha.yaml` | HelmChartConfig: CoreDNS 3 replicas + topology spread |
| `infra/k3s/registries.yaml` | Harbor docker.io proxy mirror for k3s |

## Access

SSH to any control node (10.11.70.51–53) as root.
Never make changes directly on the hosts. This repository is the source of truth.

## Related Docs

- TLS certificate management: `infra/tls/README-TLS.md`
- Machine-readable project context: `CLAUDE.md` (local only, not tracked in git)
