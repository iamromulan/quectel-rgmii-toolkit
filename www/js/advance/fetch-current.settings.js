async function fetchCurrentSettings() {
  try {
    const response = await fetch("/cgi-bin/advanced_settings.sh");
    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }
    const data = await response.json();
    console.log("Current settings:", data);
    return data;
  } catch (error) {
    console.error("Error fetching current settings:", error);
    return null;
  }
}

async function fetchConnectedDevices() {
  try {
    const response = await fetch("/cgi-bin/fetch_macs.sh");
    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const data = await response.json();
    console.log("Connected devices:", data);
    return data;
  } catch (error) {
    console.error("Error fetching connected devices:", error);
    return null;
  }
}

function populateConnectedDevices(devices) {
  const selectElement = document.getElementById("connected-devices");
  if (!selectElement) {
    console.error("Connected devices select element not found");
    return;
  }

  // Clear existing options except the first one
  while (selectElement.options.length > 1) {
    selectElement.remove(1);
  }

  // Add new options
  devices.forEach((device) => {
    const option = document.createElement("option");
    option.value = device.mac;
    option.textContent = `${device.hostname} - ${device.mac}`;
    selectElement.appendChild(option);
  });
}

function updatePassthroughModeState(isEnabled) {
  const ipPassthroughSelect = document.getElementById("ip-passthrough-mode");
  if (!ipPassthroughSelect) return;

  if (isEnabled) {
    ipPassthroughSelect.removeAttribute("disabled");
    ipPassthroughSelect.classList.remove("is-warning");
    const helpText = ipPassthroughSelect.parentElement.querySelector(".help");
    if (helpText) {
      helpText.textContent = "Select a passthrough mode to apply.";
      helpText.classList.remove("is-warning");
      helpText.classList.add("is-info");
    }
  } else {
    ipPassthroughSelect.setAttribute("disabled", "disabled");
    ipPassthroughSelect.classList.add("is-warning");
    ipPassthroughSelect.value = "Select IP Passthrough Mode";
    const helpText = ipPassthroughSelect.parentElement.querySelector(".help");
    if (helpText) {
      helpText.textContent = "Please select a device first.";
      helpText.classList.remove("is-info");
      helpText.classList.add("is-warning");
    }
  }
}

function updateUIElements(data) {
  // Get all required DOM elements
  const elements = {
    ipPassthrough: document.getElementById("ip-passthrough-mode"),
    dnsProxy: document.getElementById("dns-proxy-mode"),
    usbModem: document.getElementById("usb-modem-protocol"),
  };

  // Check if all elements exist
  const missingElements = Object.entries(elements)
    .filter(([key, element]) => !element)
    .map(([key]) => key);

  if (missingElements.length > 0) {
    console.error("Missing DOM elements:", missingElements);
    return false;
  }

  try {
    // Initially disable IP Passthrough mode
    updatePassthroughModeState(false);

    // Passthrough Mode (will be disabled until device is selected)
    const mpdnRuleLine = data[0].response.split("\n")[1];
    if (mpdnRuleLine) {
      const mpdnRule = mpdnRuleLine.split(":")[1].trim();
      switch (mpdnRule) {
        case '"MPDN_rule",0,0,0,0,0':
          elements.ipPassthrough.value = "Disabled";
          break;
        case '"MPDN_rule",0,1,0,1,1':
          elements.ipPassthrough.value = "ETH Only";
          break;
        case '"MPDN_rule",0,1,0,3,1':
          elements.ipPassthrough.value = "USB Only";
          break;
        default:
          elements.ipPassthrough.value = "Select IP Passthrough Mode";
          break;
      }
    }

    // DNS Proxy
    const dnsProxyLine = data[1].response
      .split("\n")[1]
      .split(":")[1]
      .split(",")[1]
      .trim();
    if (dnsProxyLine) {
      elements.dnsProxy.value =
        dnsProxyLine === '"disable"' ? "Disabled" : "Enabled";
    } else {
      elements.dnsProxy.value = "Select Onboard DNS Proxy";
    }

    // USB Modem Protocol
    const usbModemProtocolLine = data[2].response
      .split("\n")[1]
      .split(":")[1]
      .split(",")[1]
      .trim();
    switch (usbModemProtocolLine) {
      case "0":
        elements.usbModem.value = "RMNET";
        break;
      case "1":
        elements.usbModem.value = "ECM (Recommended)";
        break;
      case "2":
        elements.usbModem.value = "MBIM";
        break;
      case "3":
        elements.usbModem.value = "RNDIS";
        break;
      default:
        elements.usbModem.value = "Select USB Modem Protocol";
        break;
    }

    return true;
  } catch (error) {
    console.error("Error updating UI elements:", error);
    return false;
  }
}

