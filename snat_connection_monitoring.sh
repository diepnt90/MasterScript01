#!/bin/bash
#
# This script is for monitoring outbound connections of a .NET core application.
# If the number of outbound connections exceeds a predefined threshold, 
# then the script will automatically generate a memory dump and/or profiler trace for investigation.
# Script combined from work of : Ander Wahlqvist and Tuan Hoang 
# Author: Diep Nguyen
# Created: 17 Mar 2026
# Updated: 17 Mar 2026

script_name=${0##*/}

function usage()
{
    echo "###Syntax: $script_name -t <threshold> -f <interval> [-e <email>]"
    echo "-t <threshold> tells the threshold of outbound connections to collect dump/trace, if not given then will be defaulted to 100"
    echo "-f <interval> tells how frequent (in second) to poll the connections, if not given, then will poll every 10s"
    echo "-e <email> email address to notify when dump/trace is collected (optional)"
    echo "Additional arguments:"
    echo "  enable-dump        Enable memory dump collection when threshold is exceeded"
    echo "  enable-trace       Enable profiler trace collection when threshold is exceeded"
    echo "  enable-dump-trace  Enable both memory dump and profiler trace collection"
}

function die()
{
    echo "$1" && exit $2
}

function teardown()
{
    echo "Shutting down 'dotnet-trace collect' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-trace" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down 'dotnet-dump collect' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-dump" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down 'azcopy copy' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/azcopy" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down $script_name process..."
    kill -SIGTERM $(ps -ef | grep "$script_name" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Finishing up..."
    echo "Completed"
    exit 0
}

function getcomputername()
{
    # $1-pid
    instance=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w COMPUTERNAME)
    instance=${instance#*=}
    echo "$instance"
}

function getsasurl()
{
    # $1-pid
    sas_url=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL)
    sas_url=${sas_url#*=}
    echo "$sas_url"
}

function getwebsitename()
{
    # $1-pid
    local site
    site=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w WEBSITE_SITE_NAME)
    site=${site#*=}
    echo "${site:0:6}"
}

function sendemail()
{
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
            \"api_key\": \"api-3A3D49C1F24C4BB086727C18615A0353\" ,
            \"to\": [\"$NOTIFY_EMAIL\"],
            \"sender\": \"IMtool@daulac.my\",
            \"subject\": \"$subject\",
            \"text_body\": \"$body\"
        }" 2>&1)
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Email notification sent to $NOTIFY_EMAIL. Response: $response" >> "$output_file"
}

function collectdump()
{
    # $1-$output_file, $2-$dump_lock_file, $3-$instance, $4-$pid
    local instance_lock_file="dump_taken_${3}.lock"
    if [[ ! -e "$instance_lock_file" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Acquiring lock for dumping..." >> "$1" && touch "$instance_lock_file" && echo "Memory dump is collected by $3" >> "$instance_lock_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting memory dump..." >> "$1"
        local dump_file="dump_$3_$(date '+%Y%m%d_%H%M%S').dmp"
        local sas_url=$(getsasurl "$4")
        /tools/dotnet-dump collect -p "$4" -o "$dump_file" > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been collected. Uploading it to Azure Blob Container." >> "$1"

        azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been successfully uploaded to Azure Blob Container." >> "$1"
            sendemail "Successfully got dump for ${SITE_NAME} - ${3}" "File ${dump_file} has been uploaded to Azure Blob Container." "$1"
            return 0
        fi

        local retry_count=1
        local max_retries=5
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy failed to upload memory dump. Retrying... (Attempt $retry_count/$max_retries)" >> "$1"
            sleep 5
            azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been successfully uploaded to Azure Blob Container." >> "$1"
                sendemail "Successfully got dump for ${SITE_NAME} - ${3}" "File ${dump_file} has been uploaded to Azure Blob Container." "$1"
                return 0
            fi
            ((retry_count++))
        done
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: AzCopy failed to upload memory dump after $max_retries attempts." >> "$1"
    fi
}

function collecttrace()
{
    # $1-$output_file, $2-$trace_lock_file, $3-$instance, $4-$pid
    local instance_lock_file="trace_taken_${3}.lock"
    if [[ ! -e "$instance_lock_file" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Acquiring lock for tracing..." >> "$1" && touch "$instance_lock_file" && echo "Profiler trace is collected by $3" >> "$instance_lock_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting profiler trace..." >> "$1"
        local trace_file="trace_$3_$(date '+%Y%m%d_%H%M%S').nettrace"
        local sas_url=$(getsasurl "$4")
        /tools/dotnet-trace collect -p "$4" -o "$trace_file" --duration 00:01:00 > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been collected. Uploading it to Azure Blob Container." >> "$1"

        azcopy_output=$(/tools/azcopy copy "$trace_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been successfully uploaded to Azure Blob Container." >> "$1"
            sendemail "Successfully got dump for ${SITE_NAME} - ${3}" "File ${trace_file} has been uploaded to Azure Blob Container." "$1"
            return 0
        fi

        local retry_count=1
        local max_retries=5
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy failed to upload profiler trace. Retrying... (Attempt $retry_count/$max_retries)" >> "$1"
            sleep 5
            azcopy_output=$(/tools/azcopy copy "$trace_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been successfully uploaded to Azure Blob Container." >> "$1"
                sendemail "Successfully got dump for ${SITE_NAME} - ${3}" "File ${trace_file} has been uploaded to Azure Blob Container." "$1"
                return 0
            fi
            ((retry_count++))
        done
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: AzCopy failed to upload profiler trace after $max_retries attempts." >> "$1"
    fi
}

function monitor_connections() {
    # $1-$output_file, $2-threshold
    echo "--------------------------------------------------------------------------------" >> "$1"
    printf "%-45s %-8s %s\n" "Remote Address:Port" "Total" "States (Count)" >> "$1"
    echo "--------------------------------------------------------------------------------" >> "$1"

    netstat -natp | awk '/ESTABLISHED|TIME_WAIT|CLOSE_WAIT|FIN_WAIT/ {
        split($4, laddr, ":");
        split($5, faddr, ":");
        if (length(laddr) > 2) {
            localPort=laddr[length(laddr)];
        } else {
            localPort=laddr[2];
        }
        if (length(faddr) > 2) {
            foreignPort=faddr[length(faddr)];
        } else {
            foreignPort=faddr[2];
        }
        if (localPort !~ /^(80|443|2222)$/)
            print $5, $6
    }' | sort | uniq -c | sort -rn | \
    awk -v threshold="$2" '
    {
        remote_addr_state[$2 " " $3]+=$1;
        remote_addr_total[$2]+=$1;
        states[$2]=states[$2] " " $3 "(" $1 ")";
    }
    END {
        max_connection_count=0
        for (remote_addr in remote_addr_total) {
            if (remote_addr_total[remote_addr]>max_connection_count) {
                max_connection_count=remote_addr_total[remote_addr]
            }
            printf "%-45s %-8d %s\n", remote_addr, remote_addr_total[remote_addr], states[remote_addr]
        }
        if (max_connection_count>threshold) {
            exit 1
        }
        exit 0
    }' >> "$1"

    return $?
}

NOTIFY_EMAIL=""

while getopts ":t:f:e:hc" opt; do
    case $opt in
        t) threshold=$OPTARG ;;
        f) frequency=$OPTARG ;;
        e) NOTIFY_EMAIL=$OPTARG ;;
        h) usage; exit 0 ;;
        c) clean_flag=1 ;;
        *) die "Invalid option: -$OPTARG" 1 >&2 ;;
    esac
