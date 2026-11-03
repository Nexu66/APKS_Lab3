"""Осцилограми для звіту і pull request: читає VCD, записаний тестбенчем, і малює сигнали
у вигляді логічного аналізатора з розкодуванням шини SPI (байти MOSI/MISO, фронти вибірки).

Використання: python sim/plot_waves.py build/sim/tb_1000000.vcd build/sim/tb_12500000.vcd docs/img
"""
import bisect
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, Rectangle
from matplotlib.transforms import blended_transform_factory

BG, PANEL, GRID = "#1b1d21", "#121418", "#2a2e35"
TRACE, BUS, TEXT, MARK, DECODE, WARN = "#3ddc84", "#59c2ff", "#d4d8de", "#ffcc66", "#c792ea", "#ff7a7a"
plt.rcParams["font.family"] = "DejaVu Sans"
TB = "tb_spi_master"
STATES = {0: "IDLE", 1: "LEAD", 2: "XFER", 3: "LAG", 4: "GAP"}


# --------------------------------------------------------------------------- VCD
class VCD:
    UNITS = {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "ps": 1e-3, "fs": 1e-6}

    def __init__(self, path):
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        header, body = text.split("$enddefinitions", 1)
        self.ids, self.data, scope, scale = {}, {}, [], 1.0
        tok = header.split()
        i = 0
        while i < len(tok):
            if tok[i] == "$scope":
                scope.append(tok[i + 2]); i += 4
            elif tok[i] == "$upscope":
                scope.pop(); i += 2
            elif tok[i] == "$var":
                ident, name = tok[i + 3], tok[i + 4]
                self.ids[".".join(scope + [name])] = ident
                self.data.setdefault(ident, ([], []))
                i = tok.index("$end", i) + 1
            elif tok[i] == "$timescale":
                spec = "".join(tok[i + 1:tok.index("$end", i)])
                num = "".join(ch for ch in spec if ch.isdigit())
                scale = float(num) * self.UNITS[spec[len(num):]]
                i = tok.index("$end", i) + 1
            else:
                i += 1
        t = 0.0
        for line in body.splitlines()[1:]:
            line = line.strip()
            if not line or line[0] == "$":
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:]) * scale
            elif c in "01xzXZ":
                self._add(line[1:], t, c.lower())
            elif c in "bB":
                val, ident = line[1:].split()
                self._add(ident, t, int(val, 2) if set(val) <= {"0", "1"} else "x")

    def _add(self, ident, t, v):
        if ident in self.data:
            ts, vs = self.data[ident]
            if ts and ts[-1] == t:
                vs[-1] = v
            else:
                ts.append(t); vs.append(v)

    def sig(self, name):
        return self.data[self.ids[name]]

    def at(self, name, t):
        ts, vs = self.sig(name)
        k = bisect.bisect_right(ts, t) - 1
        return vs[k] if k >= 0 else "x"

    def edges(self, name, t0, t1):
        ts, vs = self.sig(name)
        return [(t, v) for t, v in zip(ts, vs) if t0 <= t <= t1]


# --------------------------------------------------------------------------- SPI decoding
def transactions(v):
    """(t_fall, t_rise, mode) for every SS_n low period."""
    ts, vs = v.sig(f"{TB}.ss_n")
    out, fall = [], None
    for t, val in zip(ts, vs):
        if val == "0" and fall is None:
            fall = t
        elif val == "1" and fall is not None:
            mode = v.at(f"{TB}.cmd_mode", fall)
            out.append((fall, t, mode if isinstance(mode, int) else 0))
            fall = None
    return out


def decode(v, tr):
    """Sampling-edge times and decoded MOSI/MISO bytes of one transaction."""
    fall, rise, mode = tr
    cpol, cpha = mode >> 1, mode & 1
    samples = []
    for t, val in v.edges(f"{TB}.sclk", fall, rise):
        if val not in "01":
            continue
        lead = int(val) != cpol
        if lead ^ cpha:
            samples.append(t)
    mosi_bytes, miso_bytes = [], []
    for k in range(0, len(samples) - 7, 8):
        group = samples[k:k + 8]
        bits_o = [v.at(f"{TB}.mosi", t) for t in group]
        bits_i = [v.at(f"{TB}.miso", t) for t in group]
        to_int = lambda bits: int("".join(bits), 2) if set(bits) <= {"0", "1"} else None
        mosi_bytes.append((group[0], group[-1], to_int(bits_o)))
        miso_bytes.append((group[0], group[-1], to_int(bits_i)))
    return samples, mosi_bytes, miso_bytes


