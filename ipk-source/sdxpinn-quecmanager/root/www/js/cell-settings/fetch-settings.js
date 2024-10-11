// State variables to track current values
let currentSettings = {
  apn: "",
  pdpType: "",
};

let updatedSettings = {
  apn: "",
  pdpType: "",
};

let updatedNetworkMode = "";
let currentNetworkMode = "";

let currentNr5GModeControl = "";
let updatedNr5GModeControl = "";

let updatedSlot = "";
let currentSlot = "";

// Function to check if settings have changed
function haveSettingsChanged() {
  return (
    currentSettings.apn !== updatedSettings.apn ||
    currentSettings.pdpType !== updatedSettings.pdpType
  );
}

// Function to check if network mode has changed
function haveNetworkModeChanged() {
  console.log("Current network mode:", currentNetworkMode);
  console.log("Updated network mode:", updatedNetworkMode);
  return currentNetworkMode !== updatedNetworkMode;
}

// Function to check if NR5G mode control has changed
function haveNr5GModeControlChanged() {
  console.log("Current NR5G mode control:", currentNr5GModeControl);
  console.log("Updated NR5G mode control:", updatedNr5GModeControl);
  return currentNr5GModeControl !== updatedNr5GModeControl;
}

// Function to check if SIM slot has changed
function haveSimSlotChanged() {
  console.log("Current SIM slot:", currentSlot);
  console.log("Updated SIM slot:", updatedSlot);
  return currentSlot !== updatedSlot;
}

// Function to apply network mode changes immediately
async function applyNetworkModeChange() {
  if (!haveNetworkModeChanged()) {
    alert("No changes detected in the network mode.");
    return;
  }

  try {
    const atCommand = `AT+QNWPREFCFG="mode_pref",${updatedNetworkMode}`;
    console.log("Sending AT command for network mode change:", atCommand);
    const response = await sendATCommand(atCommand);
    console.log("AT command response:", response);
    alert("Network mode applied successfully!");
  } catch (error) {
    console.error("Error applying network mode:", error);
    alert("Error applying network mode. Please try again.");
  }
}

// Function to apply NR5G mode control changes immediately
async function applyNr5GModeControlChange() {
  if (!haveNr5GModeControlChanged()) {
    alert("No changes detected in the NR5G mode control.");
    return;
  }

  try {
    const atCommand = `AT+QNWPREFCFG="nr5g_disable_mode",${updatedNr5GModeControl}`;
    console.log("Sending AT command for NR5G mode control change:", atCommand);
    const response = await sendATCommand(atCommand);
    console.log("AT command response:", response);
    alert("NR5G mode control applied successfully!");
  } catch (error) {
    console.error("Error applying NR5G mode control:", error);
    alert("Error applying NR5G mode control. Please try again.");
  }
}

// Function to apply SIM slot changes immediately
async function applySimSlotChange() {
  if (!haveSimSlotChanged()) {
    alert("No changes detected in the SIM slot.");
    return;
  }

  try {
    const atCommand = `AT+QUIMSLOT=${updatedSlot}`;
    console.log("Sending AT command for SIM slot change:", atCommand);
    const response = await sendATCommand(atCommand);
    console.log("AT command response:", response);

    // Disable the select input while the SIM slot is being applied
    const simSlotSelect = document.getElementById("simSlot");
    simSlotSelect.disabled = true;

    // Send network deregistration command to apply SIM slot changes after 1 second
    await new Promise((resolve) => setTimeout(resolve, 1000));
    await sendATCommand("AT+COPS=2");
    // Wait for 2 seconds before turning on the modem
    await new Promise((resolve) => setTimeout(resolve, 2000));
    await sendATCommand("AT+COPS=0");

    // re-enable the select input after the SIM slot is applied
    simSlotSelect.disabled = false;

    alert("SIM slot applied successfully!");
  } catch (error) {
    console.error("Error applying SIM slot:", error);
    alert("Error applying SIM slot. Please try again.");
  }
}

// Function to send settings to the modem
async function saveSettings() {
  if (!haveSettingsChanged()) {
    alert("No changes detected in the settings.");
    return;
  }

  try {
    const atCommand = `AT+QMBNCFG="AutoSel",0;+CGDCONT=1,"${updatedSettings.pdpType}","${updatedSettings.apn}"`;
    console.log("Sending AT command:", atCommand);

    // Disable the input fields while the settings are being saved
    const inputs = document.querySelectorAll("input, select");
    inputs.forEach((input) => {
      input.disabled = true;
    });
    const response = await sendATCommand(atCommand);
    console.log("AT command response:", response);

    await sendATCommand(`AT+COPS=2`);
    // Wait for 2 seconds before turning on the modem
    await new Promise((resolve) => setTimeout(resolve, 2000));
    await sendATCommand(`AT+COPS=0`);

    // Re-enable the input fields after the settings are saved
    inputs.forEach((input) => {
      input.disabled = false;
    });

    // Update current settings after successful save
    currentSettings = { ...updatedSettings };
    alert("Settings saved successfully!");
  } catch (error) {
    console.error("Error saving settings:", error);
    alert("Error saving settings. Please try again.");
  }
}

async function resetAPN() {
  atCommand = `AT+QMBNCFG="AutoSel",1`;
  console.log("Sending AT command:", atCommand);

  try {
    const response = await sendATCommand(atCommand);
    console.log("AT command response:", response);

    // Restart connection after resetting APN settings
    await sendATCommand("AT+COPS=2");
    // Wait for 2 seconds before turning on the modem
    await new Promise((resolve) => setTimeout(resolve, 2000));
    await sendATCommand("AT+COPS=0");
    alert("APN settings reset successfully!");
  } catch (error) {
    console.error("Error resetting APN settings:", error);
    alert("Error resetting APN settings. Please try again.");
  }
}