done
shift $(( OPTIND - 1 ))

enable_dump=false
enable_trace=false

if [[ "$#" -gt 0 ]]; then
    case $1 in
        enable-dump)       enable_dump=true ;;
        enable-trace)      enable_trace=true ;;
        enable-dump-trace) enable_dump=true; enable_trace=true ;;
        *)                 die "Unknown argument passed: $1" 1 ;;
    esac
fi

if [[ "$clean_flag" -eq 1 ]]; then
    teardown
fi

if [[ -z "$threshold" ]]; then
    echo "###Info: without specifying option -t <threshold>, the script will set the default outbound connection count to 100 before triggering memory dump/trace"
    threshold=100
fi

if [[ -z "$frequency" ]]; then
    echo "###Info: without specifying option -f <interval>, the script will execute every 10s"
    frequency=10
fi

if ! command -v netstat &> /dev/null; then
    echo "###Info: netstat is not installed. Installing net-tools."
    apt-get update && apt-get install -y net-tools
fi

pid=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [ -z "$pid" ]; then
    die "There is no .NET process running" 1
fi

instance=$(getcomputername "$pid")
if [[ -z "$instance" ]]; then
    die "Cannot find the environment variable of COMPUTERNAME" >&2 1
fi

SITE_NAME=$(getwebsitename "$pid")

output_dir="outconn-logs-${instance}"
mkdir -p "$output_dir"

dump_lock_file="dump_taken_${instance}.lock"
trace_lock_file="trace_taken_${instance}.lock"

while true; do
    current_hour=$(date +"%Y-%m-%d_%H")
    if [ "$current_hour" != "$previous_hour" ]; then
        output_file="$output_dir/outbound_conns_stats_${current_hour}.log"
        previous_hour="$current_hour"
    fi

    if monitor_connections "$output_file" "$threshold"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Connection count within threshold" >> "$output_file"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Connection threshold exceeded" >> "$output_file"

        if [[ "$enable_dump" == true ]]; then
            collectdump "$output_file" "$dump_lock_file" "$instance" "$pid" &
        fi

        if [[ "$enable_trace" == true ]]; then
            collecttrace "$output_file" "$trace_lock_file" "$instance" "$pid" &
        fi
    fi

    echo "--------------------------------------------------------------------------------" >> "$output_file"
    echo "Current timestamp: $(date '+%Y-%m-%d %H:%M:%S')" >> "$output_file"

    sleep $frequency
done