# --------------------------------------------------------------------------- drawing
def bit_trace(ax, v, name, y, t0, t1):
    ts, vs = v.sig(name)
    level = lambda val: y + 0.72 if val == "1" else (y + 0.12 if val == "0" else y + 0.42)
    k = bisect.bisect_right(ts, t0) - 1
    cur = vs[k] if k >= 0 else "x"
    xs, ys, unk, seg_start = [t0], [level(cur)], [], t0
    for t, val in zip(ts, vs):
        if t0 < t < t1:
            if cur not in "01":
                unk.append((seg_start, t))
            xs.append(t); ys.append(level(val))      # steps-post: value holds from this point on
            cur, seg_start = val, t
    if cur not in "01":
        unk.append((seg_start, t1))
    xs.append(t1); ys.append(level(cur))
    ax.plot(xs, ys, drawstyle="steps-post", color=TRACE, lw=1.3)
    for a, b in unk:
        ax.add_patch(Rectangle((a, y + 0.12), b - a, 0.6, color=WARN, alpha=0.15, lw=0))


def bus_trace(ax, v, name, y, t0, t1, fmt, min_w):
    ts, vs = v.sig(name)
    k = max(0, bisect.bisect_right(ts, t0) - 1)
    segs, cur, start = [], vs[k] if ts else "x", t0
    for t, val in zip(ts, vs):
        if t0 < t < t1:
            segs.append((start, t, cur)); cur, start = val, t
    segs.append((start, t1, cur))
    d = (t1 - t0) * 0.003
    for a, b, val in segs:
        dd = min(d, (b - a) / 3)
        poly = [(a, y + 0.42), (a + dd, y + 0.72), (b - dd, y + 0.72), (b, y + 0.42), (b - dd, y + 0.12), (a + dd, y + 0.12)]
        ax.add_patch(Polygon(poly, closed=True, fill=False, edgecolor=BUS, lw=1.0))
        if b - a >= min_w:
            ax.text((a + b) / 2, y + 0.42, fmt(val), color=TEXT, ha="center", va="center", fontsize=7.5, clip_on=True)


def decode_row(ax, items, y, half, color=DECODE):
    for a, b, val in items:
        x0, x1 = a - half * 0.9, b + half * 0.9
        ax.add_patch(Rectangle((x0, y + 0.14), x1 - x0, 0.56, facecolor=color, alpha=0.18, edgecolor=color, lw=1.0))
        ax.text((x0 + x1) / 2, y + 0.42, "??" if val is None else f"0x{val:02X}", color=TEXT, ha="center", va="center", fontsize=8, clip_on=True)


def hexfmt(val):
    return "x" if not isinstance(val, int) else f"{val:02X}"


