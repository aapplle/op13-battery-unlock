#!/system/bin/sh
set -eu
. "$1"
study_power_is_discharge 0 0 0 Discharging 100
study_power_is_discharge 0 0 0 'Not charging' 100
study_power_is_discharge 0 0 0 Full 100
for state in '1 0 0 Discharging 100' '0 1 0 Discharging 100' '0 0 1 Discharging 100' \
             '0 0 0 Charging 100' '0 0 0 Unknown 100' '0 0 0 Discharging -100' \
             '0 0 0 Discharging 0' '0 0 0 Discharging invalid'; do
    if study_power_is_discharge $state; then echo "FAIL: $state"; exit 1; fi
done
echo '11 discharge-state cases passed'
