#!/bin/bash
# ============================================================
# GCDump Monitor Script
# Collects 3 gcdumps at 3 memory thresholds, exports to txt, zips and uploads to Azure Blob
# Usage: ./gcdump_monitor.sh -t1 <pct> -t2 <pct> -t3 <pct>
# Example: ./gcdump_monitor.sh -t1 30 -t2 60 -t3 80
# ============================================================

script_name=${0##*/}

function usage() {
    echo "Syntax: $script_name -t1 <pct> -t2 <pct> -t3 <pct>"
    echo "  -t1 <percent>  : First threshold  - collect gcdump #1, monitoring continues"
    echo "  -t2 <percent>  : Second threshold - collect gcdump #2, monitoring continues"
    echo "  -t3 <percent>  : Third threshold  - collect gcdump #3, zip + upload all, then exit"
    echo "  -c             : Cleanup/shutdown the script"
    echo "Example: $script_name -t1 30 -t2 60 -t3 80"
}

function die() {
    echo "$1" && exit $2
}

function teardown() {
    echo "Shutting down 'dotnet-gcdump' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-gcdump" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs) 2>/dev/null
    echo "Shutting down 'azcopy copy' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/azcopy" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs) 2>/dev/null
    echo "Shutting down $script_name process..."
    kill -SIGTERM $(ps -ef | grep "$script_name" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs) 2>/dev/null
    echo "Completed"
    exit 0
}

function getsasurl() {
    local pid=$1
    local sas_url
    sas_url=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL)
    sas_url=${sas_url#*=}
    echo "$sas_url"
}

function getcomputername() {
    local pid=$1
    local instance
    instance=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w COMPUTERNAME)
    instance=${instance#*=}
    echo "$instance"
}

function collect_counters()
{
    # $1-label, $2-output_file, $3-instance, $4-pid
    local label=$1
    local output_file=$2
    local instance=$3
    local pid=$4

    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local counters_file="${WORK_DIR}/${instance}_${label}_${timestamp}_counters.txt"

    echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Collecting dotnet-counters for 10s -> $(basename $counters_file) ..." | tee -a "$output_file"
    timeout 10 /tools/dotnet-counters monitor -p "$pid" \
        --counters System.Runtime[gc-heap-size,working-set,committed-bytes,gen-0-gc-count,gen-1-gc-count,gen-2-gc-count] \
        > "$counters_file" 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] dotnet-counters collection done." | tee -a "$output_file"
}

