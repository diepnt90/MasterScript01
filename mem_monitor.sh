#!/bin/bash
# ============================================================
# Memory Monitor Script
# Usage: ./mem_monitor.sh -t1 <threshold1_percent> -t2 <threshold2_percent>
# Example: ./mem_monitor.sh -t1 50 -t2 80
#   - If RAM < threshold1 at startup: wait for threshold1 (dump 1), then threshold2 (dump 2) -> exit
#   - If RAM >= threshold1 at startup: skip threshold1, wait for threshold2 (dump) -> exit
# ============================================================

script_name=${0##*/}

function usage() {
    echo "Syntax: $script_name -t1 <threshold1_percent> -t2 <threshold2_percent>"
    echo "  -t1 <percent>  : First memory threshold (triggers first dump, monitoring continues)"
    echo "  -t2 <percent>  : Second memory threshold (triggers second dump, then script exits)"
    echo "  -c             : Cleanup/shutdown the script"
    echo "Example: $script_name -t1 50 -t2 80"
}

function die() {
    echo "$1" && exit $2
}

function teardown() {
    echo "Shutting down 'dotnet-dump collect' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-dump" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs) 2>/dev/null
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


function getwebsitename() {
    local pid=$1
    local site
    site=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w WEBSITE_SITE_NAME)
    site=${site#*=}
    echo "${site:0:6}"
}

function sendemail() {
    # $1-subject, $2-body, $3-output_file
    local subject=$1
    local body=$2
    local output_file=$3
    if [[ -z "$NOTIFY_EMAIL" ]]; then
        return 0
    fi
    local response
    response=$(curl -s -X POST https://api.smtp2go.com/v3/email/send \
        -H "Content-Type: application/json" \
        -d "{
            \"api_key\": \"api-3A3D49C1F24C4BB086727C18615A0353\",
            \"to\": [\"$NOTIFY_EMAIL\"],
            \"sender\": \"IMtool@daulac.my\",
            \"subject\": \"$subject\",
            \"text_body\": \"$body\"
        }" 2>&1)
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Email notification sent to $NOTIFY_EMAIL. Response: $response" >> "$output_file"
}
function collect_counters()
{
    # $1-label, $2-output_file, $3-instance, $4-pid
    local label=$1
    local output_file=$2
    local instance=$3
    local pid=$4

    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local counters_file="${instance}_${label}_${timestamp}_counters.csv"

    echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Collecting dotnet-counters (10s, csv) -> ${counters_file} ..." >> "$output_file"
    /tools/dotnet-counters collect -p "$pid" \
        --counters System.Runtime[gc-heap-size,working-set,loh-size,poh-size,gen-2-size,gen-0-size,gen-1-size,gc-fragmentation,gc-committed-bytes,alloc-rate] \
        --output "$counters_file" \
        --format csv \
        --duration 00:00:10 > /dev/null 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] dotnet-counters collection done." >> "$output_file"

    # Upload counters file to Azure Blob
    local sas_url
    sas_url=$(getsasurl "$pid")
    if [[ -n "$sas_url" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Uploading counters file to Azure Blob Container..." >> "$output_file"
        local azcopy_output
        azcopy_output=$(/tools/azcopy copy "$counters_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Counters file successfully uploaded." >> "$output_file"
            return 0
        fi

        local retry_count=1
        local max_retries=5
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] AzCopy failed. Retrying... (Attempt $retry_count/$max_retries)" >> "$output_file"
            sleep 5
            azcopy_output=$(/tools/azcopy copy "$counters_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Counters file successfully uploaded." >> "$output_file"
                return 0
            fi
            ((retry_count++))
        done
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] ERROR: AzCopy failed to upload counters file after $max_retries attempts." >> "$output_file"
    fi
}

function collectdump() {
    # $1-label, $2-output_file, $3-instance, $4-pid
    local label=$1
    local output_file=$2
    local instance=$3
    local pid=$4
    local instance_lock_file="memdump_taken_${instance}_${label}.lock"

    if [[ ! -e "$instance_lock_file" ]]; then
        touch "$instance_lock_file"
        echo "Memory dump ${label} is collected by ${instance}" >> "$instance_lock_file"

        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local dump_file="memdump_${instance}_${label}_${timestamp}.dmp"
        local sas_url
        sas_url=$(getsasurl "$pid")

        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Acquiring dump lock for instance ${instance}..." >> "$output_file"
        collect_counters "$label" "$output_file" "$instance" "$pid"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Collecting memory dump -> ${dump_file} ..." >> "$output_file"

        /tools/dotnet-dump collect -p "$pid" -o "$dump_file" > /dev/null
        local dump_exit=$?

        if [[ $dump_exit -ne 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] ERROR: dotnet-dump exited with code $dump_exit" >> "$output_file"
            return 1
        fi

        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Dump collected. Uploading to Azure Blob Container..." >> "$output_file"

        # Initial upload attempt
        local azcopy_output
        azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Memory dump successfully uploaded to Azure Blob Container." >> "$output_file"
            sendemail "Successfully got dump for ${SITE_NAME} - ${INSTANCE}" "File ${dump_file} has been uploaded to Azure Blob Container." "$output_file"
            return 0
        fi

        # Retry logic
        local retry_count=1
        local max_retries=5
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] AzCopy upload failed. Retrying... (Attempt $retry_count/$max_retries)" >> "$output_file"
            sleep 5
            azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] Memory dump successfully uploaded to Azure Blob Container." >> "$output_file"
                sendemail "Successfully got dump for ${SITE_NAME} - ${INSTANCE}" "File ${dump_file} has been uploaded to Azure Blob Container." "$output_file"
                return 0
            fi
            ((retry_count++))
        done

        echo "$(date '+%Y-%m-%d %H:%M:%S'): [${label}] ERROR: AzCopy failed to upload memory dump after $max_retries attempts." >> "$output_file"
    fi
}

# ─── Parse arguments ──────────────────────────────────────────────────────────
THRESHOLD1=""
THRESHOLD2=""
CLEAN_FLAG=0
INTERVAL=300  # 5 minutes
NOTIFY_EMAIL=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t1) THRESHOLD1="$2"; shift 2 ;;
        -t2) THRESHOLD2="$2"; shift 2 ;;
        -c)  CLEAN_FLAG=1; shift ;;
        -e)  NOTIFY_EMAIL="$2"; shift 2 ;;
        -h)  usage; exit 0 ;;
        *)   echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ "$CLEAN_FLAG" -eq 1 ]]; then
    teardown
