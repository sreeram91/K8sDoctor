#!/usr/bin/env bash
set -Eeuo pipefail

# K8sDoctor: lightweight Kubernetes incident diagnostics.
# This script is meant for production use: it fails fast on missing
# dependencies, uses explicit paths, and keeps output easy to parse.

# Base directory is one level above this script.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
REPORT_DIR="$BASE_DIR/reports"
NAMESPACE=""
POD=""
SINCE=""

# Print help text and supported CLI options.
usage() {
  cat <<EOF
K8sDoctor - Kubernetes incident diagnostics

Usage: $(basename "$0") [options]
  -n NAMESPACE   scan one namespace
  -p POD         scan one pod
  -o DIR         output directory (default: $REPORT_DIR)
  -s SINCE       pass to kubectl logs --since
  -h             show this help
EOF
}

# Parse CLI options. All options are optional; defaults are safe.
while getopts ":n:p:o:s:h" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    p) POD="$OPTARG" ;;
    o) REPORT_DIR="$OPTARG" ;;
    s) SINCE="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument" >&2; usage; exit 1 ;;
  esac
 done

# Ensure output directory exists before any collection begins.
mkdir -p "$REPORT_DIR"

# Current timestamp for filenames and summaries.
timestamp() { date +'%Y-%m-%d_%H-%M-%S'; }

# Color output when running in a terminal (safe no-op when redirected).
if [ -t 1 ]; then
  BOLD='\033[1m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  BOLD=''
  RED=''
  YELLOW=''
  GREEN=''
  CYAN=''
  RESET=''
fi

# Verify kubectl is installed and available on PATH.
# This prevents the script from running partial work without the client.
require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl not found. Install kubectl and configure access." >&2
    exit 2
  }
}

# Collect cluster metadata once per incident.
collect_cluster_info() {
  local outdir="$1"
  mkdir -p "$outdir"
  kubectl version --client > "$outdir/kubectl_client_version.txt" 2>&1 || true
  kubectl get nodes -o wide > "$outdir/nodes.txt" 2>&1 || true
}

# Gather diagnostics for a single failing pod.
# Creates a timestamped incident directory and writes the report assets.
collect_incident() {
  local namespace="$1" pod="$2" status="$3"
  local outdir="$REPORT_DIR/incident_${namespace}_${pod}_$(timestamp)"
  mkdir -p "$outdir/containers" "$outdir/cluster_info"

  cat > "$outdir/summary.txt" <<EOF
K8sDoctor Incident Report
Run Timestamp : $RUN_TS
Collected At   : $(timestamp)

Namespace : $namespace
Pod       : $pod
Status    : $status

Collected Files:
  - describe.txt
  - pod.yaml
  - events.txt
  - containers/
  - cluster_info/
EOF

  kubectl describe pod "$pod" -n "$namespace" > "$outdir/describe.txt" 2>&1 || true
  kubectl get pod "$pod" -n "$namespace" -o yaml > "$outdir/pod.yaml" 2>&1 || true
  kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod" > "$outdir/events.txt" 2>&1 || true

  local containers
  containers=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null || true)
  for c in $containers; do
    [ -z "$c" ] && continue
    local log_file="$outdir/containers/${c}_logs.txt"
    local prev_file="$outdir/containers/${c}_previous_logs.txt"
    if [ -n "$SINCE" ]; then
      kubectl logs "$pod" -n "$namespace" -c "$c" --since="$SINCE" > "$log_file" 2>&1 || true
      kubectl logs "$pod" -n "$namespace" -c "$c" --previous --since="$SINCE" > "$prev_file" 2>&1 || true
    else
      kubectl logs "$pod" -n "$namespace" -c "$c" > "$log_file" 2>&1 || true
      kubectl logs "$pod" -n "$namespace" -c "$c" --previous > "$prev_file" 2>&1 || true
    fi
  done

  collect_cluster_info "$outdir/cluster_info"
  # return the incident directory path so callers can use it programmatically
  printf "%s" "$outdir"
}

RUN_TS="$(timestamp)"

require_kubectl

# Human-friendly check output (matches requested format)
printf "%b %b\n" "${CYAN}[INFO] Checking cluster access...${RESET}" "${GREEN}OK${RESET}"
if ! kubectl get pods -A --no-headers >/dev/null 2>&1; then
  echo "${RED}ERROR:${RESET} Failed to list pods. Check kubeconfig and RBAC (needs get/list/watch pods, get events, get logs)." >&2
  exit 3
fi

printf "%b\n\n" "${CYAN}SCANNING PODS IN ALL NAMESPACES${RESET}"
sep="-----------------------------------------------------------------------------------------"
printf "%s\n" "$sep"
printf " %-15s | %-40s | %-15s | %-20s\n" "NAMESPACE" "POD NAME" "STATUS" "INFO"
printf "%s\n" "$sep"

pod_list() {
  # Build the pod list based on user filters.
  if [ -n "$NAMESPACE" ] && [ -n "$POD" ]; then
    kubectl get pods -n "$NAMESPACE" --no-headers | awk -v ns="$NAMESPACE" -v p="$POD" '$1==p {print ns" "$1" "$4}'
  elif [ -n "$NAMESPACE" ]; then
    kubectl get pods -n "$NAMESPACE" --no-headers | awk -v ns="$NAMESPACE" '{print ns" "$1" "$4}'
  elif [ -n "$POD" ]; then
    kubectl get pods -A --no-headers | awk -v p="$POD" '$2==p {print $1" "$2" "$4}'
  else
    kubectl get pods -A --no-headers | awk '{print $1" "$2" "$4}'
  fi
}

POD_LIST="$(pod_list)"
[ -z "$POD_LIST" ] && { echo "No pods found matching the query."; exit 0; }

total=0
ok_count=0
fail_count=0
rows=()
while read -r namespace pod status _; do
  [ -z "$pod" ] && continue
  total=$((total+1))
  if [[ "$status" =~ ^(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|InvalidImageName)$ ]]; then
    # collect incident and record report path
    incident_path=$(collect_incident "$namespace" "$pod" "$status") || incident_path=""
    info="Report saved"
    fail_count=$((fail_count+1))
    status_display="${BOLD}${RED}${status}${RESET}"
  else
    info="-"
    ok_count=$((ok_count+1))
    status_display="${GREEN}${status}${RESET}"
  fi
  # store row as delimiter-separated values
  rows+=("$namespace|$pod|$status_display|$info")
done <<< "$POD_LIST"

# Print collected rows in a table with colors applied
for r in "${rows[@]}"; do
  IFS='|' read -r ns pod status_disp info <<< "$r"
  # strip color codes for width alignment: use a simple uncolored status variable for spacing
  # print the row (status_disp may contain ANSI codes)
  printf " %-15s | %-40s | %-15b | %-20s\n" "$ns" "$pod" "$status_disp" "$info"
done
printf "%s\n\n" "$sep"

# Summary
printf "%b\n" "${CYAN}SCAN SUMMARY${RESET}"
printf "─────────────────────────────────────────────────────────\n"
printf " Total Pods Checked : %s\n" "$total"
printf " Healthy Pods (OK)  : %s\n" "$ok_count"
printf " Failed Pods (FAIL) : %s\n\n" "$fail_count"
printf "Reports saved to: %s\n" "$REPORT_DIR"