function collect_gcdump() {
    # $1-threshold_label (e.g. "30pct"), $2-output_file, $3-instance, $4-pid
    local label=$1
    local output_file=$2
    local instance=$3
    local pid=$4

    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local gcdump_file="${WORK_DIR}/gcdump_${instance}_${label}_${timestamp}.gcdump"
    local report_file="${WORK_DIR}/report_${instance}_${label}_${timestamp}.txt"

    collect_counters "$label" "$output_file" "$instance" "$pid"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Collecting gcdump -> $(basename $gcdump_file) ..." | tee -a "$output_file"

    if [[ ! -x "/tools/dotnet-gcdump" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] ERROR: /tools/dotnet-gcdump not found or not executable." | tee -a "$output_file"
        return 1
    fi

    /tools/dotnet-gcdump collect -p "$pid" -o "$gcdump_file" > /dev/null 2>&1
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] ERROR: dotnet-gcdump exited with code $exit_code" | tee -a "$output_file"
        return 1
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] gcdump collected. Generating text report -> $(basename $report_file) ..." | tee -a "$output_file"

    /tools/dotnet-gcdump report "$gcdump_file" > "$report_file" 2>&1
    if [[ $? -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] WARNING: dotnet-gcdump report failed, report file may be empty." | tee -a "$output_file"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Text report generated." | tee -a "$output_file"
    fi

    # Track collected report files for final zip
    COLLECTED_REPORTS+=("$report_file")
    COLLECTED_GCDUMPS+=("$gcdump_file")

    echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Done. Total collected so far: ${#COLLECTED_REPORTS[@]}/3" | tee -a "$output_file"
}

function zip_and_upload() {
    local output_file=$1
    local instance=$2
    local pid=$3

    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local zip_file="${WORK_DIR}/gcdump_reports_${instance}_${timestamp}.tar.gz"
    local sas_url
    sas_url=$(getsasurl "$pid")

    local report_count=${#COLLECTED_REPORTS[@]}
    local counters_count=${#COLLECTED_COUNTERS[@]}
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Archiving $report_count report(s) + $counters_count counters file(s) -> $(basename $zip_file) ..." | tee -a "$output_file"

    # Bundle all collected files (reports + counters) using tar+gzip
    local all_files=("${COLLECTED_REPORTS[@]}" "${COLLECTED_COUNTERS[@]}")
    local basenames=()
    for f in "${all_files[@]}"; do basenames+=("${f##*/}"); done
    local tar_output
    tar_output=$(tar -czf "$zip_file" -C "$WORK_DIR" "${basenames[@]}" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to create tar.gz file. Details: $tar_output" | tee -a "$output_file"
        return 1
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S'): Zip created. Uploading to Azure Blob Container..." | tee -a "$output_file"

    # Initial upload attempt
    local azcopy_output
    azcopy_output=$(/tools/azcopy copy "$zip_file" "$sas_url" 2>&1)
    if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Zip file successfully uploaded to Azure Blob Container." | tee -a "$output_file"
        return 0
    fi

    # Retry logic
    local retry_count=1
    local max_retries=5
    while [[ $retry_count -le $max_retries ]]; do
        echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy upload failed. Retrying... (Attempt $retry_count/$max_retries)" | tee -a "$output_file"
        sleep 5
        azcopy_output=$(/tools/azcopy copy "$zip_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Zip file successfully uploaded to Azure Blob Container." | tee -a "$output_file"
            return 0
        fi
        ((retry_count++))
    done

    echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: AzCopy failed to upload zip after $max_retries attempts." | tee -a "$output_file"
    return 1
}

# ─── Parse arguments ──────────────────────────────────────────────────────────
THRESHOLD1=""
THRESHOLD2=""
THRESHOLD3=""
CLEAN_FLAG=0
INTERVAL=300  # 5 minutes

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t1) THRESHOLD1="$2"; shift 2 ;;
        -t2) THRESHOLD2="$2"; shift 2 ;;
        -t3) THRESHOLD3="$2"; shift 2 ;;
        -c)  CLEAN_FLAG=1; shift ;;
        -h)  usage; exit 0 ;;
        *)   echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ "$CLEAN_FLAG" -eq 1 ]]; then
    teardown
fi

# ─── Validate thresholds ──────────────────────────────────────────────────────
if [[ -z "$THRESHOLD1" || -z "$THRESHOLD2" || -z "$THRESHOLD3" ]]; then
    echo "[ERROR] All three thresholds -t1, -t2, -t3 are required."
    usage
    exit 1
fi

for T in "$THRESHOLD1" "$THRESHOLD2" "$THRESHOLD3"; do
    if ! [[ "$T" =~ ^[0-9]+$ ]] || [[ "$T" -lt 1 ]] || [[ "$T" -gt 100 ]]; then
        echo "[ERROR] Threshold must be an integer between 1 and 100 (received: $T)"
        exit 1
    fi
done

if [[ "$THRESHOLD1" -ge "$THRESHOLD2" ]] || [[ "$THRESHOLD2" -ge "$THRESHOLD3" ]]; then
    echo "[ERROR] Thresholds must be strictly increasing: t1 < t2 < t3"
    echo "        Received: t1=$THRESHOLD1% t2=$THRESHOLD2% t3=$THRESHOLD3%"
    exit 1
fi

# ─── Find .NET process ────────────────────────────────────────────────────────
PID=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [[ -z "$PID" ]]; then
    die "[ERROR] No .NET process found. Cannot collect gcdumps." 1
fi

# ─── Get instance name ────────────────────────────────────────────────────────
INSTANCE=$(getcomputername "$PID")
if [[ -z "$INSTANCE" ]]; then
    echo "[WARNING] Cannot find COMPUTERNAME environment variable, using hostname instead."
    INSTANCE=$(hostname)
fi

# ─── Setup output directory ───────────────────────────────────────────────────
WORK_DIR="gcdump-logs-${INSTANCE}"
mkdir -p "$WORK_DIR"

# Arrays to track collected files
COLLECTED_REPORTS=()
COLLECTED_GCDUMPS=()
COLLECTED_COUNTERS=()

PREVIOUS_HOUR=""

