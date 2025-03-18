#!/bin/bash

# Usage: ./k8s-collector.sh -n <namespace> [-c custom_resource1,custom_resource2] [-z]

set -e

NAMESPACE=""
CUSTOM_RESOURCES=""
ZIP_OUTPUT=false

while getopts "n:c:z" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    c) CUSTOM_RESOURCES="$OPTARG" ;;
    z) ZIP_OUTPUT=true ;;
    *) echo "Usage: $0 -n <namespace> [-c custom_resource1,custom_resource2] [-z]" >&2
       exit 1 ;;
  esac
done

if [ -z "$NAMESPACE" ]; then
  echo "Error: Namespace is required. Use -n <namespace>"
  echo "Usage: $0 -n <namespace> [-c custom_resource1,custom_resource2] [-z]"
  exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="${NAMESPACE}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"
echo "Creating output directory: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/logs"
mkdir -p "$OUTPUT_DIR/describe"
mkdir -p "$OUTPUT_DIR/events"

ERROR_LOG_FILE="$OUTPUT_DIR/error_summary.log"
echo "Error Log Summary for Namespace: $NAMESPACE (Extracted on $TIMESTAMP)" > "$ERROR_LOG_FILE"
echo "=========================================================================" >> "$ERROR_LOG_FILE"
echo "" >> "$ERROR_LOG_FILE"

process_resource_type() {
  local resource_type="$1"
  local singular="$2"
  local plural="$3"
  
  echo "Extracting ${resource_type} information..."
  
  mkdir -p "$OUTPUT_DIR/get/${plural}"
  kubectl get ${plural} -n "$NAMESPACE" -o wide > "$OUTPUT_DIR/get/${plural}/${plural}.txt" 2>/dev/null || echo "No ${resource_type}s found" > "$OUTPUT_DIR/get/${plural}/${plural}.txt"
  RESOURCES=$(kubectl get ${plural} -n "$NAMESPACE" -o name 2>/dev/null)
  
  for resource_path in $RESOURCES; do
    resource=$(echo "$resource_path" | cut -d '/' -f 2)
    
    echo "Processing ${resource_type}: $resource"
    
    kubectl describe ${singular} "$resource" -n "$NAMESPACE" > "$OUTPUT_DIR/describe/${singular}_${resource}.txt" &
    kubectl get ${singular} "$resource" -n "$NAMESPACE" -o yaml > "$OUTPUT_DIR/get/${plural}/${resource}.yaml" &
  done
  echo "$RESOURCES"
}

process_custom_resource() {
  local resource="$1"
  
  echo "Extracting custom resource: $resource..."
  
  if ! kubectl api-resources | grep -q "$resource"; then
    echo "Warning: Custom resource '$resource' not found in the cluster. Skipping."
    return
  fi
  
  mkdir -p "$OUTPUT_DIR/get/${resource}"
  
  if kubectl get ${resource} -n "$NAMESPACE" &>/dev/null; then
    kubectl get ${resource} -n "$NAMESPACE" -o wide > "$OUTPUT_DIR/get/${resource}/${resource}.txt"
    
    RESOURCES=$(kubectl get ${resource} -n "$NAMESPACE" -o name 2>/dev/null)
    
    for resource_path in $RESOURCES; do
      resource_name=$(echo "$resource_path" | cut -d '/' -f 2)
      
      echo "Processing custom resource $resource: $resource_name"
      
      kubectl describe ${resource} "$resource_name" -n "$NAMESPACE" > "$OUTPUT_DIR/describe/${resource}_${resource_name}.txt" &
      kubectl get ${resource} "$resource_name" -n "$NAMESPACE" -o yaml > "$OUTPUT_DIR/get/${resource}/${resource_name}.yaml" &
    done
    
    echo "$(echo "$RESOURCES" | wc -w)"
  else
    echo "No resources of type '$resource' found in namespace $NAMESPACE"
    echo "0"
  fi
}

