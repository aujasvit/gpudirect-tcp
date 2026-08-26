import pandas as pd
import matplotlib.pyplot as plt
import sys

# -----------------------------
# CONFIGURATION
# -----------------------------

if (len(sys.argv) < 3):
    print("Usage: a.out input_file output_file")
    sys.exit(1)

csv_file = sys.argv[1]

x_col = "time_sec"

y1_col = "cwnd_kb"
y2_col = "rtt_us"

y1_label = "Congestion Window (KB)"
y2_label = "RTT (us)"

output_file = sys.argv[2]

# --- AXIS ZOOM CONTROL ---
# Set to None for automatic scaling
y1_min, y1_max = 100, 2000
y2_min, y2_max = 2000, 5000

# Example manual zoom:
# y1_min, y1_max = 930, 970
# y2_min, y2_max = 2100, 2350

# -----------------------------
# LOAD DATA
# -----------------------------
df = pd.read_csv(csv_file)

x = df[x_col]
y1 = df[y1_col]
y2 = df[y2_col]

# -----------------------------
# STYLE
# -----------------------------
plt.rcParams.update({
    "font.size": 9,
    "font.family": "serif",
})

fig, ax1 = plt.subplots(figsize=(3.5, 2.2))

# --- COLORS (colorblind-friendly, high contrast)
color1 = "#0072B2"  # blue
color2 = "#D55E00"  # orange

# Left axis
line1 = ax1.plot(
    x, y1,
    color=color1,
    linewidth=1.6,
    linestyle='-',
    label="cwnd"
)

ax1.set_xlabel("Time (s)")
ax1.set_ylabel(y1_label, color=color1)
ax1.tick_params(axis='y', colors=color1)

# Apply zoom if specified
if y1_min is not None and y1_max is not None:
    ax1.set_ylim(y1_min, y1_max)

# Right axis
ax2 = ax1.twinx()

line2 = ax2.plot(
    x, y2,
    color=color2,
    linewidth=1.6,
    linestyle='--',
    label="rtt"
)

ax2.set_ylabel(y2_label, color=color2)
ax2.tick_params(axis='y', colors=color2)

if y2_min is not None and y2_max is not None:
    ax2.set_ylim(y2_min, y2_max)

# Legend
lines = line1 + line2
labels = [l.get_label() for l in lines]
ax1.legend(lines, labels, loc="best", frameon=False)

# Cleanup
ax1.spines['top'].set_visible(False)
ax2.spines['top'].set_visible(False)
ax1.grid(True, linestyle=":", linewidth=0.5, alpha=0.7)

plt.tight_layout()

# Save
plt.savefig(output_file, dpi=600, bbox_inches="tight")
plt.close()
