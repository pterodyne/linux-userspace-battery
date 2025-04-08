#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>         // kzalloc, kfree
#include <linux/sysfs.h>        // sysfs functions
#include <linux/kobject.h>      // kobject
#include <linux/kstrtox.h>      // kstrtoint, kstrtou64
#include <linux/string.h>       // strncasecmp, strncpy
#include <linux/mutex.h>        // mutex
#include <linux/power_supply.h> // power_supply framework
#include <linux/platform_device.h>// platform device/driver
#include <linux/err.h>          // IS_ERR, PTR_ERR

// --- Module Data Structure ---
struct userspace_batt_data {
    u64 voltage_uv;                 // Store voltage in microvolts
    int capacity;                   // Store capacity 0-100
    int status_enum;                // Store status using POWER_SUPPLY_STATUS_* enum
    struct mutex lock;              // Protect data access

    // Kernel objects
    struct platform_device *pdev;   // Our virtual platform device
    struct power_supply *psy;       // Registered power supply device
};

// Global pointer to our data (only one instance expected)
static struct userspace_batt_data *g_batt_data;

// --- Sysfs 'store' Functions (Write from userspace) ---

// Store voltage (expects microvolts)
static ssize_t set_voltage_uv_store(struct device *dev, struct device_attribute *attr,
                                    const char *buf, size_t count) {
    u64 val;
    int ret;

    if (!g_batt_data) return -ENODEV; // Should not happen if loaded correctly

    ret = kstrtou64(buf, 0, &val);
    if (ret) return ret;

    mutex_lock(&g_batt_data->lock);
    g_batt_data->voltage_uv = val;
    mutex_unlock(&g_batt_data->lock);

    power_supply_changed(g_batt_data->psy); // Notify framework
    return count;
}

// Store capacity (expects 0-100)
static ssize_t set_capacity_store(struct device *dev, struct device_attribute *attr,
                                  const char *buf, size_t count) {
    int val;
    int ret;

    if (!g_batt_data) return -ENODEV;

    ret = kstrtoint(buf, 0, &val);
    if (ret) return ret;
    if (val < 0 || val > 100) return -EINVAL; // Basic validation

    mutex_lock(&g_batt_data->lock);
    g_batt_data->capacity = val;
    mutex_unlock(&g_batt_data->lock);

    power_supply_changed(g_batt_data->psy);
    return count;
}

// Store status string
static ssize_t set_status_store(struct device *dev, struct device_attribute *attr,
                                const char *buf, size_t count) {
    int new_status = POWER_SUPPLY_STATUS_UNKNOWN; // Default
    size_t len = count;

    if (!g_batt_data) return -ENODEV;

    // Trim trailing newline if present
    if (len > 0 && buf[len - 1] == '\n') {
        len--;
    }

    // Convert string to enum (case-insensitive)
    if (strncasecmp(buf, "Charging", len) == 0) {
        new_status = POWER_SUPPLY_STATUS_CHARGING;
    } else if (strncasecmp(buf, "Discharging", len) == 0) {
        new_status = POWER_SUPPLY_STATUS_DISCHARGING;
    } else if (strncasecmp(buf, "Full", len) == 0) {
        new_status = POWER_SUPPLY_STATUS_FULL;
    } else if (strncasecmp(buf, "Not charging", len) == 0) {
        new_status = POWER_SUPPLY_STATUS_NOT_CHARGING;
    } else { // Any other string maps to Unknown
        new_status = POWER_SUPPLY_STATUS_UNKNOWN;
    }

    mutex_lock(&g_batt_data->lock);
    if (g_batt_data->status_enum != new_status) {
        g_batt_data->status_enum = new_status;
        mutex_unlock(&g_batt_data->lock);
        power_supply_changed(g_batt_data->psy); // Notify only if changed
    } else {
        mutex_unlock(&g_batt_data->lock);
    }
    return count;
}

