#!/bin/bash
#
# Combined Diagnostics Script for Thread Count, Response Time and Outbound Connections monitoring.
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
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "Other script options:"
    echo "  -t <threshold>:  Specify threshold (required for all diagnostics)"
    echo "  -l <URL>      :  Specify URL to monitor (default: http://localhost:80 for responsetime only)"
    echo "  -c            :  Shutting down the script and all relevant processes"
    echo "  -h            :  Display this help message"
    echo "Optional arguments for all diagnostics:"
    echo "  enable-dump        :  Enable memory dump collection when threshold is exceeded"
    echo "  enable-trace       :  Enable profiler trace collection when threshold is exceeded"
    echo "  enable-dump-trace  :  Enable both memdump and trace collection when threshold is exceeded"
    exit 0
}

# Parse arguments
while getopts ":d:t:l:ch" opt; do
    case $opt in
        d) DIAGNOSTIC=$OPTARG ;;
        t) THRESHOLD=$OPTARG ;;
        l) URL=$OPTARG ;;
        c) CLEANUP=true ;;
        h) usage ;;
        \?) echo "Invalid option -$OPTARG" >&2; usage ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

# Check if cleanup is requested
if [ "$CLEANUP" = true ]; then
    echo "Stopping all diagnostic scripts..."
    ./threadcount/netcore_threadcount_monitoring.sh -c 2>/dev/null
    ./responsetime/resp_monitoring.sh -c 2>/dev/null
    ./outboundconnection/snat_connection_monitoring.sh -c 2>/dev/null
    kill -SIGTERM $(ps -ef | grep "$master_script_name" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    exit 0
fi

# Interactive input if no diagnostic type is provided
if [ -z "$DIAGNOSTIC" ]; then
    echo "Select diagnostic type:"
    echo "1. threadcount"
    echo "2. responsetime"
    echo "3. outboundconnection"
    read -p "Enter choice [1-3]: " diag_choice

    case $diag_choice in
        1) DIAGNOSTIC="threadcount" ;;
        2) DIAGNOSTIC="responsetime" ;;
        3) DIAGNOSTIC="outboundconnection" ;;
        *) echo "Invalid choice." ; exit 1 ;;
    esac
fi

# Get threshold if not provided
if [ -z "$THRESHOLD" ]; then
    read -p "Enter threshold: " THRESHOLD
fi

# Get URL for responsetime if not provided
if [ "$DIAGNOSTIC" == "responsetime" ] && [ -z "$URL" ]; then
    read -p "Enter URL to monitor (default: http://localhost:80): " URL
    URL=${URL:-http://localhost:80}
fi

# Handle diagnostic options for all monitoring types
if [ -z "$1" ]; then
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
else
    while (( "$#" )); do
        if [ "$1" == "enable-dump" ] || [ "$1" == "enable-trace" ] || [ "$1" == "enable-dump-trace" ]; then
            DIAG_OPTION="$1"
            break
        fi
        shift
    done
fi

# Define URLs for the diagnostic scripts
THREADCOUNT_SCRIPT_URL="https://raw.githubusercontent.com/bkstar123/netcore_counters_monitoring/refs/heads/master/netcore_threadcount_monitoring.sh"
RESPONSETIME_SCRIPT_URL="https://raw.githubusercontent.com/bkstar123/http_response_time_monitoring/refs/heads/master/resp_monitoring.sh"
SNAT_CONNECTION_MONITORING_SCRIPT_URL="https://raw.githubusercontent.com/bkstar123/outbound_connection_monitoring/refs/heads/master/snat_connection_monitoring.sh"

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
        if [ -n "$DIAG_OPTION" ]; then
            cmd_args+=("$DIAG_OPTION")
        fi
        run_diagnostic_script "threadcount" $THREADCOUNT_SCRIPT_URL
        ;;
    responsetime)
        cmd_args+=("-t" "$THRESHOLD")
        if [ -n "$URL" ]; then
            cmd_args+=("-l" "$URL")
        fi
        if [ -n "$DIAG_OPTION" ]; then
            cmd_args+=("$DIAG_OPTION")
        fi
        run_diagnostic_script "responsetime" $RESPONSETIME_SCRIPT_URL
        ;;
    outboundconnection)
        cmd_args+=("-t" "$THRESHOLD")
        if [ -n "$DIAG_OPTION" ]; then
            cmd_args+=("$DIAG_OPTION")
        fi
        run_diagnostic_script "outboundconnection" $SNAT_CONNECTION_MONITORING_SCRIPT_URL
        ;;
    *)
        echo "Invalid diagnostic type: $DIAGNOSTIC"
        usage
        ;;
esac

echo "Diagnostic script execution initiated."

# To stop script
# ./master_monitoring.sh -c
