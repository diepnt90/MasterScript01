#!/bin/bash
#
# This script is for monitoring the number of threads of a .NET core application.
# If the thread count exceeds a predefined threshold, then the script will automatically generate a memory dump and/or profiler trace for investigation.
#
# author: Tuan Hoang
# Updated: Mainul Hossain
# 12 Feb 2025

script_name=${0##*/}

function usage()
{
    echo "###Syntax: $script_name -t <threshold> [enable-dump|enable-trace|enable-dump-trace]"
    echo "- Without specifying -t <threshold>, the default will be 100 threads."
    echo "###Threshold: when the number of threads exceeds the threshold value in the working instance, the script will automatically take a memory dump and/or trace for that instance."
}

function die()
{
    echo "$1" && exit $2
}

function teardown()
{
    echo "Shutting down dotnet-counters collect process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-counters" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
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

while getopts ":t:hc" opt; do
    case $opt in
        t)
           threshold=$OPTARG
           ;;
        h)
           usage
           exit 0
           ;;
        c)
           clean_flag=1
           ;;
        *)
           die "Invalid option: -$OPTARG" 1
           ;;
    esac
done
shift $(( OPTIND - 1 ))

# Cleaning all processes generated by the script
if [[ "$clean_flag" -eq 1 ]]; then
    teardown
fi

# Define default threshold value for the number of threads
if [[ -z "$threshold" ]]; then
    echo "###Info: If not specify the option -t <threshold>, the script will set the default threshold of thread counts to 100"
    threshold=100
fi

# Initialize dump and trace flags
enable_dump=false
enable_trace=false
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

# Find the PID of the .NET application
pid=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [ -z "$pid" ]; then
    die "There is no .NET process running" 1
fi

# Get the computer name from /proc/PID/environ, where PID is .net core process's pid
instance=$(getcomputername "$pid")
if [[ -z "$instance" ]]; then
    die "Cannot find the environment variable of COMPUTERNAME" >&2 1
fi

# Output dir is named after instance name
output_dir="threadcount-logs-$instance"
# Create output directory if it doesn't exist
mkdir -p "$output_dir"

# Name of the lock files for generating memdump and trace (now instance-specific)
dump_lock_file="dump_taken_${instance}.lock"
trace_lock_file="trace_taken_${instance}.lock"
# Name of the file storing output of dotnet-counters collect
runtime_counter_log_file="dotnet-runtime-metrics-$instance.csv"

# Collect the .NET process' runtime metrics by starting the dotnet-counters collect command in background
/tools/dotnet-counters collect --process-id "$pid" --counters System.Runtime --output "$runtime_counter_log_file" > /dev/null &

# Wait until the dotnet-counters collect start writing its collected data to the output file
while [[ ! -e "$runtime_counter_log_file" ]]; do
   sleep 1
done

# Function to truncate collected metric data file
function trunc() {
    MAX_SIZE=$(( 1*1024*1024 )) # 1 MB
    while [[ -f "$1" ]]; do
        file_size=$(stat -c%s "$1")
        if [[ "$file_size" -ge "$MAX_SIZE" ]]; then
            #truncate the file
            truncate -s 0 "$1"
        fi
    done
}

# Start monitoring
if [[ -e "$runtime_counter_log_file" ]]; then
    # Start a thread to monitor the size of $runtime_counter_log_file & truncate it
    trunc "$runtime_counter_log_file" &
    
    # Reading metric data in $runtime_counter_log_file to extract threadcount information
    tail -f "$runtime_counter_log_file" | while read -r line; do
        # Check if it's a new hour for rotating logs
        current_hour=$(date +"%Y-%m-%d_%H")
        if [ "$current_hour" != "$previous_hour" ]; then
            # Rotate the file
            output_file="$output_dir/threadcount_${current_hour}.log"
            previous_hour="$current_hour"
        fi
        
        if [[ $line == *"ThreadPool Thread Count"* ]]; then
            thread_count=$(echo "$line" | awk -F ',' '{print $NF}')
            timestamp=$(echo "$line" | awk -F ',' '{print $1}')
            echo "$timestamp: Thread Pool Thread Count: $thread_count" >> "$output_file"
            
            # Compare with the threshold value and collect dump/trace if exceeded
            if [[ "$thread_count" -ge "$threshold" ]]; then
                if [[ "$enable_dump" == true ]]; then
                    collectdump "$output_file" "$dump_lock_file" "$instance" "$pid" &
                fi
                
                if [[ "$enable_trace" == true ]]; then
                    collecttrace "$output_file" "$trace_lock_file" "$instance" "$pid" &
                fi
            fi
        fi
    done
fi
