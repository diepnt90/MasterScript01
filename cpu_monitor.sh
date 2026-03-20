#!/bin/bash
# ============================================================
# CPU Monitor Script
# Monitor CPU usage every 2 minutes. If CPU exceeds threshold
# for 5 consecutive checks (10 minutes), collect memory dump.
# Usage: ./cpu_monitor.sh -t <threshold_percent> [-e <email>]
# ============================================================

script_name=${0##*/}

function usage() {
    echo "Syntax: $script_name -t <threshold_percent> [-e <email>]"
    echo "  -t <percent>  : CPU threshold % to trigger dump after 5 consecutive checks (10 minutes)"
    echo "  -e <email>    : Email address to notify when dump is collected (optional)"
    echo "  -c            : Cleanup/shutdown the script"
    echo "Example: $script_name -t 80 -e your@email.com"
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

function get_cpu_pct() {
    read _ u1 n1 s1 i1 _ < <(grep '^cpu ' /proc/stat)
    sleep 1
    read _ u2 n2 s2 i2 _ < <(grep '^cpu ' /proc/stat)
    local diff_total=$(( (u2+n2+s2+i2) - (u1+n1+s1+i1) ))
    local diff_idle=$(( i2 - i1 ))
    if [[ $diff_total -eq 0 ]]; then
        echo 0
        return
    fi
    echo $(( (diff_total - diff_idle) * 100 / diff_total ))
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

function collectdump() {
    # $1-output_file, $2-instance, $3-pid
    local output_file=$1
    local instance=$2
    local pid=$3
    local instance_lock_file="cpudump_taken_${instance}.lock"

    if [[ ! -e "$instance_lock_file" ]]; then
        touch "$instance_lock_file"
        echo "CPU dump is collected by ${instance}" >> "$instance_lock_file"

        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local dump_file="cpudump_${instance}_${timestamp}.dmp"
        local sas_url
        sas_url=$(getsasurl "$pid")

        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting memory dump -> ${dump_file} ..." >> "$output_file"
        /tools/dotnet-dump collect -p "$pid" -o "$dump_file" > /dev/null
        local dump_exit=$?

        if [[ $dump_exit -ne 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: dotnet-dump exited with code $dump_exit" >> "$output_file"
            return 1
        fi

        echo "$(date '+%Y-%m-%d %H:%M:%S'): Dump collected. Uploading to Azure Blob Container..." >> "$output_file"

        local azcopy_output
        azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump successfully uploaded to Azure Blob Container." >> "$output_file"
            sendemail "Successfully got dump for ${SITE_NAME} - ${instance}" "File ${dump_file} has been uploaded to Azure Blob Container." "$output_file"
            return 0
        fi

        local retry_count=1
        local max_retries=5
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy upload failed. Retrying... (Attempt $retry_count/$max_retries)" >> "$output_file"
            sleep 5
            azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump successfully uploaded to Azure Blob Container." >> "$output_file"
                sendemail "Successfully got dump for ${SITE_NAME} - ${instance}" "File ${dump_file} has been uploaded to Azure Blob Container." "$output_file"
                return 0
            fi
            ((retry_count++))
        done
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: AzCopy failed to upload memory dump after $max_retries attempts." >> "$output_file"
    fi
}

# ─── Parse arguments ──────────────────────────────────────────────────────────
THRESHOLD=""
CLEAN_FLAG=0
NOTIFY_EMAIL=""
INTERVAL=120   # 2 minutes
CONSECUTIVE_REQUIRED=5  # 5 x 2min = 10 minutes

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t)  THRESHOLD="$2"; shift 2 ;;
        -e)  NOTIFY_EMAIL="$2"; shift 2 ;;
        -c)  CLEAN_FLAG=1; shift ;;
        -h)  usage; exit 0 ;;
        *)   echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ "$CLEAN_FLAG" -eq 1 ]]; then
    teardown
fi

# ─── Validate threshold ───────────────────────────────────────────────────────
if [[ -z "$THRESHOLD" ]]; then
    echo "[ERROR] -t <threshold> is required."
    usage
    exit 1