def draw(v, rows, t0, t1, title, out, markers=(), notes=(), width=13.0):
    n = len(rows)
    fig, ax = plt.subplots(figsize=(width, 0.52 * n + 0.95), dpi=160)
    fig.patch.set_facecolor(BG)
    ax.set_facecolor(PANEL)
    span = t1 - t0
    for i, row in enumerate(rows):
        y = n - 1 - i
        label, kind = row[0], row[1]
        ax.axhline(y, color=GRID, lw=0.5)
        ax.text(-0.006, y + 0.42, label, transform=blended_transform_factory(ax.transAxes, ax.transData),
                color=TEXT, ha="right", va="center", fontsize=8.5)
        if kind == "bit":
            bit_trace(ax, v, row[2], y, t0, t1)
        elif kind == "bus":
            fmt = row[3] if len(row) > 3 else hexfmt
            bus_trace(ax, v, row[2], y, t0, t1, fmt, span * 0.012)
        elif kind == "decode":
            decode_row(ax, row[2], y, row[3])
        elif kind == "bits":                      # bit values at sampling edges
            for t, b in row[2]:
                ax.text(t, y + 0.42, b, color=MARK, ha="center", va="center", fontsize=8, clip_on=True)
    for t in markers:
        ax.axvline(t, color=MARK, lw=0.6, ls=(0, (2, 3)), alpha=0.55)
    for t, row_idx, text, color in notes:
        ax.annotate(text, xy=(t, n - 1 - row_idx + 0.9), color=color, fontsize=8, ha="center", va="bottom")
    ax.set_xlim(t0, t1)
    ax.set_ylim(-0.15, n + 0.25)
    ax.set_yticks([])
    ticks = ax.get_xticks()
    ax.set_xticks(ticks)
    ax.set_xticklabels([f"{t / 1000:g}" for t in ticks], color=TEXT, fontsize=8)
    ax.set_xlim(t0, t1)
    ax.set_xlabel("час, мкс", color=TEXT, fontsize=8.5)
    ax.tick_params(colors=GRID)
    for s in ax.spines.values():
        s.set_color(GRID)
    ax.grid(axis="x", color=GRID, lw=0.5)
    fig.text(0.012, 0.985, title, color=TEXT, fontsize=10, ha="left", va="top", weight="bold")
    fig.subplots_adjust(left=0.115, right=0.99, top=1 - 0.42 / (0.52 * n + 0.95), bottom=0.5 / (0.52 * n + 0.95))
    fig.savefig(out, facecolor=BG)
    plt.close(fig)
    print("saved", out)


