#!/bin/bash
#
# Combined Diagnostics Script for Thread Count, Response Time, Outbound Connections,
# Memory Usage and GCDump monitoring.
# Allows user to select which diagnostics to run and provides additional input as needed.
# Author: Mainul Hossain and Anh Tuan Hoang
# Created: 10 July 2024
# Updated: January 21, 2025

# Get the script's name
master_script_name=${0##*/}

# Usage function to display help
function usage() {
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "Syntax: $master_script_name -d <diagnostics> -t <threshold> [-l <URL>] [-c] [-h] [enable-trace | enable-dump | enable-dump-trace]"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "-d <diagnostics> specifies which diagnostic to run. The diagnostics can be one of following:"
    echo "  - threadcount       :  Monitor thread count of a .NET core application"
    echo "  - responsetime      :  Monitor response time of a .NET core application"
    echo "  - outboundconnection:  Monitor outbound connections"
    echo "  - memoryusage       :  Monitor memory usage and collect dumps at two thresholds"
    echo "  - gcdump            :  Monitor memory usage and collect gcdumps at three thresholds, zip reports and upload
  - cpuusage          :  Monitor CPU usage and collect dump after 5 consecutive checks above threshold (10 minutes)"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "Other script options:"
    echo "  -t <threshold>  :  Specify threshold (required for threadcount, responsetime, outboundconnection)"
    echo "  -t1 <percent>   :  First threshold in %  (required for memoryusage and gcdump)"
    echo "  -t2 <percent>   :  Second threshold in % (required for memoryusage and gcdump)"
    echo "  -t3 <percent>   :  Third threshold in %  (required for gcdump only)"
    echo "  -l <URL>        :  Specify URL to monitor (default: http://localhost:80 for responsetime only)
  -e <email>      :  Email address to notify when dump/trace/gcdump is collected (optional)"
    echo "  -c              :  Shutting down the script and all relevant processes"
    echo "  -h              :  Display this help message"
    echo "Optional arguments for threadcount, responsetime, outboundconnection:"
    echo "  enable-dump        :  Enable memory dump collection when threshold is exceeded"
    echo "  enable-trace       :  Enable profiler trace collection when threshold is exceeded"
    echo "  enable-dump-trace  :  Enable both memdump and trace collection when threshold is exceeded"
    exit 0
}

NOTIFY_EMAIL=""

# Parse arguments
while getopts ":d:t:l:e:ch" opt; do
    case $opt in
        d) DIAGNOSTIC=$OPTARG ;;
        t) THRESHOLD=$OPTARG ;;
        l) URL=$OPTARG ;;
        e) NOTIFY_EMAIL=$OPTARG ;;
        c) CLEANUP=true ;;
        h) usage ;;
        \?) echo "Invalid option -$OPTARG" >&2; usage ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

# Handle -t1 / -t2 / -t3 from remaining args (getopts doesn't support multi-char flags)
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t1) MEM_THRESHOLD1="$2"; shift 2 ;;
        -t2) MEM_THRESHOLD2="$2"; shift 2 ;;
        -t3) MEM_THRESHOLD3="$2"; shift 2 ;;
        enable-dump|enable-trace|enable-dump-trace)
            DIAG_OPTION="$1"; shift ;;
        *) shift ;;
    esac
done

# Check if cleanup is requested
if [ "$CLEANUP" = true ]; then
    echo "Stopping all diagnostic scripts..."
    ./threadcount/netcore_threadcount_monitoring.sh -c 2>/dev/null
    ./responsetime/resp_monitoring.sh -c 2>/dev/null
    ./outboundconnection/snat_connection_monitoring.sh -c 2>/dev/null
    ./memoryusage/mem_monitor.sh -c 2>/dev/null
    ./gcdump/gcdump_monitor.sh -c 2>/dev/null
    ./cpuusage/cpu_monitor.sh -c 2>/dev/null
    kill -SIGTERM $(ps -ef | grep "$master_script_name" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    exit 0
fi

# Interactive input if no diagnostic type is provided
if [ -z "$DIAGNOSTIC" ]; then
    echo "Select diagnostic type:"
    echo "1. threadcount"
    echo "2. responsetime"
    echo "3. outboundconnection"
    echo "4. Memory Monitoring"
    echo "5. gcdump"
    echo "6. CPU Monitoring"
    read -p "Enter choice [1-6]: " diag_choice

    case $diag_choice in
        1) DIAGNOSTIC="threadcount" ;;
        2) DIAGNOSTIC="responsetime" ;;
        3) DIAGNOSTIC="outboundconnection" ;;
        4) DIAGNOSTIC="memoryusage" ;;
        5) DIAGNOSTIC="gcdump" ;;
        6) DIAGNOSTIC="cpuusage" ;;
        *) echo "Invalid choice." ; exit 1 ;;
    esac
fi

