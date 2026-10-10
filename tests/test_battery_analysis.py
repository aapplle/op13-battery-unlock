import importlib.util
import unittest
import csv
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "battery_analysis", Path(__file__).parents[1] / "tools/battery_study/analyze.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def row(t, current=1000, powered=False):
    return {"uptime_s": t, "vbat_mv": 4000, "ibat_ma": current,
            "batt_temp": 250, "charge_counter_raw": 6000000 - t / 3.6 * 1000,
            "unpowered_discharge": not powered, "ui_soc": 100, "batt_soc": 100}


class BatteryAnalysisTests(unittest.TestCase):
    def test_oplus_not_charging_label_and_real_external_supply(self):
        fields = ["uptime_s", "vbat_mv", "ibat_ma", "batt_temp", "usb_online",
                  "wireless_online", "wired_online", "power_status", "charge_counter_raw", "ui_soc", "batt_soc"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "samples.csv"
            with path.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.DictWriter(stream, fieldnames=fields)
                writer.writeheader()
                for time, usb in ((0, 0), (5, 0), (10, 1)):
                    data = row(time)
                    data.pop("unpowered_discharge")
                    data.update(usb_online=usb, wireless_online=0, wired_online=usb,
                                power_status="Not charging")
                    writer.writerow(data)
            result = module.integrate(module.read_rows(path))
        self.assertEqual(result["accepted_segments"], 1)
        self.assertEqual(result["rejected_segments"]["external_power_or_status"], 1)
        self.assertAlmostEqual(result["reported_channel_energy_wh"], 4 * 5 / 3600)

    def test_analytic_energy_and_pack_units_gate(self):
        rows = [row(0), row(3600)]
        result = module.integrate(rows, max_gap=3600)
        self.assertEqual(result["reported_channel_energy_wh"], 4)
        self.assertEqual(result["reported_channel_charge_mah"], 1000)
        self.assertIsNone(result["pack_energy_wh"])
        self.assertFalse(result["full_discharge_evidence"])
        calibrated = module.integrate(rows, max_gap=3600, voltage_scale=2,
                                      current_scale=1, calibration_note="synthetic 2S, pack current")
        self.assertEqual(calibrated["pack_energy_wh"], 8)
        with self.assertRaises(ValueError):
            module.integrate(rows, voltage_scale=2)

    def test_external_supply_and_gaps_do_not_count_as_output(self):
        result = module.integrate([row(0), row(5, powered=True), row(10), row(100)])
        self.assertEqual(result["accepted_segments"], 0)
        self.assertIsNone(result["reported_channel_energy_wh"])
        self.assertEqual(result["rejected_segments"]["external_power_or_status"], 2)
        self.assertEqual(result["rejected_segments"]["gap"], 1)

    def test_current_polarity_and_reboot_boundary(self):
        result = module.integrate([row(0, -1000), row(3600, -1000)],
                                  discharge_sign=-1, max_gap=3600)
        self.assertEqual(result["reported_channel_energy_wh"], 4)
        with self.assertRaises(ValueError):
            module.integrate([row(10), row(0)])

    def test_shutdown_requires_evidence(self):
        with self.assertRaises(ValueError):
            module.integrate([row(0), row(5)], endpoint="natural_shutdown")
        result = module.integrate([row(0), row(5)], endpoint="natural_shutdown",
                                  endpoint_note="synthetic known end")
        self.assertTrue(result["full_discharge_evidence"])
        partial = [row(0), row(5)]
        partial[0]["ui_soc"] = 80
        self.assertFalse(module.integrate(partial, endpoint="natural_shutdown",
                                         endpoint_note="started part-full")["full_discharge_evidence"])


if __name__ == "__main__":
    unittest.main()
