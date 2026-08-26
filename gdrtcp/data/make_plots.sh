#!/usr/bin/env bash

set -euo pipefail

# Create output directory
mkdir -p output

# Loop over experiment folders
for dir in exp*; do
    # Skip if not a directory
    [[ -d "$dir" ]] || continue

    # Extract experiment index (e.g., exp3 -> 3)
    exp_num="${dir#exp}"

    input_file="$dir/data.csv"

    # Skip if data file doesn't exist
    if [[ ! -f "$input_file" ]]; then
        echo "Warning: $input_file not found, skipping..."
        continue
    fi

    echo "Processing $dir..."

    # Run plotting scripts
    python plot_tp_rtt_var.py "$input_file" "output/exp${exp_num}_1.png"
    python plot_rtt_cwnd.py   "$input_file" "output/exp${exp_num}_2.png"
    python cpu_plot.py        "$input_file" "output/exp${exp_num}_3.png"
done

echo "All plots generated in ./output/"
