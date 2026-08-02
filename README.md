# K8sDoctor

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Language: Shell](https://img.shields.io/badge/language-Bash-yellow.svg)](#)

K8sDoctor is a small, focused Kubernetes incident diagnostics tool for SREs and DevOps engineers. It scans a cluster for unhealthy pods and automatically collects targeted diagnostics (describe, per-container logs, events filtered to the pod, and the pod YAML) into a timestamped incident folder.

---

## Why use K8sDoctor

- Fast, zero-dependency incident bundle generation using only Bash + kubectl.
- Per-container logs (current + previous) collected alongside pod describe, events filtered to the pod, and YAML manifest.
- SRE-focused: outputs a complete incident folder suitable for attaching to incident reports or storing in runbooks.
- Lightweight and easy to run from your laptop, bastion, or a temporary container inside the cluster.

---

## Highlights

- Single entrypoint: `scripts/k8sdoctor.sh`
- Saves incident bundles under `reports/incident_<namespace>_<pod>_<timestamp>/`
- Per-incident files: `summary.txt`, `describe.txt`, `pod.yaml`, `events.txt`, `containers/*` (per-container logs), `cluster_info/*`
- Supports filtering to namespace and pod, and log windows via `--since`.

---

## Quickstart (3 steps)

1. Ensure you have kubectl configured and access to the target cluster:

```bash
kubectl config current-context
```

2. Make the script executable and run the cluster scan:

```bash
git clone https://github.com/sreeram91/K8sDoctor.git
cd K8sDoctor
chmod +x scripts/k8sdoctor.sh
./scripts/k8sdoctor.sh
```

3. Inspect the generated incident folders under `reports/`.

---

## Usage & Options

Run the script with optional flags to scope the scan or tune log collection:

```bash
./scripts/k8sdoctor.sh [ -n NAMESPACE ] [ -p POD ] [ -o DIR ] [ -s SINCE ]
```

Options:

- `-n NAMESPACE` — only scan this namespace (default: all namespaces)
- `-p POD`       — only inspect the pod with this name (use with `-n` to target a namespaced pod)
- `-o DIR`       — output directory (default: `./reports`)
- `-s SINCE`     — pass to `kubectl logs --since` to limit logs (e.g. `30m`, `1h`)
- `-h`           — show help

Examples:

```bash
# Full cluster scan
./scripts/k8sdoctor.sh

# Scan a single namespace
./scripts/k8sdoctor.sh -n production

# Inspect a single pod and save to /tmp/reports
./scripts/k8sdoctor.sh -n production -p payment-api -o /tmp/reports

# Only collect logs from the last 30 minutes
./scripts/k8sdoctor.sh -s 30m
```

---

## Output layout

Each incident folder follows the pattern:

```
reports/
  incident_<namespace>_<pod>_<timestamp>/
    summary.txt                # brief incident summary + collected files list (includes RUN_TS)
    describe.txt               # kubectl describe pod
    pod.yaml                   # kubectl get pod -o yaml
    events.txt                 # events filtered to this pod
    containers/                # per-container logs
      <container>_logs.txt
      <container>_previous_logs.txt
    cluster_info/              # kubectl client version & nodes information
      kubectl_client_version.txt
      nodes.txt
```

Note: the script collects the kubectl client version and the node list under `cluster_info/`. It does not collect a separate `cluster_version.txt` file.

The `summary.txt` is designed to give a quick overview for the incident responder; the rest of the files contain the raw outputs you would normally gather manually.

---

## Permissions (RBAC)

The script requires a user/service account with the following permissions across the target namespaces (or cluster-wide):

- pods: get, list, watch
- pods/log: get
- events: get, list
- nodes: get, list

If you want to run K8sDoctor from inside the cluster (recommended for automation), create a minimal ClusterRole/ClusterRoleBinding granting the above verbs. I can provide a sample manifest if you want.

---

## SRE tips for using the reports

- Attach the incident folder to your ticket or postmortem; the folder contains everything auditors and on-call engineers need to reproduce the incident timeline.
- Use `pod.yaml` to recreate the failing pod in a safe test namespace for replay.
- Use per-container `previous_logs` when diagnosing CrashLoopBackOff and container restarts.
- Store compressed incident bundles (tar.gz) for long-term retention if you maintain incident history.

---

## Roadmap (short-term SRE additions)

- Root-cause heuristics in `summary.txt` to highlight likely causes (image pull errors, crash exit codes, OOMKilled hints).
- Label/regex filtering so teams can scan only their apps.
- Optional redaction for secrets before saving manifests/logs.
- Optional compression and retention options for older reports.

---

## Contributing

Contributions are welcome — raise issues or PRs. If you want a small, focused change (RBAC manifest, label filters, or heuristics), open an issue describing the desired behavior and I'll implement it.

---

## License

MIT — see the LICENSE file.