# --------------------------------------------------------------------------- figures
def figures(vcd_slow, vcd_fast, outdir):
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    v = VCD(vcd_slow)
    trs = transactions(v)
    half = (trs[0][1] - trs[0][0]) / (4 * 16 + 2)        # T/2: 64 half-periods + t_lead + t_lag
    state_fmt = lambda s: STATES.get(s, "x") if isinstance(s, int) else "x"
    core = f"{TB}.dut.u_core"

    # 1. T1, перший байт крупно: режим 0, фази і зсувний регістр
    fall, rise, mode = trs[0]
    samples, mo, mi = decode(v, trs[0])
    rst_rise = [t for t, val in v.edges(f"{TB}.rst_n", 0, fall) if val == "1"]
    t0, t1 = max(fall - 2 * half, rst_rise[-1] if rst_rise else 0), samples[8] + half * 0.5
    bits_o = [(t, v.at(f"{TB}.mosi", t)) for t in samples[:8]]
    bits_i = [(t, v.at(f"{TB}.miso", t)) for t in samples[:8]]
    draw(v, [
        ("state", "bus", f"{core}.state", state_fmt),
        ("SS_n", "bit", f"{TB}.ss_n"),
        ("SCLK", "bit", f"{TB}.sclk"),
        ("ecnt", "bus", f"{core}.ecnt", lambda x: str(x) if isinstance(x, int) else "x"),
        ("MOSI", "bit", f"{TB}.mosi"),
        ("MOSI біт", "bits", bits_o),
        ("tx shreg", "bus", f"{core}.u_tx.shreg"),
        ("MISO", "bit", f"{TB}.miso"),
        ("MISO біт", "bits", bits_i),
        ("rx_valid", "bit", f"{TB}.rx_valid"),
        ("rx_data", "bus", f"{TB}.rx_data"),
    ], t0, t1, "T1, режим 0 (CPOL=0, CPHA=0): перший байт — MOSI 0xDE, MISO 0x01; пунктир — фронти вибірки",
        out / "wave_t1_byte.png", markers=samples[:8])

    # 2. T1 повністю: 4 байти
    draw(v, [
        ("cmd_start", "bit", f"{TB}.cmd_start"),
        ("busy", "bit", f"{TB}.busy"),
        ("SS_n", "bit", f"{TB}.ss_n"),
        ("SCLK", "bit", f"{TB}.sclk"),
        ("MOSI", "bit", f"{TB}.mosi"),
        ("MOSI байт", "decode", mo, half),
        ("tx_req", "bit", f"{TB}.tx_req"),
        ("tx_data", "bus", f"{TB}.tx_data"),
        ("MISO", "bit", f"{TB}.miso"),
        ("MISO байт", "decode", mi, half),
        ("rx_valid", "bit", f"{TB}.rx_valid"),
        ("rx_data", "bus", f"{TB}.rx_data"),
        ("done", "bit", f"{TB}.done"),
    ], fall - 3 * half, rise + 3 * half, "T1: транзакція з 4 байтів у режимі 0 — MOSI DE AD BE EF, MISO 01 23 45 67",
        out / "wave_t1_full.png")

    # 3. Режими 0–3: перший байт T1..T4
    fig, axes = plt.subplots(2, 2, figsize=(13, 6.4), dpi=160)
    fig.patch.set_facecolor(BG)
    for idx, ax in enumerate(axes.flat):
        fall, rise, mode = trs[idx]
        samples, mo, mi = decode(v, trs[idx])
        t0, t1 = fall - 2 * half, samples[7] + 3 * half
        rows = [("SS_n", f"{TB}.ss_n"), ("SCLK", f"{TB}.sclk"), ("MOSI", f"{TB}.mosi"), ("MISO", f"{TB}.miso")]
        ax.set_facecolor(PANEL)
        for i, (label, name) in enumerate(rows):
            y = len(rows) - 1 - i
            ax.axhline(y, color=GRID, lw=0.5)
            bit_trace(ax, v, name, y, t0, t1)
            ax.text(t0 - (t1 - t0) * 0.012, y + 0.42, label, color=TEXT, ha="right", va="center", fontsize=8.5)
        for t in samples[:8]:
            ax.axvline(t, color=MARK, lw=0.6, ls=(0, (2, 3)), alpha=0.6)
            ax.text(t, 1 + 0.86, v.at(f"{TB}.mosi", t), color=MARK, ha="center", fontsize=7)
            ax.text(t, 0 + 0.86, v.at(f"{TB}.miso", t), color=MARK, ha="center", fontsize=7)
        cpol, cpha = mode >> 1, mode & 1
        ax.set_title(f"режим {mode}: CPOL={cpol}, CPHA={cpha} — MOSI 0x{mo[0][2]:02X}, MISO 0x{mi[0][2]:02X}",
                     color=TEXT, fontsize=9.5, loc="left")
        ax.set_xlim(t0 - (t1 - t0) * 0.08, t1)
        ax.set_ylim(-0.15, len(rows) + 0.1)
        ax.set_yticks([])
        ticks = [t for t in ax.get_xticks() if t >= t0]
        ax.set_xticks(ticks)
        ax.set_xticklabels([f"{t / 1000:g}" for t in ticks], color=TEXT, fontsize=7.5)
        ax.tick_params(colors=GRID)
        for s in ax.spines.values():
            s.set_color(GRID)
    fig.suptitle("Режими SPI 0–3 (тести T1–T4): пунктир — фронти вибірки, жовті цифри — прочитані біти; час, мкс",
                 color=TEXT, fontsize=10, x=0.01, ha="left", weight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    fig.savefig(out / "wave_modes.png", facecolor=BG)
    plt.close(fig)
    print("saved", out / "wave_modes.png")

    # 4. T6: 16 байтів підряд, режим 3
    fall, rise, mode = trs[5]
    samples, mo, mi = decode(v, trs[5])
    draw(v, [
        ("SS_n", "bit", f"{TB}.ss_n"),
        ("SCLK", "bit", f"{TB}.sclk"),
        ("MOSI", "bit", f"{TB}.mosi"),
        ("MOSI байт", "decode", mo, half),
        ("MISO", "bit", f"{TB}.miso"),
        ("MISO байт", "decode", mi, half),
        ("tx_req", "bit", f"{TB}.tx_req"),
        ("rx_valid", "bit", f"{TB}.rx_valid"),
        ("done", "bit", f"{TB}.done"),
    ], fall - 6 * half, rise + 6 * half, "T6: 16 байтів підряд у режимі 3 (CPOL=1, CPHA=1) — SCLK без пауз між байтами",
        out / "wave_t6_burst.png", width=14)

    # 5. T7: cmd_start під час передачі ігнорується, транзакції впритул
    fa, ra, _ = trs[6]
    fb, rb, _ = trs[7]
    ts_start = [t for t, val in v.edges(f"{TB}.cmd_start", fa - 4 * half, rb) if val == "1"]
    draw(v, [
        ("cmd_start", "bit", f"{TB}.cmd_start"),
        ("busy", "bit", f"{TB}.busy"),
        ("state", "bus", f"{core}.state", state_fmt),
        ("SS_n", "bit", f"{TB}.ss_n"),
        ("SCLK", "bit", f"{TB}.sclk"),
        ("MOSI", "bit", f"{TB}.mosi"),
        ("MISO", "bit", f"{TB}.miso"),
        ("rx_valid", "bit", f"{TB}.rx_valid"),
        ("done", "bit", f"{TB}.done"),
    ], fa - 4 * half, rb + 4 * half,
        f"T7: другий cmd_start під час передачі ігнорується; наступна транзакція впритул (t_idle = {(fb - ra) / 1000:.2f} мкс)",
        out / "wave_t7_b2b.png", markers=ts_start[1:2], notes=[(ts_start[1], 0, "ігнорується", WARN)] if len(ts_start) > 1 else ())

    # 6. T8: скидання посеред передачі
    fall, rise, mode = trs[8]
    ts_rst = [t for t, val in v.edges(f"{TB}.rst_n", fall, fall + 1e9) if val == "0"]
    fb, rb, _ = trs[9]
    draw(v, [
        ("rst_n", "bit", f"{TB}.rst_n"),
        ("busy", "bit", f"{TB}.busy"),
        ("state", "bus", f"{core}.state", state_fmt),
        ("SS_n", "bit", f"{TB}.ss_n"),
        ("SCLK", "bit", f"{TB}.sclk"),
        ("MOSI", "bit", f"{TB}.mosi"),
        ("MISO", "bit", f"{TB}.miso"),
        ("rx_valid", "bit", f"{TB}.rx_valid"),
        ("rx_data", "bus", f"{TB}.rx_data"),
    ], fall - 4 * half, rb + 4 * half,
        "T8: скидання посеред третього байта — шина одразу в спокої, наступна транзакція (C0 DE → BE EF) коректна",
        out / "wave_t8_reset.png", markers=ts_rst[:1], notes=[(ts_rst[0], 0, "rst_n = 0", WARN)] if ts_rst else ())

    # 7. Максимальна частота 12.5 МГц: T1, перший байт з тактом clk
    if vcd_fast:
        w = VCD(vcd_fast)
        trs_f = transactions(w)
        fall, rise, mode = trs_f[0]
        half_f = (rise - fall) / (4 * 16 + 2)
        samples, mo, mi = decode(w, trs_f[0])
        draw(w, [
            ("clk", "bit", f"{TB}.clk"),
            ("SS_n", "bit", f"{TB}.ss_n"),
            ("SCLK", "bit", f"{TB}.sclk"),
            ("MOSI", "bit", f"{TB}.mosi"),
            ("MOSI біт", "bits", [(t, w.at(f"{TB}.mosi", t)) for t in samples[:16]]),
            ("MISO", "bit", f"{TB}.miso"),
            ("MISO біт", "bits", [(t, w.at(f"{TB}.miso", t)) for t in samples[:16]]),
            ("rx_valid", "bit", f"{TB}.rx_valid"),
            ("rx_data", "bus", f"{TB}.rx_data"),
        ], fall - 2 * half_f, samples[15] + 3 * half_f,
            "SCLK = 12.5 МГц (HALF = 2 такти clk 50 МГц): T1, перші два байти — MOSI DE AD, MISO 01 23",
            out / "wave_fast.png", markers=samples[:16])


if __name__ == "__main__":
    figures(sys.argv[1], sys.argv[2] if len(sys.argv) > 3 else None, sys.argv[-1])
