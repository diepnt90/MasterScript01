#!/bin/bash
#
# This script is for monitoring outbound connections of a .NET core application.
# If the number of outbound connections exceeds a predefined threshold, 
# then the script will automatically generate a memory dump and/or profiler trace for investigation.
# Script combined from work of : Ander Wahlqvist and Tuan Hoang 
# Author: Mainul Hossain
# Created: January 21, 2025
# Updated: 12 Feb 2025

script_name=${0##*/}

function usage()
{
    echo "###Syntax: $script_name -t <threshold> -f <interval>"
    echo "-t <threshold> tells the threshold of outbound connections to collect dump/trace, if not given then will be defaulted to 100"
    echo "-f <interval> tells how frequent (in second) to poll the connections, if not given, then will poll every 10s"
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
    # kill relevant process
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
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been collected. Uploading it to Azure Blob Container 'insights-logs-appserviceconsolelogs'" >> "$1"

        # Initial attempt
        azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been successfully uploaded to Azure Blob Container." >> "$1"
            return 0
        fi

        # If initial attempt fails, start retry logic
        local retry_count=1
        local max_retries=5
        
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy failed to upload memory dump. Retrying... (Attempt $retry_count/$max_retries)" >> "$1"
            sleep 5
            
            azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been successfully uploaded to Azure Blob Container." >> "$1"
                return 0
            fi
            
            ((retry_count++))
        done

        # If we get here, all retries failed
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
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been collected. Uploading it to Azure Blob Container 'insights-logs-appserviceconsolelogs'" >> "$1"

        # Initial attempt
        azcopy_output=$(/tools/azcopy copy "$trace_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been successfully uploaded to Azure Blob Container." >> "$1"
            return 0
        fi

        # If initial attempt fails, start retry logic
        local retry_count=1
        local max_retries=5
        
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy failed to upload profiler trace. Retrying... (Attempt $retry_count/$max_retries)" >> "$1"
            sleep 5
            
            azcopy_output=$(/tools/azcopy copy "$trace_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been successfully uploaded to Azure Blob Container." >> "$1"
                return 0
            fi
            
            ((retry_count++))
        done

        # If we get here, all retries failed
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

# Parse command line arguments
while getopts ":t:f:hc" opt; do
    case $opt in
        t) 
           threshold=$OPTARG
           ;;
        f)
           frequency=$OPTARG
           ;;
        h)
           usage
           exit 0
           ;;
        c)
           clean_flag=1
           ;;
        *) 
           die "Invalid option: -$OPTARG" 1 >&2
           ;;
    esac
done
shift $(( OPTIND - 1 ))

# Initialize diagnostic collection flags
enable_dump=false
enable_trace=false

# Process additional arguments after options
if [[ "$#" -gt 0 ]]; then
    case $1 in
        enable-dump)
            enable_dump=true
            ;;
        enable-trace)
            enable_trace=true
            ;;
        enable-dump-trace)
            enable_dump=true
            enable_trace=true
            ;;
        *)
            die "Unknown argument passed: $1" 1
            ;;
    esac
fi

# Cleaning all processes generated by the script
if [[ "$clean_flag" -eq 1 ]]; then
    teardown
fi

# Set default values if not provided
if [[ -z "$threshold" ]]; then
    echo "###Info: without specifying option -t <threshold>, the script will set the default outbound connection count to 100 before triggering memory dump/trace"
    threshold=100
fi

if [[ -z "$frequency" ]]; then
    echo "###Info: without specifying option -f <interval>, the script will execute every 10s"
    frequency=10
fi

# Install net-tools if not exists
if ! command -v netstat &> /dev/null; then
    echo "###Info: netstat is not installed. Installing net-tools."
    apt-get update && apt-get install -y net-tools
fi

# Find the PID of the .NET application
pid=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [ -z "$pid" ]; then
    die "There is no .NET process running" 1
fi

# Get instance name
instance=$(getcomputername "$pid")
if [[ -z "$instance" ]]; then
    die "Cannot find the environment variable of COMPUTERNAME" >&2 1
fi

# Setup output directory and files
output_dir="outconn-logs-${instance}"
mkdir -p "$output_dir"

# Now using instance-specific lock files
dump_lock_file="dump_taken_${instance}.lock"
trace_lock_file="trace_taken_${instance}.lock"

# Start monitoring
while true; do
    # Check if it's a new hour for rotating logs
    current_hour=$(date +"%Y-%m-%d_%H")
    if [ "$current_hour" != "$previous_hour" ]; then
        output_file="$output_dir/outbound_conns_stats_${current_hour}.log"
        previous_hour="$current_hour"
    fi

    # Monitor connections and check if threshold is exceeded
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
    
    # Wait for next iteration
    sleep $frequency
done