extract_error_logs() {
  local pod="$1"
  local container="$2"
  local log_file="$OUTPUT_DIR/logs/$pod/${container}.log"
  
  if [ -s "$log_file" ]; then
    if grep -i "error" "$log_file" > /dev/null; then
      {
        echo "=== Error logs from pod: $pod, container: $container ==="
        echo ""
        grep -i "error" "$log_file" | while read -r line; do
          echo "$line"
        done
        echo ""
        echo "------------------------------------------------"
        echo ""
      } >> "$ERROR_LOG_FILE"
    fi
  fi
}

extract_namespace_events() {
  echo "Extracting events for namespace: $NAMESPACE"
  
  echo "Getting events..."
  kubectl get events -n "$NAMESPACE" -o wide > "$OUTPUT_DIR/events/events.txt"
  
  echo "Getting events sorted by timestamp..."
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' -o wide > "$OUTPUT_DIR/events/events_by_timestamp.txt"

  echo "Getting events in JSON format..."
  kubectl get events -n "$NAMESPACE" -o json > "$OUTPUT_DIR/events/events.json"
}

echo "=== Starting extraction for namespace: $NAMESPACE ==="

echo "Extracting Pod information..."
mkdir -p "$OUTPUT_DIR/get/pods"
kubectl get pods -n "$NAMESPACE" -o wide > "$OUTPUT_DIR/get/pods/pods.txt" 2>/dev/null || echo "No Pods found" > "$OUTPUT_DIR/get/pods/pods.txt"
PODS=$(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null)

for pod_path in $PODS; do
  pod=$(echo "$pod_path" | cut -d '/' -f 2)
  
  echo "Processing pod: $pod"
  
  mkdir -p "$OUTPUT_DIR/logs/$pod"
  kubectl describe pod "$pod" -n "$NAMESPACE" > "$OUTPUT_DIR/describe/pod_${pod}.txt" &
  kubectl get pod "$pod" -n "$NAMESPACE" -o yaml > "$OUTPUT_DIR/get/pods/${pod}.yaml" &
  
  CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}')
  
  for container in $CONTAINERS; do
    echo "  Extracting logs for container: $container"
    kubectl logs "$pod" -c "$container" -n "$NAMESPACE" > "$OUTPUT_DIR/logs/$pod/${container}.log" 2>/dev/null &
  done
done

wait

echo "Extracting error logs from all containers..."
for pod_path in $PODS; do
  pod=$(echo "$pod_path" | cut -d '/' -f 2)
  CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
  
  for container in $CONTAINERS; do
    extract_error_logs "$pod" "$container"
  done
done

process_resource_type "StatefulSet" "statefulset" "statefulsets" > /dev/null &
STS_PID=$!

process_resource_type "Deployment" "deployment" "deployments" > /dev/null &
DEPLOYMENT_PID=$!

process_resource_type "Secret" "secret" "secrets" > /dev/null &
SECRET_PID=$!

process_resource_type "Job" "job" "jobs" > /dev/null &
JOB_PID=$!

process_resource_type "ConfigMap" "configmap" "configmaps" > /dev/null &
CM_PID=$!

process_resource_type "Service" "service" "services" > /dev/null &
SVC_PID=$!

extract_namespace_events &
EVENTS_PID=$!

wait $STS_PID $DEPLOYMENT_PID $SECRET_PID $JOB_PID $CM_PID $SVC_PID $EVENTS_PID

CUSTOM_RESOURCE_COUNTS=()
if [ -n "$CUSTOM_RESOURCES" ]; then
  echo "Processing custom resources..."
  
  IFS=',' read -ra CUSTOM_RESOURCE_ARRAY <<< "$CUSTOM_RESOURCES"
  
  for resource in "${CUSTOM_RESOURCE_ARRAY[@]}"; do
    resource=$(echo "$resource" | tr -d ' ')
    if [ -n "$resource" ]; then
      count=$(process_custom_resource "$resource")
      CUSTOM_RESOURCE_COUNTS+=("$resource:$count")
    fi
  done
  
  wait
fi

