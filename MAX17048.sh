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
REG_TEMP=0x16 # Read but handled gracefully if absent/error

# --- Scaling Factors ---
VCELL_LSB_UV="78.125"
SOC_LSB_PERCENT_DIV="256.0"
TEMP_LSB_C_DIV="256.0"
VCELL_LSB_V=$(echo "scale=9; $VCELL_LSB_UV / 1000000.0" | bc)

# --- Kernel Module Sysfs Paths ---
# Writable attributes are under the platform device
KO_PLATFORM_PATH="/sys/devices/platform/userspace_battery"
KO_VOLTAGE_FILE="${KO_PLATFORM_PATH}/set_voltage_uv" # Expects microvolts (uV)
KO_CAPACITY_FILE="${KO_PLATFORM_PATH}/set_capacity"  # Expects integer 0-100
KO_STATUS_FILE="${KO_PLATFORM_PATH}/set_status"      # Expects "Charging", "Discharging", etc.

# Standard power supply path (for verification if needed)
KO_CLASS_PATH="/sys/class/power_supply/userspace_battery"

ENABLE_KO_WRITE=true # Enable writing

# --- Dependency Check ---
command -v i2cget >/dev/null 2>&1 || { echo >&2 "Error: 'i2cget' not found."; exit 1; }
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' not found."; exit 1; }
command -v printf >/dev/null 2>&1 || { echo >&2 "Error: 'printf' not found."; exit 1; }

