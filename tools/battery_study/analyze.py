"""Integrate raw OPlus telemetry without assuming its scaling to a 2S pack."""

import argparse
import csv
import json
import math
from pathlib import Path


def read_rows(path):
    required = {
        "uptime_s", "vbat_mv", "ibat_ma", "batt_temp", "usb_online",
        "wireless_online", "wired_online", "power_status", "charge_counter_raw", "ui_soc", "batt_soc",
    }
    with Path(path).open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        if not required.issubset(reader.fieldnames or []):
            raise ValueError("missing required telemetry columns")
        rows = []
        for line, raw in enumerate(reader, 2):
            # A power loss may leave the last CSV record partially written.
            if None in raw or any(raw.get(key) is None for key in required):
                if line == 2:
                    raise ValueError("first record is truncated")
                raise ValueError(f"malformed or truncated record at line {line}; retain raw data and repair a copy")
            row = {key: float(raw[key]) for key in (
                "uptime_s", "vbat_mv", "ibat_ma", "batt_temp", "charge_counter_raw", "ui_soc", "batt_soc"
            )}
            if not all(math.isfinite(value) for value in row.values()):
                raise ValueError(f"non-finite value at line {line}")
            row["unpowered_discharge"] = (
                raw["usb_online"] == "0" and raw["wireless_online"] == "0"
                and raw["wired_online"] == "0"
                and raw["power_status"] in ("Discharging", "Not charging", "Full")
            )
            rows.append(row)
    return rows


def integrate(rows, *, discharge_sign=1, max_gap=15, voltage_scale=None,
              current_scale=None, calibration_note=None, endpoint="unknown", endpoint_note=None):
    if discharge_sign not in (-1, 1) or not math.isfinite(max_gap) or max_gap <= 0:
        raise ValueError("invalid sign or sampling gap")
    calibrated = voltage_scale is not None or current_scale is not None
    if calibrated:
        if voltage_scale is None or current_scale is None or not calibration_note:
            raise ValueError("both pack scaling factors and their evidence note are required")
        if not all(math.isfinite(v) and v > 0 for v in (voltage_scale, current_scale)):
            raise ValueError("pack scaling factors must be finite and positive")
    if endpoint == "natural_shutdown" and not endpoint_note:
        raise ValueError("natural shutdown requires an explicit evidence note")
    energy = charge = duration = 0.0
    rejected = {"gap": 0, "external_power_or_status": 0, "invalid_channel": 0}
    segments = 0
    for first, second in zip(rows, rows[1:]):
        dt = second["uptime_s"] - first["uptime_s"]
        if dt <= 0:
            raise ValueError("timestamps are non-monotonic; do not join data across reboots")
        if dt > max_gap:
            rejected["gap"] += 1
            continue
        if not all(row["unpowered_discharge"] for row in (first, second)):
            rejected["external_power_or_status"] += 1
            continue
        currents = [row["ibat_ma"] * discharge_sign for row in (first, second)]
        if (any(current < 0 or current > 20000 for current in currents)
                or any(not 2000 <= row["vbat_mv"] <= 5000 for row in (first, second))):
            rejected["invalid_channel"] += 1
            continue
        powers = [row["vbat_mv"] * current / 1_000_000
                  for row, current in zip((first, second), currents)]
        energy += sum(powers) / 2 * dt / 3600
        charge += sum(currents) / 2 * dt / 3600
        duration += dt
        segments += 1
    counter_delta = None
    if rows:
        counter_delta = (rows[0]["charge_counter_raw"] - rows[-1]["charge_counter_raw"]) / 1000
    return {
        "samples": len(rows), "accepted_segments": segments,
        "integrated_seconds": duration, "rejected_segments": rejected,
        "reported_channel_energy_wh": energy if segments else None,
        "reported_channel_charge_mah": charge if segments else None,
        "reported_counter_delta_mah": counter_delta,
        "pack_energy_wh": energy * voltage_scale * current_scale if calibrated and segments else None,
        "voltage_scale_to_pack": voltage_scale, "current_scale_to_pack": current_scale,
        "calibration_note": calibration_note, "discharge_sign": discharge_sign,
        "endpoint": endpoint, "endpoint_note": endpoint_note,
        "full_discharge_evidence": (
            endpoint == "natural_shutdown" and bool(endpoint_note) and segments > 0
            and not any(rejected.values()) and rows[0]["ui_soc"] == 100 and rows[0]["batt_soc"] == 100
        ),
        "note": "Integral covers accepted sample intervals only; the unsampled final tail is excluded. FCC and charger input are not measured output energy.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", type=Path)
    parser.add_argument("--discharge-sign", choices=("positive", "negative"), default="positive")
    parser.add_argument("--max-gap-seconds", type=float, default=15)
    parser.add_argument("--voltage-scale-to-pack", type=float)
    parser.add_argument("--current-scale-to-pack", type=float)
    parser.add_argument("--calibration-note")
    parser.add_argument("--endpoint", choices=("unknown", "manual_stop", "natural_shutdown"), default="unknown")
    parser.add_argument("--endpoint-note")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    try:
        result = integrate(
            read_rows(args.samples), discharge_sign=1 if args.discharge_sign == "positive" else -1,
            max_gap=args.max_gap_seconds, voltage_scale=args.voltage_scale_to_pack,
            current_scale=args.current_scale_to_pack, calibration_note=args.calibration_note,
            endpoint=args.endpoint, endpoint_note=args.endpoint_note,
        )
    except (ValueError, OSError) as error:
        parser.error(str(error))
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        # Never replace a previously produced result silently.
        with args.out.open("x", encoding="utf-8") as stream:
            stream.write(text)
    print(text, end="")


if __name__ == "__main__":
    main()