async function sendATCommand(command) {
  try {
    const response = await fetch("/cgi-bin/atinout_handler.sh", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "command=" + encodeURIComponent(command),
    });
    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }
    const data = await response.json();
    return data;
  } catch (error) {
    console.error("Error sending AT command:", error);
    throw error;
  }
}

// Function to fetch cell settings data
async function fetchCellSettings() {
  try {
    const response = await fetch("/cgi-bin/cell-settings/cell-settings.sh");

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const data = await response.json();
    console.log("Full response:", data);

    data.forEach((item) => {
      if (item.response.includes("CGDCONT?")) {
        const apn = item.response
          .split("\n")[1]
          .split(":")[1]
          .split(",")[2]
          .replace(/"/g, "")
          .trim();

        currentSettings.apn = apn;
        updatedSettings.apn = apn;

        const apnInput = document.getElementById("currentAPN");
        if (apnInput) {
          apnInput.value = apn;

          // Add event listener for APN changes
          if (!apnInput.hasListener) {
            apnInput.hasListener = true;
            apnInput.addEventListener("input", (e) => {
              updatedSettings.apn = e.target.value;
            });
          }
        }

        const pdpType = item.response
          .split("\n")[1]
          .split(":")[1]
          .split(",")[1]
          .replace(/"/g, "")
          .trim();

        currentSettings.pdpType = pdpType;
        updatedSettings.pdpType = pdpType;

        const pdpTypeSelect = document.getElementById("apnPDP");
        if (pdpTypeSelect) {
          // Set initial value
          pdpTypeSelect.value =
            pdpType === "IPV4V6"
              ? "IPV4V6"
              : pdpType === "IPV6"
              ? "IPV6"
              : pdpType === "PPP"
              ? "PPP"
              : "IP";

          // Add event listener for PDP type changes
          if (!pdpTypeSelect.hasListener) {
            pdpTypeSelect.hasListener = true;
            pdpTypeSelect.addEventListener("change", (e) => {
              updatedSettings.pdpType = e.target.value;
            });
          }
        }
      } else if (item.response.includes("mode_pref")) {
        const networkMode = item.response
          .split("\n")[1]
          .replace("+QNWPREFCFG: ", "")
          .split(",")[1]
          .trim();

        currentNetworkMode = networkMode;
        updatedNetworkMode = networkMode;

        console.log("Network mode:", networkMode);

        const networkSelect = document.getElementById("networkPreference");
        if (networkSelect) {
          // Set initial value based on actual value from modem
          networkSelect.value =
            networkMode === "LTE:NR5G"
              ? "LTE:NR5G"
              : networkMode === "NR5G"
              ? "NR5G"
              : networkMode === "LTE"
              ? "LTE"
              : "AUTO";

          // Add event listener for network mode changes, if there is, run applyNetworkModeChange
          if (!networkSelect.hasListener) {
            networkSelect.hasListener = true;
            networkSelect.addEventListener("change", (e) => {
              updatedNetworkMode = e.target.value;
              applyNetworkModeChange();
            });
          }
        }
      } else if (item.response.includes("nr5g_disable_mode")) {
        const nr5GModeControl = item.response
          .split("\n")[1]
          .split(":")[1]
          .split(",")[1]
          .trim();

        console.log("NR5G mode control:", nr5GModeControl);

        currentNr5GModeControl = nr5GModeControl;
        updatedNr5GModeControl = nr5GModeControl;

        const nr5GControlSelect = document.getElementById("nr5gModeControl");

        if (nr5GControlSelect) {
          // Set initial value based on actual value from modem
          nr5GControlSelect.value =
            nr5GModeControl === "0" ? "0" : nr5GModeControl === "1" ? "1" : "2";

          // Add event listener for NR5G mode control changes, if there is, run applyNr5GModeControlChange
          if (!nr5GControlSelect.hasListener) {
            nr5GControlSelect.hasListener = true;
            nr5GControlSelect.addEventListener("change", (e) => {
              updatedNr5GModeControl = e.target.value;
              applyNr5GModeControlChange();
            });
          }
        }
      } else if (item.response.includes("QUIMSLOT")) {
        const slot = item.response
          .split("\n")[1]
          .split(":")[1]
          .split(",")[0]
          .trim();

        console.log("Slot:", slot);

        currentSlot = slot;
        updatedSlot = slot;

        const slotInput = document.getElementById("simSlot");
        if (slotInput) {
          // Explicitly set the value and update the selected option
          slotInput.value = slot;

          // Add event listener for slot changes if not already added
          if (!slotInput.hasListener) {
            slotInput.hasListener = true;
            slotInput.addEventListener("change", (e) => {
              updatedSlot = e.target.value;
              if (updatedSlot) {
                // Only apply if a valid slot is selected
                applySimSlotChange();
              }
            });
          }
        }
      }
    });
  } catch (error) {
    console.error("Error fetching cell settings:", error);
  }
}

// Initialize when DOM is loaded
document.addEventListener("DOMContentLoaded", () => {
  fetchCellSettings();

  // Add event listener for both save buttons
  const saveButtons = document.querySelectorAll(".card-footer-item");
  saveButtons.forEach((button) => {
    if (button.textContent.trim() === "Save APN") {
      button.addEventListener("click", saveSettings);
    } else if (button.textContent.trim() === "Reset APN") {
      button.addEventListener("click", resetAPN);
    }
  });

  // For every alert and close button, add event listener to refetch cell settings
  const alertButtons = document.querySelectorAll(".delete");
  alertButtons.forEach((button) => {
    button.addEventListener("click", fetchCellSettings);
  });
});
