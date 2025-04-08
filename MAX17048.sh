#!/bin/bash

# --- Configuration ---
I2C_BUS="1"
I2C_ADDR="0x36"
INTERVAL_SECONDS=10
VOLTAGE_INCREASE_THRESHOLD="0.005"
VOLTAGE_DECREASE_THRESHOLD="-0.005"

# Register Addresses
REG_VCELL=0x02
REG_SOC=0x04
REG_TEMP=0x16

# --- Scaling Factors ---
VCELL_LSB_UV="78.125"
SOC_LSB_PERCENT_DIV="256.0"
TEMP_LSB_C_DIV="256.0"
VCELL_LSB_V=$(echo "scale=9; $VCELL_LSB_UV / 1000000.0" | bc)

# --- Kernel Module Sysfs Paths ---
KO_PLATFORM_PATH="/sys/devices/platform/userspace_battery"
KO_VOLTAGE_FILE="${KO_PLATFORM_PATH}/set_voltage_uv"
KO_CAPACITY_FILE="${KO_PLATFORM_PATH}/set_capacity"
KO_STATUS_FILE="${KO_PLATFORM_PATH}/set_status"
KO_CLASS_PATH="/sys/class/power_supply/userspace_battery"
ENABLE_KO_WRITE=true

# --- Dependency Check ---
# ... (same as before) ...
command -v i2cget >/dev/null 2>&1 || { echo >&2 "Error: 'i2cget' not found."; exit 1; }
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' not found."; exit 1; }
command -v printf >/dev/null 2>&1 || { echo >&2 "Error: 'printf' not found."; exit 1; }