fi

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$THRESHOLD" -lt 1 ]] || [[ "$THRESHOLD" -gt 100 ]]; then
    echo "[ERROR] Threshold must be an integer between 1 and 100 (received: $THRESHOLD)"
    exit 1
fi

# ─── Find .NET process ────────────────────────────────────────────────────────
PID=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [[ -z "$PID" ]]; then
    die "[ERROR] No .NET process found. Cannot collect memory dumps." 1
fi

# ─── Get instance and site name ───────────────────────────────────────────────
INSTANCE=$(getcomputername "$PID")
if [[ -z "$INSTANCE" ]]; then
    echo "[WARNING] Cannot find COMPUTERNAME, using hostname instead."
    INSTANCE=$(hostname)
fi

SITE_NAME=$(getwebsitename "$PID")

# ─── Setup output directory ───────────────────────────────────────────────────
OUTPUT_DIR="cpu-logs-${INSTANCE}"
mkdir -p "$OUTPUT_DIR"

PREVIOUS_HOUR=""
CONSECUTIVE_COUNT=0

echo "============================================================"
echo " CPU Monitor Started"
echo " Instance      : ${INSTANCE}"
echo " PID           : ${PID}"
echo " Threshold     : ${THRESHOLD}%"
echo " Check interval: ${INTERVAL}s (every 2 minutes)"
echo " Dump trigger  : ${CONSECUTIVE_REQUIRED} consecutive checks above threshold (10 minutes)"
echo " Log dir       : ${OUTPUT_DIR}/"
echo " Started at    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ─── Main loop ────────────────────────────────────────────────────────────────
while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Hourly log rotation
    CURRENT_HOUR=$(date +"%Y-%m-%d_%H")
    if [[ "$CURRENT_HOUR" != "$PREVIOUS_HOUR" ]]; then
        OUTPUT_FILE="${OUTPUT_DIR}/cpu_stats_${CURRENT_HOUR}.log"
        PREVIOUS_HOUR="$CURRENT_HOUR"
    fi

    # Get CPU% (takes 1s)
    CPU_PCT=$(get_cpu_pct)

    if [[ "$CPU_PCT" -gt "$THRESHOLD" ]]; then
        CONSECUTIVE_COUNT=$(( CONSECUTIVE_COUNT + 1 ))
        echo "[${TIMESTAMP}] CPU: ${CPU_PCT}% | Threshold: ${THRESHOLD}% | Consecutive: ${CONSECUTIVE_COUNT}/${CONSECUTIVE_REQUIRED} [ABOVE]" | tee -a "$OUTPUT_FILE"

        if [[ "$CONSECUTIVE_COUNT" -ge "$CONSECUTIVE_REQUIRED" ]]; then
            echo "[${TIMESTAMP}] [ALERT] CPU exceeded ${THRESHOLD}% for ${CONSECUTIVE_REQUIRED} consecutive checks. Collecting dump..." | tee -a "$OUTPUT_FILE"
            collectdump "$OUTPUT_FILE" "$INSTANCE" "$PID"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dump collected. Script completed." | tee -a "$OUTPUT_FILE"
            exit 0
        fi
    else
        if [[ "$CONSECUTIVE_COUNT" -gt 0 ]]; then
            echo "[${TIMESTAMP}] CPU: ${CPU_PCT}% | Threshold: ${THRESHOLD}% | Consecutive reset (was ${CONSECUTIVE_COUNT}/${CONSECUTIVE_REQUIRED})" | tee -a "$OUTPUT_FILE"
            CONSECUTIVE_COUNT=0
        else
            echo "[${TIMESTAMP}] CPU: ${CPU_PCT}% | Threshold: ${THRESHOLD}% | Consecutive: 0/${CONSECUTIVE_REQUIRED}" | tee -a "$OUTPUT_FILE"
        fi
    fi

    # Sleep remaining time (INTERVAL - 1s already spent in get_cpu_pct)
    sleep $(( INTERVAL - 1 ))
done
