#!/bin/bash

if ! command -v netstat &> /dev/null; then
    echo "Error: netstat is not installed. Please install net-tools."
    exit 1
fi

while true; do
    echo "Polling current connections (with process)..."
    echo "-----------------------------------------------------------------------------------------------------"
    printf "%-40s %-25s %-8s %s\n" "Remote Address:Port" "Process" "Total" "States (Count)"
    echo "-----------------------------------------------------------------------------------------------------"

    netstat -natp 2>/dev/null | awk '
    /ESTABLISHED|TIME_WAIT|CLOSE_WAIT|FIN_WAIT/ {
        split($4, laddr, ":");
        split($5, faddr, ":");

        # Handle IPv6
        if (length(laddr) > 2) localPort=laddr[length(laddr)];
        else localPort=laddr[2];

        if (length(faddr) > 2) foreignPort=faddr[length(faddr)];
        else foreignPort=faddr[2];

        process=$7;
        if (process == "-" || process == "") process="unknown";

        # Exclude incoming ports 80, 443, 2222
        if (localPort !~ /^(80|443|2222)$/)
            print $5, $6, process
    }' | sort | uniq -c | sort -rn | \
    awk '{
        key = $2 " " $4;   # remote + process
        remote = $2;
        state = $3;
        proc = $4;
        count = $1;

        total[key] += count;
        states[key] = states[key] " " state "(" count ")";
    }
    END {
        for (k in total) {
            split(k, arr, " ");
            remote = arr[1];
            proc = arr[2];

            printf "%-40s %-25s %-8d %s\n", remote, proc, total[k], states[k];
        }
    }' | sort -k3,3nr

    echo "-----------------------------------------------------------------------------------------------------"
    echo "Poll complete. Waiting for 10 seconds..."
    sleep 10
    echo ""
done
