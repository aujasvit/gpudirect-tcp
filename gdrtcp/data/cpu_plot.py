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
anchor_col = "total_cpu"

output_file = sys.argv[2]

# -----------------------------
# LOAD DATA
# -----------------------------
df = pd.read_csv(csv_file)

x = df[x_col]

cols = list(df.columns)
anchor_idx = cols.index(anchor_col)

# Include total_cpu + everything after
y_cols = cols[anchor_idx:]

# -----------------------------
# STYLE
# -----------------------------
plt.rcParams.update({
    "font.size": 9,
    "font.family": "serif",
})

fig, ax = plt.subplots(figsize=(3.5, 2.2))

colors = [
    "#0072B2", "#D55E00", "#009E73",
    "#CC79A7", "#F0E442", "#56B4E9"
]

# -----------------------------
# PLOTTING
# -----------------------------
lines = []

color_idx = 0

for col in y_cols:
    if col == anchor_col:
        # --- Continuous, subtle overlay ---
        line, = ax.plot(
            x,
            df[col],
            label=col,
            color="#222222",   # softer than pure black
            linewidth=1.7,     # slightly thinner than before
            linestyle="-.",     # continuous line
            alpha=0.85,        # allows overlap visibility
            zorder=5           # clearly on top
        )
    else:
        line, = ax.plot(
            x,
            df[col],
            label=col,
            color=colors[color_idx % len(colors)],
            linestyle="-",
            linewidth=1.5,
            alpha=0.95,
            zorder=2
        )
        color_idx += 1

    lines.append(line)

# -----------------------------
# AXES
# -----------------------------
ax.set_xlabel("Time (s)")
ax.set_ylabel("CPU Usage (%)")
ax.set_ylim(0, 110)

ax.grid(True, linestyle=":", linewidth=0.5, alpha=0.7)
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)

# -----------------------------
# LEGEND (ABOVE)
# -----------------------------
handles, labels = ax.get_legend_handles_labels()

order = [labels.index(anchor_col)] + [i for i in range(len(labels)) if labels[i] != anchor_col]

ax.legend(
    [handles[i] for i in order],
    [labels[i] for i in order],
    loc="lower center",
    bbox_to_anchor=(0.5, 1.02),
    ncol=min(len(labels), 2),
    frameon=False
)

# -----------------------------
# LAYOUT & SAVE
# -----------------------------
plt.tight_layout()

plt.savefig(
    output_file,
    dpi=600,
    bbox_inches="tight"
)

plt.close()