fi

# ─── Validate thresholds ──────────────────────────────────────────────────────
if [[ -z "$THRESHOLD1" || -z "$THRESHOLD2" ]]; then
    echo "[ERROR] Both -t1 and -t2 are required."
    usage
    exit 1
fi

for T in "$THRESHOLD1" "$THRESHOLD2"; do
    if ! [[ "$T" =~ ^[0-9]+$ ]] || [[ "$T" -lt 1 ]] || [[ "$T" -gt 100 ]]; then
        echo "[ERROR] Threshold must be an integer between 1 and 100 (received: $T)"
        exit 1
    fi
done

if [[ "$THRESHOLD1" -ge "$THRESHOLD2" ]]; then
    echo "[ERROR] threshold1 ($THRESHOLD1%) must be less than threshold2 ($THRESHOLD2%)"
    exit 1
fi

# ─── Find .NET process ────────────────────────────────────────────────────────
PID=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [[ -z "$PID" ]]; then
    die "[ERROR] No .NET process found. Cannot collect memory dumps." 1
fi

# ─── Get instance name ────────────────────────────────────────────────────────
INSTANCE=$(getcomputername "$PID")
if [[ -z "$INSTANCE" ]]; then
    echo "[WARNING] Cannot find COMPUTERNAME environment variable, using hostname instead."
    INSTANCE=$(hostname)
fi

# ─── Get site name
SITE_NAME=$(getwebsitename "$PID")

# ─── Setup output directory & log file ───────────────────────────────────────
OUTPUT_DIR="memusage-logs-${INSTANCE}"
mkdir -p "$OUTPUT_DIR"

PREVIOUS_HOUR=""

# ─── Startup RAM check ───────────────────────────────────────────────────────
read INIT_TOTAL INIT_USED <<< $(free -m | awk 'NR==2 {print $2, $3}')
INIT_PCT=$(( INIT_USED * 100 / INIT_TOTAL ))

echo "============================================================"
echo " Memory Monitor Started"
echo " Instance    : ${INSTANCE}"
echo " PID         : ${PID}"
echo " Threshold 1 : ${THRESHOLD1}%  (dump #1, monitoring continues)"
echo " Threshold 2 : ${THRESHOLD2}%  (dump #2, then script exits)"
echo " Interval    : ${INTERVAL}s (every 5 minutes)"
echo " Log dir     : ${OUTPUT_DIR}/"
echo " Started at  : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAM at startup: ${INIT_USED}MB / ${INIT_TOTAL}MB (${INIT_PCT}%)"

if [[ "$INIT_PCT" -gt "$THRESHOLD1" ]]; then
    DUMP1_DONE=true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RAM is at ${INIT_PCT}% > ${THRESHOLD1}%, skipping threshold 1 -> waiting for threshold 2 (${THRESHOLD2}%)"
else
    DUMP1_DONE=false
fi

# ─── Main loop ────────────────────────────────────────────────────────────────
while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Hourly log rotation
    CURRENT_HOUR=$(date +"%Y-%m-%d_%H")
    if [[ "$CURRENT_HOUR" != "$PREVIOUS_HOUR" ]]; then
        OUTPUT_FILE="${OUTPUT_DIR}/memusage_stats_${CURRENT_HOUR}.log"
        PREVIOUS_HOUR="$CURRENT_HOUR"
    fi

    read TOTAL_MEM USED_MEM <<< $(free -m | awk 'NR==2 {print $2, $3}')
    USED_PCT=$(( USED_MEM * 100 / TOTAL_MEM ))

    echo "[${TIMESTAMP}] Memory: ${USED_MEM}MB / ${TOTAL_MEM}MB (${USED_PCT}%) | Thresholds: ${THRESHOLD1}% / ${THRESHOLD2}%" | tee -a "$OUTPUT_FILE"

    # Check threshold 2 first (higher priority)
    if [[ "$USED_PCT" -gt "$THRESHOLD2" ]]; then
        echo "[${TIMESTAMP}] [ALERT] Memory exceeded threshold 2 (${THRESHOLD2}%). Collecting dump #2..." | tee -a "$OUTPUT_FILE"
        collectdump "threshold2_${THRESHOLD2}pct" "$OUTPUT_FILE" "$INSTANCE" "$PID"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dump #2 collected. Script completed." | tee -a "$OUTPUT_FILE"
        exit 0

    # Check threshold 1 (only if not already done)
    elif [[ "$DUMP1_DONE" == false && "$USED_PCT" -gt "$THRESHOLD1" ]]; then
        echo "[${TIMESTAMP}] [ALERT] Memory exceeded threshold 1 (${THRESHOLD1}%). Collecting dump #1..." | tee -a "$OUTPUT_FILE"
        collectdump "threshold1_${THRESHOLD1}pct" "$OUTPUT_FILE" "$INSTANCE" "$PID"
        DUMP1_DONE=true
    fi

    sleep ${INTERVAL}
done