# ─── memoryusage: get and validate thresholds ────────────────────────────────
if [ "$DIAGNOSTIC" == "memoryusage" ]; then
    while true; do
        [ -z "$MEM_THRESHOLD1" ] && read -p "Enter memory threshold 1 (%) - first dump, monitoring continues: " MEM_THRESHOLD1
        [ -z "$MEM_THRESHOLD2" ] && read -p "Enter memory threshold 2 (%) - second dump, then script exits: " MEM_THRESHOLD2

        # Validate integers
        if ! [[ "$MEM_THRESHOLD1" =~ ^[0-9]+$ ]] || [[ "$MEM_THRESHOLD1" -lt 1 ]] || [[ "$MEM_THRESHOLD1" -gt 100 ]]; then
            echo "[ERROR] Threshold 1 must be an integer between 1 and 100 (received: $MEM_THRESHOLD1)"
            MEM_THRESHOLD1=""
            MEM_THRESHOLD2=""
            continue
        fi
        if ! [[ "$MEM_THRESHOLD2" =~ ^[0-9]+$ ]] || [[ "$MEM_THRESHOLD2" -lt 1 ]] || [[ "$MEM_THRESHOLD2" -gt 100 ]]; then
            echo "[ERROR] Threshold 2 must be an integer between 1 and 100 (received: $MEM_THRESHOLD2)"
            MEM_THRESHOLD2=""
            continue
        fi
        if [[ "$MEM_THRESHOLD1" -ge "$MEM_THRESHOLD2" ]]; then
            echo "[ERROR] Threshold 1 ($MEM_THRESHOLD1%) must be less than threshold 2 ($MEM_THRESHOLD2%). Please re-enter."
            MEM_THRESHOLD1=""
            MEM_THRESHOLD2=""
            continue
        fi
        break
    done
fi

# ─── gcdump: get thresholds interactively if not provided ────────────────────
if [ "$DIAGNOSTIC" == "gcdump" ]; then
    if [ -z "$MEM_THRESHOLD1" ]; then
        read -p "Enter memory threshold 1 (%) - collect gcdump #1, monitoring continues: " MEM_THRESHOLD1
    fi
    if [ -z "$MEM_THRESHOLD2" ]; then
        read -p "Enter memory threshold 2 (%) - collect gcdump #2, monitoring continues: " MEM_THRESHOLD2
    fi
    if [ -z "$MEM_THRESHOLD3" ]; then
        read -p "Enter memory threshold 3 (%) - collect gcdump #3, zip reports + upload, then exit: " MEM_THRESHOLD3
    fi
fi

# ─── Other diagnostics: get threshold if not provided ────────────────────────
if [ "$DIAGNOSTIC" != "memoryusage" ] && [ "$DIAGNOSTIC" != "gcdump" ] && [ "$DIAGNOSTIC" != "cpuusage" ] && [ -z "$THRESHOLD" ]; then
    read -p "Enter threshold: " THRESHOLD
fi

# Get URL for responsetime if not provided
if [ "$DIAGNOSTIC" == "responsetime" ] && [ -z "$URL" ]; then
    read -p "Enter URL to monitor (default: http://localhost:80): " URL
    URL=${URL:-http://localhost:80}
fi

# Handle diagnostic options (dump/trace) for non-memory/gcdump diagnostics
if [ "$DIAGNOSTIC" != "memoryusage" ] && [ "$DIAGNOSTIC" != "gcdump" ] && [ "$DIAGNOSTIC" != "cpuusage" ] && [ -z "$DIAG_OPTION" ]; then
    echo "Enable additional options (default: none):"
    echo "1. enable-dump"
    echo "2. enable-trace"
    echo "3. enable-dump-trace"
    read -p "Enter choice [1-3]: " diag_option_choice

    case $diag_option_choice in
        1) DIAG_OPTION="enable-dump" ;;
        2) DIAG_OPTION="enable-trace" ;;
        3) DIAG_OPTION="enable-dump-trace" ;;
        *) echo "Invalid choice." ; exit 1 ;;
    esac
fi

# ─── cpu: get threshold if not provided ──────────────────────────────────────
if [ "$DIAGNOSTIC" == "cpuusage" ]; then
    if [ -z "$THRESHOLD" ]; then
        read -p "Enter CPU threshold (%) - dump after 5 consecutive checks above threshold: " THRESHOLD
    fi
fi

# ─── Ask for notification email if not provided
if [ -z "$NOTIFY_EMAIL" ]; then
    read -p "Enter email for notification (leave blank to skip): " NOTIFY_EMAIL
fi