# --- Helper Function: Read 16-bit word (Byte-by-Byte) ---
read_i2c_word_bytes() {
    local reg_msb_hex=$1
    # Ensure input is treated as hex even if no 0x prefix
    local reg_msb_val=$((16#${1#0x}))
    local reg_lsb_hex=$(printf "0x%x" $(( reg_msb_val + 1 )) )
    local msb_hex lsb_hex msb_dec lsb_dec final_dec exit_code_msb exit_code_lsb

    msb_hex=$(i2cget -y "$I2C_BUS" "$I2C_ADDR" "$reg_msb_hex" b 2>&1)
    exit_code_msb=$?
    # Add check for empty output as well
    if [ $exit_code_msb -ne 0 ] || ! [[ "$msb_hex" =~ ^0x[0-9a-fA-F]{1,2}$ ]] || [ -z "$msb_hex" ]; then
        echo "Error reading I2C MSB $reg_msb_hex: Received '$msb_hex' (Exit code: $exit_code_msb)" >&2 ; return 1 ; fi

    lsb_hex=$(i2cget -y "$I2C_BUS" "$I2C_ADDR" "$reg_lsb_hex" b 2>&1)
    exit_code_lsb=$?
     if [ $exit_code_lsb -ne 0 ] || ! [[ "$lsb_hex" =~ ^0x[0-9a-fA-F]{1,2}$ ]] || [ -z "$lsb_hex" ]; then
        echo "Error reading I2C LSB $reg_lsb_hex: Received '$lsb_hex' (Exit code: $exit_code_lsb)" >&2 ; return 1 ; fi

    msb_dec=$(printf "%d" "$msb_hex" 2>/dev/null)
    lsb_dec=$(printf "%d" "$lsb_hex" 2>/dev/null)
    # Check if conversion yielded empty strings or non-digits (printf %d should handle non-digits)
    if ! [[ "$msb_dec" =~ ^[0-9]+$ ]] || ! [[ "$lsb_dec" =~ ^[0-9]+$ ]]; then
         echo "Error converting hex bytes '$msb_hex'/'$lsb_hex' for base $reg_msb_hex." >&2 ; return 1 ; fi

    final_dec=$(( (msb_dec * 256) + lsb_dec ))
    echo "$final_dec" # Output the successfully calculated decimal value
    return 0 # Indicate success
}

# --- Initialization ---
last_voltage=""
charge_status="Monitoring"
echo "--- Starting MAX17048 Polling -> userspace_battery KO ---"
echo "Timestamp             | Voltage (V) | SOC (%) | Temp (°C) | Status       "
echo "----------------------|-------------|---------|-----------|---------------"

# --- Main Loop ---
while true; do
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Define variables local to the loop iteration to prevent carry-over on errors
    local raw_vcell_dec="" raw_soc_dec="" raw_temp_dec=""
    local current_voltage="" current_voltage_uv="" soc_percent_int="" soc_percent_float="" temp_c=""
    local voltage_diff="" is_increasing="" is_decreasing="" new_charge_status="" ko_status_string=""
    local vcell_read_success=1 soc_read_success=1 temp_read_success=1 # Default to fail

    # Read Sensor Data
    raw_vcell_dec=$(read_i2c_word_bytes "$REG_VCELL")
    vcell_read_success=$?
    raw_soc_dec=$(read_i2c_word_bytes "$REG_SOC")
    soc_read_success=$?
    raw_temp_dec=$(read_i2c_word_bytes "$REG_TEMP")
    temp_read_success=$? # Note: Temp read failure is considered non-critical later

    # *** CRITICAL ERROR CHECK for essential reads ***
    if [ "$vcell_read_success" -ne 0 ] || ! [[ "$raw_vcell_dec" =~ ^[0-9]+$ ]]; then
        echo "$timestamp | Error reading valid VCELL data (Success: $vcell_read_success, Value: '$raw_vcell_dec'). Skipping cycle." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi
    if [ "$soc_read_success" -ne 0 ] || ! [[ "$raw_soc_dec" =~ ^[0-9]+$ ]]; then
        echo "$timestamp | Error reading valid SOC data (Success: $soc_read_success, Value: '$raw_soc_dec'). Skipping cycle." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi

    # --- Calculate Scaled Values (Now safe to assume inputs are numeric) ---
    current_voltage=$(echo "scale=4; $raw_vcell_dec * $VCELL_LSB_V" | bc)
    if ! [[ "$current_voltage" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then # Regex allows optional sign, decimal
        echo "$timestamp | Error calculating current_voltage (bc output: '$current_voltage'). Skipping cycle." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi

    current_voltage_uv=$(echo "scale=0; $current_voltage * 1000000 / 1" | bc)
    if ! [[ "$current_voltage_uv" =~ ^[0-9]+$ ]]; then
        echo "$timestamp | Error calculating current_voltage_uv (bc output: '$current_voltage_uv'). Skipping cycle." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi

    soc_percent_int=$(echo "scale=0; $raw_soc_dec / $SOC_LSB_PERCENT_DIV" | bc)
    if ! [[ "$soc_percent_int" =~ ^-?[0-9]+$ ]]; then # Regex allows optional initial minus sign
        echo "$timestamp | Error calculating soc_percent_int (bc output: '$soc_percent_int'). Skipping cycle." >&2
        sleep "$INTERVAL_SECONDS"; continue
    fi

    # Ensure SOC is within 0-100 range (Arithmetic evaluation should be safe now)
    # Use bash arithmetic expansion for integer comparison
    if (( soc_percent_int > 100 )); then soc_percent_int=100; fi
    if (( soc_percent_int < 0 )); then soc_percent_int=0; fi

    # Calculate float version for display
    soc_percent_float=$(echo "scale=2; $raw_soc_dec / $SOC_LSB_PERCENT_DIV" | bc)
    if ! [[ "$soc_percent_float" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
        echo "$timestamp | Warning: Error calculating soc_percent_float (bc output: '$soc_percent_float'). Displaying N/A." >&2
        soc_percent_float="N/A"
    fi

    # --- Temperature Calculation ---
    if [ "$temp_read_success" -eq 0 ] && [[ "$raw_temp_dec" =~ ^[0-9]+$ ]]; then
       if [ "$raw_temp_dec" -eq 65535 ]; then temp_c="N/A";
       else
           if (( raw_temp_dec > 32767 )); then local temp_signed_dec=$(( raw_temp_dec - 65536 ));
           else local temp_signed_dec=$raw_temp_dec ; fi
           temp_c=$(echo "scale=2; $temp_signed_dec / $TEMP_LSB_C_DIV" | bc)
           if ! [[ "$temp_c" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then temp_c="Error"; fi
       fi
    else
        temp_c="N/A"
        # Optional: Log warnings if temp reading failed or was invalid
        # if [ "$temp_read_success" -ne 0 ]; then echo "$timestamp | Warning: Temp read failed." >&2; fi
        # if [[ "$raw_temp_dec" != "" ]] && ! [[ "$raw_temp_dec" =~ ^[0-9]+$ ]]; then echo "$timestamp | Warning: Invalid temp data ('$raw_temp_dec')." >&2; fi
    fi

    # --- Determine Charging/Discharging Status (with Hysteresis) ---
    new_charge_status="$charge_status" # Default to current state
    # Check if last_voltage is valid before comparing
    if [ -z "$last_voltage" ] || ! [[ "$last_voltage" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] ; then
        new_charge_status="Monitoring" # Initial state or after bad previous read
    else
        voltage_diff=$(echo "$current_voltage - $last_voltage" | bc)
        if ! [[ "$voltage_diff" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]; then
              echo "$timestamp | Warning: Error calculating voltage_diff ('$voltage_diff'). Maintaining previous status." >&2
              # Keep previous status by not changing new_charge_status
        else
            # Use bc for floating point comparison
            is_increasing=$(echo "$voltage_diff > $VOLTAGE_INCREASE_THRESHOLD" | bc -l) # Use -l for float comparison
            is_decreasing=$(echo "$voltage_diff < $VOLTAGE_DECREASE_THRESHOLD" | bc -l)

            # Check bc comparison results (should be 0 or 1)
            if ! [[ "$is_increasing" =~ ^[01]$ ]] || ! [[ "$is_decreasing" =~ ^[01]$ ]]; then
                 echo "$timestamp | Warning: Error comparing voltage diff result ('$is_increasing'/'$is_decreasing'). Maintaining previous status." >&2
            else
                if [ "$is_increasing" -eq 1 ]; then
                    new_charge_status="Charging"
                elif [ "$is_decreasing" -eq 1 ]; then
                    if [ "$charge_status" != "Charging" ]; then # Apply hysteresis
                         new_charge_status="Discharging"
                    fi # else: Keep "Charging" status if it dipped slightly
                else # In deadband
                    if [ "$charge_status" == "Initializing" ] || [ "$charge_status" == "Monitoring" ]; then
                        new_charge_status="Stable"
                    fi # else: Keep previous Charging/Discharging/Stable status
                fi
            fi # End check of bc comparison results
        fi # End check of voltage_diff calculation
    fi
    charge_status="$new_charge_status" # Update status

    # --- Map script status to Kernel Power Supply Status ---
    ko_status_string="Unknown" # Default
    case "$charge_status" in
        Charging) ko_status_string="Charging" ;;
        Discharging) ko_status_string="Discharging" ;;
        Stable)
             local is_full=$(echo "$current_voltage > 4.18" | bc -l) # Example threshold for 'Full'
             if [[ "$is_full" =~ ^[01]$ ]]; then # Check bc result
                  if [ "$is_full" -eq 1 ]; then ko_status_string="Full";
                  else ko_status_string="Not charging"; fi # Assumed charger connected but battery not full/charging
             else ko_status_string="Not charging"; fi # Default stable state if check fails
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
            local write_error=0
            # Check if values are valid before writing
            if [[ "$current_voltage_uv" =~ ^[0-9]+$ ]]; then printf "%s" "$current_voltage_uv" > "$KO_VOLTAGE_FILE" || write_error=1
            else write_error=1; echo "$timestamp | Error: Invalid voltage_uv for KO write ('$current_voltage_uv')" >&2; fi

            if [[ "$soc_percent_int" =~ ^[0-9]+$ ]]; then printf "%s" "$soc_percent_int" > "$KO_CAPACITY_FILE" || write_error=1
            else write_error=1; echo "$timestamp | Error: Invalid soc_percent_int for KO write ('$soc_percent_int')" >&2; fi

            # Status string should always be valid from case statement
            printf "%s" "$ko_status_string" > "$KO_STATUS_FILE" || write_error=1

            if [ "$write_error" -ne 0 ]; then echo "$timestamp | ERROR writing one or more values to KO sysfs files!" >&2; fi
        elif [ ! -d "$KO_PLATFORM_PATH" ]; then
             echo "$timestamp | INFO: KO path $KO_PLATFORM_PATH not found. Is module loaded?" >&2; sleep 5;
        else
             echo "$timestamp | ERROR: Cannot write to KO sysfs files in $KO_PLATFORM_PATH. Check permissions." >&2; sleep 5;
        fi
    fi # End KO write block

    # --- Update State for Next Iteration ---
    # Check current_voltage is valid and within a reasonable range for 1S LiPo
    if [[ "$current_voltage" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] && \
       (( $(echo "$current_voltage > 1.0 && $current_voltage < 5.0" | bc -l) )); then
        last_voltage="$current_voltage"
    else
         echo "$timestamp | Warning: Voltage ($current_voltage) invalid or out of range, not updating last_voltage." >&2
         last_voltage="" # Clear last voltage if current read is bad, forces Monitoring next cycle
    fi

    sleep "$INTERVAL_SECONDS"

done