# --- Helper Function: Read 16-bit word (Byte-by-Byte) ---
# ... (same as before) ...
read_i2c_word_bytes() {
    local reg_msb_hex=$1 # 'local' is OK inside functions
    local reg_msb_val=$((16#${1#0x}))
    local reg_lsb_hex=$(printf "0x%x" $(( reg_msb_val + 1 )) )
    local msb_hex lsb_hex msb_dec lsb_dec final_dec exit_code_msb exit_code_lsb

    msb_hex=$(i2cget -y "$I2C_BUS" "$I2C_ADDR" "$reg_msb_hex" b 2>&1)
    exit_code_msb=$?
    if [ $exit_code_msb -ne 0 ] || ! [[ "$msb_hex" =~ ^0x[0-9a-fA-F]{1,2}$ ]] || [ -z "$msb_hex" ]; then
        echo "Error reading I2C MSB $reg_msb_hex: Received '$msb_hex' (Exit code: $exit_code_msb)" >&2 ; return 1 ; fi

    lsb_hex=$(i2cget -y "$I2C_BUS" "$I2C_ADDR" "$reg_lsb_hex" b 2>&1)
    exit_code_lsb=$?
     if [ $exit_code_lsb -ne 0 ] || ! [[ "$lsb_hex" =~ ^0x[0-9a-fA-F]{1,2}$ ]] || [ -z "$lsb_hex" ]; then
        echo "Error reading I2C LSB $reg_lsb_hex: Received '$lsb_hex' (Exit code: $exit_code_lsb)" >&2 ; return 1 ; fi

    msb_dec=$(printf "%d" "$msb_hex" 2>/dev/null)
    lsb_dec=$(printf "%d" "$lsb_hex" 2>/dev/null)
    if ! [[ "$msb_dec" =~ ^[0-9]+$ ]] || ! [[ "$lsb_dec" =~ ^[0-9]+$ ]]; then
         echo "Error converting hex bytes '$msb_hex'/'$lsb_hex' for base $reg_msb_hex." >&2 ; return 1 ; fi

    final_dec=$(( (msb_dec * 256) + lsb_dec ))
    echo "$final_dec"
    return 0
}


# --- Initialization ---
last_voltage=""
charge_status="Monitoring"
echo "--- Starting MAX17048 Polling -> userspace_battery KO ---"
echo "Timestamp             | Voltage (V) | SOC (%) | Temp (°C) | Status       "
echo "----------------------|-------------|---------|-----------|---------------"

# --- Regex for validating float numbers (allows leading .) ---
# Matches: 1, 1.2, .2, -1, -1.2, -.2, + variants
REGEX_FLOAT='^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$'
# Regex for validating integers (allows optional -)
REGEX_INT='^-?[0-9]+$'

# --- Main Loop ---
while true; do
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Reset variables for this iteration
    raw_vcell_dec="" raw_soc_dec="" raw_temp_dec=""
    current_voltage="" current_voltage_uv="" soc_percent_int="" soc_percent_float="" temp_c=""
    voltage_diff="" is_increasing="" is_decreasing="" new_charge_status="" ko_status_string=""
    vcell_read_success=1 soc_read_success=1 temp_read_success=1

    # Read Sensor Data
    raw_vcell_dec=$(read_i2c_word_bytes "$REG_VCELL")
    vcell_read_success=$?
    raw_soc_dec=$(read_i2c_word_bytes "$REG_SOC")
    soc_read_success=$?
    raw_temp_dec=$(read_i2c_word_bytes "$REG_TEMP")
    temp_read_success=$?

    # Critical Check: VCELL and SOC reads must succeed and be numeric
    if [ "$vcell_read_success" -ne 0 ] || ! [[ "$raw_vcell_dec" =~ $REGEX_INT ]]; then
        echo "$timestamp | Error reading valid VCELL data (Success: $vcell_read_success, Value: '$raw_vcell_dec'). Skipping." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi
    if [ "$soc_read_success" -ne 0 ] || ! [[ "$raw_soc_dec" =~ $REGEX_INT ]]; then
        echo "$timestamp | Error reading valid SOC data (Success: $soc_read_success, Value: '$raw_soc_dec'). Skipping." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi

    # --- Calculate Scaled Values ---
    current_voltage=$(echo "scale=4; $raw_vcell_dec * $VCELL_LSB_V" | bc)
    if ! [[ "$current_voltage" =~ $REGEX_FLOAT ]]; then
        echo "$timestamp | Error calculating current_voltage (bc output: '$current_voltage'). Skipping." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi

    current_voltage_uv=$(echo "scale=0; $current_voltage * 1000000 / 1" | bc)
    if ! [[ "$current_voltage_uv" =~ $REGEX_INT ]]; then
        echo "$timestamp | Error calculating current_voltage_uv (bc output: '$current_voltage_uv'). Skipping." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi

    soc_percent_int=$(echo "scale=0; $raw_soc_dec / $SOC_LSB_PERCENT_DIV" | bc)
    if ! [[ "$soc_percent_int" =~ $REGEX_INT ]]; then
        echo "$timestamp | Error calculating soc_percent_int (bc output: '$soc_percent_int'). Skipping." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi
    if (( soc_percent_int > 100 )); then soc_percent_int=100; fi
    if (( soc_percent_int < 0 )); then soc_percent_int=0; fi

    soc_percent_float=$(echo "scale=2; $raw_soc_dec / $SOC_LSB_PERCENT_DIV" | bc)
    if ! [[ "$soc_percent_float" =~ $REGEX_FLOAT ]]; then
        echo "$timestamp | Warning: Error calculating soc_percent_float ('$soc_percent_float'). Displaying N/A." >&2
        soc_percent_float="N/A"
    fi

    # --- Temperature Calculation ---
    if [ "$temp_read_success" -eq 0 ] && [[ "$raw_temp_dec" =~ $REGEX_INT ]]; then
       temp_signed_dec=""
       if [ "$raw_temp_dec" -eq 65535 ]; then temp_c="N/A";
       else
           if (( raw_temp_dec > 32767 )); then temp_signed_dec=$(( raw_temp_dec - 65536 ));
           else temp_signed_dec=$raw_temp_dec ; fi
           temp_c=$(echo "scale=2; $temp_signed_dec / $TEMP_LSB_C_DIV" | bc)
           if ! [[ "$temp_c" =~ $REGEX_FLOAT ]]; then temp_c="Error"; fi
       fi
    else temp_c="N/A"; fi

    # --- Determine Charging/Discharging Status (with Hysteresis) ---
    new_charge_status="$charge_status"
    if [ -z "$last_voltage" ] || ! [[ "$last_voltage" =~ $REGEX_FLOAT ]] ; then
        new_charge_status="Monitoring"
    else
        voltage_diff=$(echo "$current_voltage - $last_voltage" | bc)
        # *** Use improved regex to validate voltage_diff ***
        if ! [[ "$voltage_diff" =~ $REGEX_FLOAT ]]; then
              echo "$timestamp | Warning: Error calculating voltage_diff ('$voltage_diff'). Maintaining previous status." >&2
        else
            # Proceed with comparison
            is_increasing=$(echo "$voltage_diff > $VOLTAGE_INCREASE_THRESHOLD" | bc -l)
            is_decreasing=$(echo "$voltage_diff < $VOLTAGE_DECREASE_THRESHOLD" | bc -l)

            if ! [[ "$is_increasing" =~ ^[01]$ ]] || ! [[ "$is_decreasing" =~ ^[01]$ ]]; then
                 echo "$timestamp | Warning: Error comparing voltage diff result ('$is_increasing'/'$is_decreasing'). Maintaining previous status." >&2
            else
                if [ "$is_increasing" -eq 1 ]; then
                    new_charge_status="Charging"
                elif [ "$is_decreasing" -eq 1 ]; then
                    if [ "$charge_status" != "Charging" ]; then
                         new_charge_status="Discharging"
                    fi
                else # In deadband
                    if [ "$charge_status" == "Initializing" ] || [ "$charge_status" == "Monitoring" ]; then
                        new_charge_status="Stable"
                    fi
                fi
            fi # End check of bc comparison results
        fi # End check of voltage_diff calculation validity
    fi
    charge_status="$new_charge_status" # Update status for this iteration

    # --- Map script status to Kernel Power Supply Status ---
    # ... (same as before) ...
    ko_status_string="Unknown" # Default
    case "$charge_status" in
        Charging) ko_status_string="Charging" ;;
        Discharging) ko_status_string="Discharging" ;;
        Stable)
             is_full=""
             if [[ "$current_voltage" =~ $REGEX_FLOAT ]]; then
                 is_full=$(echo "$current_voltage > 4.18" | bc -l) # Example threshold for 'Full'
                 if [[ "$is_full" =~ ^[01]$ ]]; then
                      if [ "$is_full" -eq 1 ]; then ko_status_string="Full";
                      else ko_status_string="Not charging"; fi
                 else ko_status_string="Not charging"; fi
             else ko_status_string="Not charging"; fi
            ;;
        Monitoring|Initializing|*) ko_status_string="Unknown" ;;
    esac


    # --- Output to Console ---
    printf "%s | %-11s | %-7s | %-9s | %s\n" \
        "$timestamp" \
        "$current_voltage" \
        "$soc_percent_float" \
        "$temp_c" \
        "$charge_status"

    # --- Write to Kernel Module (Conditional) ---
    if [ "$ENABLE_KO_WRITE" = true ] ; then
        if [ -d "$KO_PLATFORM_PATH" ] && [ -w "$KO_VOLTAGE_FILE" ] && [ -w "$KO_CAPACITY_FILE" ] && [ -w "$KO_STATUS_FILE" ]; then
            # *** Add DEBUG output before writing ***
            echo "$timestamp | DEBUG: Writing -> V_uV:$current_voltage_uv | Cap:$soc_percent_int | Status:$ko_status_string" >&2

            write_error=0
            if [[ "$current_voltage_uv" =~ $REGEX_INT ]]; then printf "%s" "$current_voltage_uv" > "$KO_VOLTAGE_FILE" || write_error=1
            else write_error=1; echo "$timestamp | Error: Invalid voltage_uv for KO write ('$current_voltage_uv')" >&2; fi

            if [[ "$soc_percent_int" =~ $REGEX_INT ]]; then printf "%s" "$soc_percent_int" > "$KO_CAPACITY_FILE" || write_error=1
            else write_error=1; echo "$timestamp | Error: Invalid soc_percent_int for KO write ('$soc_percent_int')" >&2; fi

            # Status string should always be valid from case statement
            printf "%s" "$ko_status_string" > "$KO_STATUS_FILE" || write_error=1

            if [ "$write_error" -ne 0 ]; then echo "$timestamp | ERROR writing one or more values to KO sysfs files!" >&2; fi
        elif [ ! -d "$KO_PLATFORM_PATH" ]; then
             echo "$timestamp | INFO: KO path $KO_PLATFORM_PATH not found. Is module loaded?" >&2; sleep 5;
        else
             echo "$timestamp | ERROR: Cannot write to KO sysfs files in $KO_PLATFORM_PATH. Check permissions." >&2; sleep 5;
        fi
    fi

    # --- Update State for Next Iteration ---
    is_valid_voltage=0
    if [[ "$current_voltage" =~ $REGEX_FLOAT ]]; then
        bc_result=$(echo "$current_voltage > 1.0 && $current_voltage < 5.0" | bc -l)
        if [[ "$bc_result" == "1" ]]; then
            is_valid_voltage=1
        fi
    fi
    if [ "$is_valid_voltage" -eq 1 ]; then
        last_voltage="$current_voltage"
    else
         echo "$timestamp | Warning: Voltage ($current_voltage) invalid or out of range, not updating last_voltage." >&2
         last_voltage=""
    fi

    sleep "$INTERVAL_SECONDS"

done
