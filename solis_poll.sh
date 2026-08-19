printf "\nSOLIS LIVE\n\n"
printf "Grid voltage:   --\n"
printf "Battery SoC:    --\n"
printf "House load:     --\n"
printf "Battery:        --\n"
printf "Grid:           --\n"

while true; do
    values=$(
        {
          mbpoll -1 -m tcp -a 1 -r 33074 -c 1  -t 3 192.168.1.57 2>&1
          mbpoll -1 -m tcp -a 1 -r 33136 -c 16 -t 3 192.168.1.57 2>&1
          mbpoll -1 -m tcp -a 1 -r 33264 -c 2  -t 3 192.168.1.57 2>&1
        } | awk '
        /^\[[0-9]+\]:/ {
            reg=$1
            gsub(/\[|\]:/, "", reg)
            r[reg]=$2
        }
        END {
            voltage = r[33074] / 10
            batt = (r[33150] * 65536 + r[33151]) / 1000

            gridraw = r[33264] * 65536 + r[33265]
            if (gridraw >= 2147483648)
                gridraw -= 4294967296
            grid = gridraw / 1000

            if (batt < 0.05)
                batt_status = "Idle"
            else if (r[33136] == 1)
                batt_status = "Discharging"
            else
                batt_status = "Charging"

            if (grid > 0.05) {
                grid_status = "Exporting"
                grid_display = grid
            } else if (grid < -0.05) {
                grid_status = "Importing"
                grid_display = -grid
            } else {
                grid_status = "Idle"
                grid_display = 0
            }

            printf "%.1f|%d|%.2f|%s|%.2f|%s|%.2f",
                voltage,
                r[33140],
                r[33148] / 1000,
                batt_status,
                batt,
                grid_status,
                grid_display
        }'
    )

    IFS='|' read -r voltage soc load batt_status batt_power grid_status grid_power <<< "$values"

    printf "\033[5A"
    printf "\r\033[KGrid voltage:   %s V\n" "$voltage"
    printf "\r\033[KBattery SoC:    %s%%\n" "$soc"
    printf "\r\033[KHouse load:     %s kW\n" "$load"
    printf "\r\033[KBattery:        %s %s kW\n" "$batt_status" "$batt_power"
    printf "\r\033[KGrid:           %s %s kW\n" "$grid_status" "$grid_power"

    sleep 0.5
done