// --- Sysfs Attribute Definitions (for writable attributes) ---
// Use DEVICE_ATTR_WO for Write-Only by userspace
static DEVICE_ATTR_WO(set_voltage_uv);
static DEVICE_ATTR_WO(set_capacity);
static DEVICE_ATTR_WO(set_status);

// --- Attribute Group (for writable attributes) ---
static struct attribute *userspace_batt_sysfs_attrs[] = {
    &dev_attr_set_voltage_uv.attr,
    &dev_attr_set_capacity.attr,
    &dev_attr_set_status.attr,
    NULL, // Null-terminated list
};

static const struct attribute_group userspace_batt_sysfs_attr_group = {
    .attrs = userspace_batt_sysfs_attrs,
};

// --- Power Supply 'get_property' Function (Read by kernel/upower) ---
static int userspace_batt_get_property(struct power_supply *psy,
                                       enum power_supply_property psp,
                                       union power_supply_propval *val) {
    // Get private data associated with the power_supply device
    struct userspace_batt_data *data = power_supply_get_drvdata(psy);
    int ret = 0;

    if (!data) return -ENODEV;

    mutex_lock(&data->lock);

    switch (psp) {
    case POWER_SUPPLY_PROP_VOLTAGE_NOW: // Expected in uV
        val->intval = (int)data->voltage_uv; // Cast u64 to int for propval
        break;
    case POWER_SUPPLY_PROP_CAPACITY: // Expected 0-100
        val->intval = data->capacity;
        break;
    case POWER_SUPPLY_PROP_STATUS: // Expected POWER_SUPPLY_STATUS_* enum
        val->intval = data->status_enum;
        break;
    default:
        ret = -EINVAL; // Property not supported
        break;
    }

    mutex_unlock(&data->lock);
    return ret;
}

// --- Power Supply Properties ---
static enum power_supply_property userspace_batt_properties[] = {
    POWER_SUPPLY_PROP_VOLTAGE_NOW,
    POWER_SUPPLY_PROP_CAPACITY,
    POWER_SUPPLY_PROP_STATUS,
};

// --- Platform Driver Probe / Remove ---

static int userspace_battery_probe(struct platform_device *pdev) {
    int ret;
    struct power_supply_config psy_cfg = {}; // Use initializer
    struct power_supply_desc *psy_desc;

    if (!g_batt_data) {
        dev_err(&pdev->dev, "userspace_battery: Global data not allocated!\n");
        return -ENODEV;
    }

    // Set the global platform device pointer for cleanup
    g_batt_data->pdev = pdev;

    // Allocate and configure power supply description
    psy_desc = devm_kzalloc(&pdev->dev, sizeof(*psy_desc), GFP_KERNEL);
    if (!psy_desc) return -ENOMEM;

    psy_desc->name = "userspace_battery"; // Name for /sys/class/power_supply/
    psy_desc->type = POWER_SUPPLY_TYPE_BATTERY;
    psy_desc->properties = userspace_batt_properties;
    psy_desc->num_properties = ARRAY_SIZE(userspace_batt_properties);
    psy_desc->get_property = userspace_batt_get_property;

    psy_cfg.drv_data = g_batt_data; // Link our data struct

    // Register the power supply device using the virtual platform device as parent
    g_batt_data->psy = devm_power_supply_register(&pdev->dev, psy_desc, &psy_cfg);
    if (IS_ERR(g_batt_data->psy)) {
        dev_err(&pdev->dev, "userspace_battery: Failed to register power supply, error %ld\n", PTR_ERR(g_batt_data->psy));
        return PTR_ERR(g_batt_data->psy);
    }
    dev_info(&pdev->dev, "userspace_battery: Registered power supply device.\n");

    // Create the writable sysfs attributes under the platform device
    // (/sys/devices/platform/userspace_battery/)
    ret = sysfs_create_group(&pdev->dev.kobj, &userspace_batt_sysfs_attr_group);
    if (ret) {
        dev_err(&pdev->dev, "userspace_battery: Failed to create sysfs group, error %d\n", ret);
        // devm_power_supply_register cleanup is automatic on return error
        return ret;
    }
    dev_info(&pdev->dev, "userspace_battery: Created sysfs attributes.\n");

    return 0; // Success
}