# ─── Startup RAM check ───────────────────────────────────────────────────────
read INIT_TOTAL INIT_USED <<< $(free -m | awk 'NR==2 {print $2, $3}')
INIT_PCT=$(( INIT_USED * 100 / INIT_TOTAL ))

echo "============================================================"
echo " GCDump Monitor Started"
echo " Instance    : ${INSTANCE}"
echo " PID         : ${PID}"
echo " Threshold 1 : ${THRESHOLD1}%  (gcdump #1, monitoring continues)"
echo " Threshold 2 : ${THRESHOLD2}%  (gcdump #2, monitoring continues)"
echo " Threshold 3 : ${THRESHOLD3}%  (gcdump #3, zip reports + upload, then exit)"
echo " Interval    : ${INTERVAL}s (every 5 minutes)"
echo " Work dir    : ${WORK_DIR}/"
echo " Started at  : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAM at startup: ${INIT_USED}MB / ${INIT_TOTAL}MB (${INIT_PCT}%)"

# Determine which thresholds to skip based on current RAM
if [[ "$INIT_PCT" -gt "$THRESHOLD2" ]]; then
    DUMP1_DONE=true
    DUMP2_DONE=true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAM is at ${INIT_PCT}% > ${THRESHOLD2}%, skipping threshold 1 & 2 -> waiting for threshold 3 (${THRESHOLD3}%)"
elif [[ "$INIT_PCT" -gt "$THRESHOLD1" ]]; then
    DUMP1_DONE=true
    DUMP2_DONE=false
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAM is at ${INIT_PCT}% > ${THRESHOLD1}%, skipping threshold 1 -> waiting for threshold 2 (${THRESHOLD2}%) and 3 (${THRESHOLD3}%)"
else
    DUMP1_DONE=false
    DUMP2_DONE=false
fi

# ─── Main loop ────────────────────────────────────────────────────────────────
while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Hourly log rotation
    CURRENT_HOUR=$(date +"%Y-%m-%d_%H")
    if [[ "$CURRENT_HOUR" != "$PREVIOUS_HOUR" ]]; then
        OUTPUT_FILE="${WORK_DIR}/gcdump_stats_${CURRENT_HOUR}.log"
        PREVIOUS_HOUR="$CURRENT_HOUR"
    fi

    read TOTAL_MEM USED_MEM <<< $(free -m | awk 'NR==2 {print $2, $3}')
    USED_PCT=$(( USED_MEM * 100 / TOTAL_MEM ))

    echo "[${TIMESTAMP}] Memory: ${USED_MEM}MB / ${TOTAL_MEM}MB (${USED_PCT}%) | Thresholds: ${THRESHOLD1}% / ${THRESHOLD2}% / ${THRESHOLD3}%" | tee -a "$OUTPUT_FILE"

    # Check threshold 3 first (highest priority)
    if [[ "$USED_PCT" -gt "$THRESHOLD3" ]]; then
        echo "[${TIMESTAMP}] [ALERT] Memory exceeded threshold 3 (${THRESHOLD3}%). Collecting gcdump #3..." | tee -a "$OUTPUT_FILE"
        collect_gcdump "${THRESHOLD3}pct" "$OUTPUT_FILE" "$INSTANCE" "$PID"
        zip_and_upload "$OUTPUT_FILE" "$INSTANCE" "$PID"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] All done. Script completed." | tee -a "$OUTPUT_FILE"
        exit 0

    # Check threshold 2
    elif [[ "$DUMP2_DONE" == false && "$USED_PCT" -gt "$THRESHOLD2" ]]; then
        echo "[${TIMESTAMP}] [ALERT] Memory exceeded threshold 2 (${THRESHOLD2}%). Collecting gcdump #2..." | tee -a "$OUTPUT_FILE"
        collect_gcdump "${THRESHOLD2}pct" "$OUTPUT_FILE" "$INSTANCE" "$PID"
        DUMP2_DONE=true

    # Check threshold 1
    elif [[ "$DUMP1_DONE" == false && "$USED_PCT" -gt "$THRESHOLD1" ]]; then
        echo "[${TIMESTAMP}] [ALERT] Memory exceeded threshold 1 (${THRESHOLD1}%). Collecting gcdump #1..." | tee -a "$OUTPUT_FILE"
        collect_gcdump "${THRESHOLD1}pct" "$OUTPUT_FILE" "$INSTANCE" "$PID"
        DUMP1_DONE=true
    fi

    sleep ${INTERVAL}
done