# Define URLs for the diagnostic scripts
THREADCOUNT_SCRIPT_URL="https://raw.githubusercontent.com/diepnt90/MasterScript01/refs/heads/main/netcore_threadcount_monitoring.sh"
RESPONSETIME_SCRIPT_URL="https://raw.githubusercontent.com/diepnt90/MasterScript01/refs/heads/main/resp_monitoring.sh"
SNAT_CONNECTION_MONITORING_SCRIPT_URL="https://raw.githubusercontent.com/diepnt90/MasterScript01/refs/heads/main/snat_connection_monitoring.sh"
MEM_MONITOR_SCRIPT_URL="https://raw.githubusercontent.com/diepnt90/MasterScript01/refs/heads/main/mem_monitor.sh"
GCDUMP_MONITOR_SCRIPT_URL="https://raw.githubusercontent.com/diepnt90/MasterScript01/refs/heads/main/gcdump_monitor.sh"
CPU_MONITOR_SCRIPT_URL="https://raw.githubusercontent.com/diepnt90/MasterScript01/refs/heads/main/cpu_monitor.sh"

# Check if curl is installed, if not install it
if ! command -v curl &> /dev/null; then
    echo "curl could not be found, installing it now..."
    apt-get update && apt-get install -y curl &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Failed to install curl. Please install it manually and rerun the script."
        exit 1
    fi
    echo "curl has been successfully installed"
fi

# Function to download and execute the diagnostic scripts
function run_diagnostic_script() {
    local folder_name=$1
    shift
    local script_urls=("$@")

    # Create folder and navigate to it
    mkdir -p ./$folder_name
    cd ./$folder_name

    # Download the scripts if not already downloaded
    for script_url in "${script_urls[@]}"; do
        local diagnostic_script_name=$(basename $script_url)
        if [ ! -f $diagnostic_script_name ]; then
            echo "Downloading $diagnostic_script_name..."
            curl -L -o $diagnostic_script_name $script_url &> /dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to download the dependent script at $script_url"
                exit 1
            fi
            chmod +x $diagnostic_script_name
        fi
    done

    # Run the script with the constructed arguments
    nohup ./${script_urls[0]##*/} "${cmd_args[@]}" &
}

# Initialize command arguments array
cmd_args=()

# Build command arguments based on diagnostic type
case $DIAGNOSTIC in
    threadcount)
        cmd_args+=("-t" "$THRESHOLD")
        if [ -n "$NOTIFY_EMAIL" ]; then cmd_args+=("-e" "$NOTIFY_EMAIL"); fi
        if [ -n "$DIAG_OPTION" ]; then
            cmd_args+=("$DIAG_OPTION")
        fi
        run_diagnostic_script "threadcount" $THREADCOUNT_SCRIPT_URL
        ;;
    responsetime)
        cmd_args+=("-t" "$THRESHOLD")
        if [ -n "$URL" ]; then cmd_args+=("-l" "$URL"); fi
        if [ -n "$NOTIFY_EMAIL" ]; then cmd_args+=("-e" "$NOTIFY_EMAIL"); fi
        if [ -n "$DIAG_OPTION" ]; then
            cmd_args+=("$DIAG_OPTION")
        fi
        run_diagnostic_script "responsetime" $RESPONSETIME_SCRIPT_URL
        ;;
    outboundconnection)
        cmd_args+=("-t" "$THRESHOLD")
        if [ -n "$NOTIFY_EMAIL" ]; then cmd_args+=("-e" "$NOTIFY_EMAIL"); fi
        if [ -n "$DIAG_OPTION" ]; then
            cmd_args+=("$DIAG_OPTION")
        fi
        run_diagnostic_script "outboundconnection" $SNAT_CONNECTION_MONITORING_SCRIPT_URL
        ;;
    memoryusage)
        cmd_args+=("-t1" "$MEM_THRESHOLD1" "-t2" "$MEM_THRESHOLD2")
        if [ -n "$NOTIFY_EMAIL" ]; then cmd_args+=("-e" "$NOTIFY_EMAIL"); fi
        run_diagnostic_script "memoryusage" $MEM_MONITOR_SCRIPT_URL
        ;;
    gcdump)
        cmd_args+=("-t1" "$MEM_THRESHOLD1" "-t2" "$MEM_THRESHOLD2" "-t3" "$MEM_THRESHOLD3")
        if [ -n "$NOTIFY_EMAIL" ]; then cmd_args+=("-e" "$NOTIFY_EMAIL"); fi
        run_diagnostic_script "gcdump" $GCDUMP_MONITOR_SCRIPT_URL
        ;;
    cpuusage)
        cmd_args+=("-t" "$THRESHOLD")
        if [ -n "$NOTIFY_EMAIL" ]; then cmd_args+=("-e" "$NOTIFY_EMAIL"); fi
        run_diagnostic_script "cpuusage" $CPU_MONITOR_SCRIPT_URL
        ;;
    *)
        echo "Invalid diagnostic type: $DIAGNOSTIC"
        usage
        ;;
esac

echo "Diagnostic script execution initiated."

# To stop script
# ./master_monitoring.sh -c