PODS_COUNT=$(echo "$PODS" | wc -w)
STS_COUNT=$(ls -1 "$OUTPUT_DIR/describe/statefulset_"* 2>/dev/null | wc -l || echo 0)
DEPLOYMENTS_COUNT=$(ls -1 "$OUTPUT_DIR/describe/deployment_"* 2>/dev/null | wc -l || echo 0)
SECRETS_COUNT=$(ls -1 "$OUTPUT_DIR/describe/secret_"* 2>/dev/null | wc -l || echo 0)
JOBS_COUNT=$(ls -1 "$OUTPUT_DIR/describe/job_"* 2>/dev/null | wc -l || echo 0)
CMS_COUNT=$(ls -1 "$OUTPUT_DIR/describe/configmap_"* 2>/dev/null | wc -l || echo 0)
SVCS_COUNT=$(ls -1 "$OUTPUT_DIR/describe/service_"* 2>/dev/null | wc -l || echo 0)
ERROR_LOGS_COUNT=$(grep -c "=== Error logs from" "$ERROR_LOG_FILE" || echo 0)
EVENTS_COUNT=$(grep -c "^[^ ]" "$OUTPUT_DIR/events/events.txt" 2>/dev/null | awk '{print $1-1}' || echo 0)

echo "Generating summary..."
{
  echo "Summary"
  echo "========================================"
  echo "Namespace: $NAMESPACE"
  echo "Timestamp: $TIMESTAMP"
  echo ""
  
  echo "Resources collected:"
  echo "-------------------"
  echo "Pods: $PODS_COUNT"
  echo "StatefulSets: $STS_COUNT"
  echo "Deployments: $DEPLOYMENTS_COUNT"
  echo "Secrets: $SECRETS_COUNT"
  echo "Jobs: $JOBS_COUNT"
  echo "ConfigMaps: $CMS_COUNT"
  echo "Services: $SVCS_COUNT"
  echo "Events: $EVENTS_COUNT"
  
  if [ ${#CUSTOM_RESOURCE_COUNTS[@]} -gt 0 ]; then
    echo ""
    echo "Custom Resources:"
    echo "----------------"
    for item in "${CUSTOM_RESOURCE_COUNTS[@]}"; do
      resource_type=$(echo "$item" | cut -d ':' -f 1)
      count=$(echo "$item" | cut -d ':' -f 2)
      echo "$resource_type: $count"
    done
  fi
  
  echo ""
  echo "Error logs:"
  echo "-----------"
  echo "Container logs with errors: $ERROR_LOGS_COUNT"
  echo "See $ERROR_LOG_FILE for details"
  
  echo ""
  echo "Events:"
  echo "-------"
  echo "Events by resource: $OUTPUT_DIR/events/events.txt"
  echo "Events by timestamp: $OUTPUT_DIR/events/events_by_timestamp.txt"
  echo "Events in JSON format: $OUTPUT_DIR/events/events.json"
  
} > "$OUTPUT_DIR/summary.txt"

if [ "$ZIP_OUTPUT" = true ]; then
  ZIP_FILE="${OUTPUT_DIR}.zip"
  echo "Creating ZIP archive: $ZIP_FILE"
  if command -v zip >/dev/null 2>&1; then
    zip -r "$ZIP_FILE" "$OUTPUT_DIR" >/dev/null
    echo "ZIP archive created successfully: $ZIP_FILE"
    
    cp "$OUTPUT_DIR/summary.txt" "./summary_${NAMESPACE}_${TIMESTAMP}.txt"
    echo "Summary file copied to: ./summary_${NAMESPACE}_${TIMESTAMP}.txt"
  else
    echo "Error: 'zip' command not found. Please install zip or omit the -z flag."
    echo "The uncompressed output is still available in: $OUTPUT_DIR"
  fi
fi

echo "=== Extraction completed successfully ==="
echo "Output is available in: $OUTPUT_DIR"
if [ "$ZIP_OUTPUT" = true ] && command -v zip >/dev/null 2>&1; then
  echo "ZIP archive: $ZIP_FILE"
fi

echo "Summary information: $OUTPUT_DIR/summary.txt"
echo "Error log summary: $ERROR_LOG_FILE"