// Function to send an AT command based on the DNS proxy mode
async function sendDnsProxyCommand(command) {
  try {
    const response = await fetch("/cgi-bin/atinout_handler.sh", {
      method: "POST",
      body: "command=" + encodeURIComponent(command),
    });

    const data = await response.json();
    console.log("DNS Proxy AT command executed:", data.output);
  } catch (error) {
    console.error("Error sending DNS Proxy AT command:", error);
  }
}

// Function to handle DNS Proxy changes
function handleDnsProxyChange() {
  const dnsProxySelect = document.getElementById("dns-proxy-mode");
  const currentDnsProxyMode = dnsProxySelect.getAttribute("data-current-mode"); // Store current mode as a data attribute

  dnsProxySelect.addEventListener("change", function (e) {
    const selectedMode = e.target.value;

    // Send AT command only if the selected mode differs from the current one
    if (selectedMode !== currentDnsProxyMode) {
      if (selectedMode === "Enabled") {
        sendDnsProxyCommand('AT+QMAP="DHCPV4DNS","enable"');
      } else if (selectedMode === "Disabled") {
        sendDnsProxyCommand('AT+QMAP="DHCPV4DNS","disable"');
      }
    } else {
      console.log("No changes made to DNS Proxy mode");
    }
  });
}

// Function to send an AT command based on the IP Passthrough mode
async function sendIpPassthroughCommand(command) {
  if (command) {
    showLoadingContent(); // Show loading content and hide the buttons
    startCountdown(80); // Start the countdown for 5 seconds
  }
  try {
    const response = await fetch("/cgi-bin/atinout_handler.sh", {
      method: "POST",
      body: "command=" + encodeURIComponent(command),
    });

    const data = await response.json();
    console.log("IP Passthrough AT command executed:", data.output);
  } catch (error) {
    console.error("Error sending IP Passthrough AT command:", error);
  }
}

// Function to handle IP Passthrough mode changes
function handleIpPassthroughChange() {
  // track if the device is selected by listening to the connected devices dropdown change event
  const connectedDevicesSelect = document.getElementById("connected-devices");
  if (connectedDevicesSelect) {
    connectedDevicesSelect.addEventListener("change", function (e) {
      const selectedMAC = e.target.value;
      const selectedHostname = e.target.options[e.target.selectedIndex].text;
      console.log("Selected device:", {
        mac: selectedMAC,
        hostname: selectedHostname,
      });

      // Enable/disable IP Passthrough mode based on selection
      const isDeviceSelected = selectedMAC !== "Select Device MAC";
      if (isDeviceSelected) {
        updatePassthroughModeState(true);
      } else {
        updatePassthroughModeState(false);
      }
    });
  }

  const ipPassthroughSelect = document.getElementById("ip-passthrough-mode");
  const currentIpPassthroughMode =
    ipPassthroughSelect.getAttribute("data-current-mode"); // Store current mode as a data attribute

  ipPassthroughSelect.addEventListener("change", function (e) {
    const selectedMode = e.target.value;
    const selectedDeviceMAC =
      document.getElementById("connected-devices").value;

    // Send AT command only if the selected mode differs from the current one
    if (selectedMode !== currentIpPassthroughMode) {
      let command;
      switch (selectedMode) {
        case "Disabled":
          command = 'AT+QMPDN="MPDN_rule",0;+CFUN=1,1';
          break;
        case "ETH Only":
          command = `AT+QMPDN="MPDN_rule",0,1,0,1,1,"${selectedDeviceMAC}"`;
          break;
        case "USB Only":
          command = `AT+QMPDN="MPDN_rule",0,1,0,3,1,"${selectedDeviceMAC}"`;
          break;
        default:
          console.error("Invalid IP Passthrough mode:", selectedMode);
          return;
      }

      sendIpPassthroughCommand(command);
    } else {
      console.log("No changes made to IP Passthrough mode");
    }
  });
}

// Function to send an AT command based on the USB Modem Protocol
async function sendUsbModemProtocolCommand(command) {
  try {
    if (command) {
      showLoadingContent(); // Show loading content and hide the buttons
      startCountdown(80); // Start the countdown for 5 seconds
    }
    const response = await fetch("/cgi-bin/atinout_handler.sh", {
      method: "POST",
      body: "command=" + encodeURIComponent(command),
    });

    const data = await response.json();
    console.log("USB Modem Protocol AT command executed:", data.output);
  } catch (error) {
    console.error("Error sending USB Modem Protocol AT command:", error);
  }
}

