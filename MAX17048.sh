# --- Kernel Module Sysfs Paths ---
# Writable attributes are under the platform device
KO_PLATFORM_PATH="/sys/devices/platform/userspace_battery"
KO_VOLTAGE_FILE="${KO_PLATFORM_PATH}/set_voltage_uv" # Expects microvolts (uV)
KO_CAPACITY_FILE="${KO_PLATFORM_PATH}/set_capacity"  # Expects integer 0-100
KO_STATUS_FILE="${KO_PLATFORM_PATH}/set_status"      # Expects "Charging", "Discharging", etc.

# Standard power supply path (for verification if needed)
KO_CLASS_PATH="/sys/class/power_supply/userspace_battery"

ENABLE_KO_WRITE=true # Enable writing

# --- Inside the main loop ---

# ... read sensor data ...

# --- Calculate Scaled Values ---
current_voltage=$(echo "scale=4; $raw_vcell_dec * $VCELL_LSB_V" | bc)
# Calculate voltage in microvolts for the KO
current_voltage_uv=$(echo "scale=0; $current_voltage * 1000000 / 1" | bc)
# Calculate integer SOC for the KO
soc_percent_int=$(echo "scale=0; $raw_soc_dec / $SOC_LSB_PERCENT_DIV" | bc)
# Ensure SOC is within 0-100 range
if (( soc_percent_int > 100 )); then soc_percent_int=100; fi
if (( soc_percent_int < 0 )); then soc_percent_int=0; fi
# Keep float version for display
soc_percent_float=$(echo "scale=2; $raw_soc_dec / $SOC_LSB_PERCENT_DIV" | bc)

# ... Temperature calculation ...

# --- Determine Charging/Discharging Status (with Hysteresis) ---
# ... (Your existing status logic) ...
# charge_status will be "Charging", "Discharging", "Stable", "Monitoring"

# --- Map script status to Kernel Power Supply Status ---
ko_status_string="Unknown" # Default
case "$charge_status" in
    Charging)
        ko_status_string="Charging"
        ;;
    Discharging)
        ko_status_string="Discharging"
        ;;
    Stable)
        # Determine if Stable means Full or just Not Charging
        # Example threshold: If voltage > 4.18V and charger likely connected (status was charging before stable?)
        is_likely_full=$(echo "$current_voltage > 4.18" | bc)
        # We might need a separate check if a charger is plugged in if the chip provides it.
        # For now, map stable to "Not charging" or "Unknown"
        # Let's refine this later if needed. Defaulting to Unknown is safer.
        # if [ "$is_likely_full" -eq 1 ]; then
        #     ko_status_string="Full"
        # else
             ko_status_string="Not charging" # Assume stable means charger present but not actively charging
        # fi
        ;;
    Monitoring|Initializing|*) # Map Monitoring and any unexpected status to Unknown
        ko_status_string="Unknown"
        ;;
esac

# ... Output to Console ...

# --- Write to Kernel Module (Conditional) ---
if [ "$ENABLE_KO_WRITE" = true ] ; then
    # Check if KO platform path exists
    if [ -d "$KO_PLATFORM_PATH" ]; then
        # Write Voltage (uV)
        printf "%s" "$current_voltage_uv" > "$KO_VOLTAGE_FILE" # 2>/dev/null || echo "$timestamp | WARN: Failed voltage write" >&2

        # Write Capacity (%)
        printf "%s" "$soc_percent_int" > "$KO_CAPACITY_FILE" # 2>/dev/null || echo "$timestamp | WARN: Failed capacity write" >&2

        # Write Status String
        printf "%s" "$ko_status_string" > "$KO_STATUS_FILE" # 2>/dev/null || echo "$timestamp | WARN: Failed status write" >&2

         # Error checking - uncomment the error redirects/messages if needed for debugging
         if [ $? -ne 0 ]; then echo "$timestamp | ERROR writing to KO sysfs files!" >&2; fi

    else
         echo "$timestamp | INFO: KO path $KO_PLATFORM_PATH not found. Is module loaded?" >&2
         sleep 5 # Prevent spamming if module isn't loaded
    fi
fi # End KO write block

# ... Update last_voltage ...
# ... sleep ...