static int userspace_battery_remove(struct platform_device *pdev) {
    dev_info(&pdev->dev, "userspace_battery: Removing platform driver.\n");

    // Remove sysfs group created in probe
    sysfs_remove_group(&pdev->dev.kobj, &userspace_batt_sysfs_attr_group);

    // power_supply registration/cleanup is handled by devm
    // No need to free g_batt_data here, done in module_exit

    return 0;
}

// --- Platform Driver Definition ---
static struct platform_driver userspace_battery_platform_driver = {
    .driver = {
        .name = "userspace_battery", // Must match platform device name
    },
    .probe = userspace_battery_probe,
    .remove = userspace_battery_remove,
};

// --- Module Init / Exit ---
static int __init userspace_battery_init(void) {
    int ret;

    pr_info("userspace_battery: Loading module...\n");

    // Allocate global data structure
    g_batt_data = kzalloc(sizeof(*g_batt_data), GFP_KERNEL);
    if (!g_batt_data) {
        pr_err("userspace_battery: Failed to allocate memory\n");
        return -ENOMEM;
    }

    // Initialize defaults
    mutex_init(&g_batt_data->lock);
    g_batt_data->voltage_uv = 0;
    g_batt_data->capacity = -1; // Indicate uninitialized
    g_batt_data->status_enum = POWER_SUPPLY_STATUS_UNKNOWN;
    g_batt_data->pdev = NULL; // Not created yet
    g_batt_data->psy = NULL; // Not created yet

    // Create the virtual platform device - This acts as the parent device
    // ID -1 = auto-assign, no resources, no platform data
    g_batt_data->pdev = platform_device_register_simple("userspace_battery", -1, NULL, 0);
    if (IS_ERR(g_batt_data->pdev)) {
        ret = PTR_ERR(g_batt_data->pdev);
        pr_err("userspace_battery: Failed to register platform device, error %d\n", ret);
        kfree(g_batt_data);
        g_batt_data = NULL;
        return ret;
    }
    pr_info("userspace_battery: Registered virtual platform device.\n");

    // Register the platform driver, which will trigger the probe function
    ret = platform_driver_register(&userspace_battery_platform_driver);
    if (ret) {
        pr_err("userspace_battery: Failed to register platform driver, error %d\n", ret);
        platform_device_unregister(g_batt_data->pdev); // Clean up platform device
        kfree(g_batt_data);
        g_batt_data = NULL;
        return ret;
    }
    pr_info("userspace_battery: Registered platform driver.\n");

    pr_info("userspace_battery: Module loaded successfully.\n");
    return 0; // Success
}

static void __exit userspace_battery_exit(void) {
    pr_info("userspace_battery: Unloading module...\n");

    // Unregister the driver first (calls the remove function)
    platform_driver_unregister(&userspace_battery_platform_driver);
    pr_info("userspace_battery: Unregistered platform driver.\n");

    // Unregister the platform device
    if (g_batt_data && g_batt_data->pdev) {
        platform_device_unregister(g_batt_data->pdev);
        pr_info("userspace_battery: Unregistered platform device.\n");
    }

    // Free global data structure
    if (g_batt_data) {
        kfree(g_batt_data);
        g_batt_data = NULL;
        pr_info("userspace_battery: Freed global data.\n");
    }
     pr_info("userspace_battery: Module unloaded.\n");
}

module_init(userspace_battery_init);
module_exit(userspace_battery_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Your Name / Assisted by AI");
MODULE_DESCRIPTION("Virtual battery providing userspace updatable sysfs attributes via power_supply framework");