// Function to handle USB Modem Protocol changes
function handleUsbModemProtocolChange() {
  const usbModemSelect = document.getElementById("usb-modem-protocol");
  const currentUsbModemProtocol = usbModemSelect.getAttribute(
    "data-current-protocol"
  ); // Store current protocol as a data attribute

  usbModemSelect.addEventListener("change", function (e) {
    const selectedProtocol = e.target.value;

    // Send AT command only if the selected protocol differs from the current one
    if (selectedProtocol !== currentUsbModemProtocol) {
      let command;
      switch (selectedProtocol) {
        case "RMNET":
          command = 'AT+QCFG="usbnet",0;+CFUN=1,1';
          break;
        case "ECM (Recommended)":
          command = 'AT+QCFG="usbnet",1;+CFUN=1,1';
          break;
        case "MBIM":
          command = 'AT+QCFG="usbnet",2;+CFUN=1,1';
          break;
        case "RNDIS":
          command = 'AT+QCFG="usbnet",3;+CFUN=1,1';
          break;
        default:
          console.error("Invalid USB Modem Protocol:", selectedProtocol);
          return;
      }

      sendUsbModemProtocolCommand(command);
    } else {
      console.log("No changes made to USB Modem Protocol");
    }
  });
}

// Function to show the modal
function showModal() {
  const modal = document.getElementById("reboot-modal");
  if (modal) {
    modal.classList.add("is-active"); // Bulma modals require "is-active" to be shown
  }
}

// Function to show loading content and show the modal
function showLoadingContent() {
  document.getElementById("loading-content").style.display = "flex"; // Show the loading section
  document.getElementById("modal-buttons").style.display = "none"; // Hide the buttons

  // Activate the modal
  showModal();
}

// Function to start the countdown
function startCountdown(duration) {
  let countdownElement = document.getElementById("countdown");
  let countdown = duration;
  let interval = setInterval(function () {
    countdown--;
    countdownElement.textContent = countdown;

    if (countdown <= 0) {
      clearInterval(interval);
      // Add any additional logic after countdown reaches 0 (like reloading or closing the modal)
      location.reload(); // Reload the page
    }
  }, 1000);
}

// Function for initializing the page
function init() {
  // Replace all i elements under the class advanced-settings with a spinner icon initially
  const advancedSettingsIcons = document.querySelectorAll(
    ".advanced-settings i"
  );
  advancedSettingsIcons.forEach((icon) => {
    icon.classList.add("fa-spinner", "fa-spin");
  });

  Promise.all([fetchCurrentSettings(), fetchConnectedDevices()])
    .then(([settings, devices]) => {
      if (settings) {
        const updateSuccess = updateUIElements(settings);
        if (!updateSuccess) {
          console.error("Failed to update UI elements");
        } else {
          // Revert the spinner icons back to their original state
          advancedSettingsIcons.forEach((icon) => {
            icon.classList.remove("fa-spinner", "fa-spin");
          });

          handleDnsProxyChange(); // Add event listener for DNS Proxy changes
          handleUsbModemProtocolChange(); // Add event listener for USB Modem Protocol changes
          handleIpPassthroughChange(); // Add event listener for IP Passthrough changes
        }
      } else {
        console.error("Failed to fetch current settings");
      }

      if (devices) {
        populateConnectedDevices(devices);
      } else {
        console.error("Failed to fetch connected devices");
      }
    })
    .catch((error) => {
      console.error("Error during initialization:", error);
    });
}

// Initialize event listeners when DOM is ready
// document.addEventListener("DOMContentLoaded", () => {
//   // Initialize the page
//   init();

//   //   Add event listener for usb modem protocol changes
//   handleUsbModemProtocolChange();

//   // Add event listener for connected devices dropdown
//   const connectedDevicesSelect = document.getElementById("connected-devices");
//   if (connectedDevicesSelect) {
//     connectedDevicesSelect.addEventListener("change", function (e) {
//       const selectedMAC = e.target.value;
//       const selectedHostname = e.target.options[e.target.selectedIndex].text;
//       console.log("Selected device:", {
//         mac: selectedMAC,
//         hostname: selectedHostname,
//       });

//       // Enable/disable IP Passthrough mode based on selection
//       const isDeviceSelected = selectedMAC !== "Select Device MAC";
//       updatePassthroughModeState(isDeviceSelected);
//     });
//   }

//   // Add event listener for IP Passthrough mode changes
//   const ipPassthroughSelect = document.getElementById("ip-passthrough-mode");
//   if (ipPassthroughSelect) {
//     ipPassthroughSelect.addEventListener("change", function (e) {
//       const selectedMode = e.target.value;
//       const connectedDevicesSelect =
//         document.getElementById("connected-devices");
//       const selectedMAC = connectedDevicesSelect
//         ? connectedDevicesSelect.value
//         : null;

//       if (selectedMAC && selectedMAC !== "Select Device MAC") {
//         console.log("Applying IP Passthrough mode:", {
//           mode: selectedMode,
//           deviceMAC: selectedMAC,
//         });
//         // Here you can add the API call to apply the passthrough mode
//       } else {
//         console.error("No device selected for IP Passthrough mode");
//         e.target.value = "Select IP Passthrough Mode";
//       }
//     });
//   }
// });
// Initialize event listeners when DOM is ready
document.addEventListener("DOMContentLoaded", () => {
  // Initialize the page
  init();
});
