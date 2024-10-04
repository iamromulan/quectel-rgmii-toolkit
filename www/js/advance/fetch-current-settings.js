// API Module - Handles all server communications
const api = {
  async fetchCurrentSettings() {
    try {
      const response = await fetch("/cgi-bin/advanced_settings.sh");
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      const data = await response.json();
      console.log("Current settings:", data);
      return data;
    } catch (error) {
      console.error("Error fetching settings:", error);
      throw error;
    }
  },

  async fetchConnectedDevices() {
    try {
      const response = await fetch("/cgi-bin/fetch_macs.sh");
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      const data = await response.json();
      return data;
    } catch (error) {
      console.error("Error fetching devices:", error);
      throw error;
    }
  },

  async sendATCommand(command) {
    try {
      const response = await fetch("/cgi-bin/atinout_handler.sh", {
        method: "POST",
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: "command=" + encodeURIComponent(command)
      });
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      const data = await response.json();
      console.log("AT command response:", data);
      return data;
    } catch (error) {
      console.error("Error sending AT command:", error);
      throw error;
    }
  }
};

// UI Manager Module - Handles all DOM interactions and UI updates
const uiManager = {
  elements: {
    ipPassthrough: () => document.getElementById("ip-passthrough-mode"),
    dnsProxy: () => document.getElementById("dns-proxy-mode"),
    usbModem: () => document.getElementById("usb-modem-protocol"),
    connectedDevices: () => document.getElementById("connected-devices"),
    loadingContent: () => document.getElementById("loading-content"),
    modalButtons: () => document.getElementById("modal-buttons"),
    countdown: () => document.getElementById("countdown"),
    rebootModal: () => document.getElementById("reboot-modal"),
    advancedSettingsIcons: () => document.querySelectorAll(".advanced-settings i")
  },

  showLoadingSpinners() {
    this.elements.advancedSettingsIcons().forEach(icon => {
      icon.classList.add("fa-spinner", "fa-spin");
    });
  },

  hideLoadingSpinners() {
    this.elements.advancedSettingsIcons().forEach(icon => {
      icon.classList.remove("fa-spinner", "fa-spin");
    });
  },

  updatePassthroughModeState(isEnabled) {
    const select = this.elements.ipPassthrough();
    if (!select) return;

    const helpText = select.parentElement.querySelector(".help");
    
    if (isEnabled) {
      select.removeAttribute("disabled");
      select.classList.remove("is-warning");
      if (helpText) {
        helpText.textContent = "Select a passthrough mode to apply.";
        helpText.classList.remove("is-warning");
        helpText.classList.add("is-info");
      }
    } else {
      select.setAttribute("disabled", "disabled");
      select.classList.add("is-warning");
      select.value = "Select IP Passthrough Mode";
      if (helpText) {
        helpText.textContent = "Please select a device first.";
        helpText.classList.remove("is-info");
        helpText.classList.add("is-warning");
      }
    }
  },

  populateConnectedDevices(devices) {
    const select = this.elements.connectedDevices();
    if (!select) {
      console.error("Connected devices select element not found");
      return;
    }

    // Clear existing options except the first one
    while (select.options.length > 1) {
      select.remove(1);
    }

    // Add new options
    devices.forEach(device => {
      const option = document.createElement("option");
      option.value = device.mac;
      option.textContent = `${device.hostname} - ${device.mac}`;
      select.appendChild(option);
    });
  },

  showModal() {
    const modal = this.elements.rebootModal();
    if (modal) {
      modal.classList.add("is-active");
    }
  },

  showLoadingContent() {
    this.elements.loadingContent().style.display = "flex";
    this.elements.modalButtons().style.display = "none";
    this.showModal();
  },

  startCountdown(duration) {
    const countdownElement = this.elements.countdown();
    let countdown = duration;
    
    const interval = setInterval(() => {
      countdown--;
      countdownElement.textContent = countdown;

      if (countdown <= 0) {
        clearInterval(interval);
        location.reload();
      }
    }, 1000);
  },

  // showSuccessMessage(message) {
  //   // Implement based on your UI framework
  //   console.log("Success:", message);
  //   // Example: Show a toast notification
  //   if (window.bulmaToast) {
  //     bulmaToast.toast({
  //       message: message,
  //       type: 'is-success',
  //       duration: 3000,
  //       position: 'top-center',
  //     });
  //   }
  // },

  // showErrorMessage(message) {
  //   // Implement based on your UI framework
  //   console.error("Error:", message);
  //   // Example: Show a toast notification
  //   if (window.bulmaToast) {
  //     bulmaToast.toast({
  //       message: message,
  //       type: 'is-danger',
  //       duration: 5000,
  //       position: 'top-center',
  //     });
  //   }
  // },

  setElementLoading(element, isLoading) {
    if (isLoading) {
      element.disabled = true;
      element.classList.add('is-loading');
    } else {
      element.disabled = false;
      element.classList.remove('is-loading');
    }
  }
};

// Settings Manager Module - Handles settings logic and updates
const settingsManager = {
  async updateSettings(data) {
    const elements = {
      ipPassthrough: uiManager.elements.ipPassthrough(),
      dnsProxy: uiManager.elements.dnsProxy(),
      usbModem: uiManager.elements.usbModem()
    };

    // Validate required elements
    const missingElements = Object.entries(elements)
      .filter(([, element]) => !element)
      .map(([key]) => key);

    if (missingElements.length > 0) {
      console.error("Missing DOM elements:", missingElements);
      return false;
    }

    try {
      uiManager.updatePassthroughModeState(false);

      // Update IP Passthrough Mode
      const mpdnRuleLine = data[0].response.split("\n")[1];
      if (mpdnRuleLine) {
        const mpdnRule = mpdnRuleLine.split(":")[1].trim();
        const passthroughMode = this.getPassthroughModeValue(mpdnRule);
        elements.ipPassthrough.value = passthroughMode;
        elements.ipPassthrough.setAttribute("data-current-mode", passthroughMode);
      }

      // Update DNS Proxy
      const dnsProxyLine = data[1].response.split("\n")[1].split(":")[1].split(",")[1].trim();
      const dnsProxyMode = dnsProxyLine === '"disable"' ? "Disabled" : "Enabled";
      elements.dnsProxy.value = dnsProxyMode;
      elements.dnsProxy.setAttribute("data-current-mode", dnsProxyMode);

      // Update USB Modem Protocol
      const usbModemProtocolLine = data[2].response.split("\n")[1].split(":")[1].split(",")[1].trim();
      const usbModemMode = this.getUsbModemProtocolValue(usbModemProtocolLine);
      elements.usbModem.value = usbModemMode;
      elements.usbModem.setAttribute("data-current-protocol", usbModemMode);

      return true;
    } catch (error) {
      console.error("Error updating settings:", error);
      return false;
    }
  },

  getPassthroughModeValue(mpdnRule) {
    const modes = {
      '"MPDN_rule",0,0,0,0,0': "Disabled",
      '"MPDN_rule",0,1,0,1,1': "ETH Only",
      '"MPDN_rule",0,1,0,3,1': "USB Only"
    };
    return modes[mpdnRule] || "Select IP Passthrough Mode";
  },

  getUsbModemProtocolValue(protocol) {
    const protocols = {
      "0": "RMNET",
      "1": "ECM (Recommended)",
      "2": "MBIM",
      "3": "RNDIS"
    };
    return protocols[protocol] || "Select USB Modem Protocol";
  }
};

// Event Handlers Module - Handles all event listeners
const eventHandlers = {
  async handleDnsProxyChange(e) {
    const element = e.target;
    const selectedMode = element.value;
    const currentMode = element.getAttribute("data-current-mode");

    if (selectedMode !== currentMode) {
      const command = selectedMode === "Enabled" 
        ? 'AT+QMAP="DHCPV4DNS","enable"'
        : 'AT+QMAP="DHCPV4DNS","disable"';
      
      uiManager.setElementLoading(element, true);
      
      try {
        const response = await api.sendATCommand(command);
        if (response.output.includes("OK")) {
          element.setAttribute("data-current-mode", selectedMode);
          // uiManager.showSuccessMessage("DNS Proxy setting updated successfully");
        } else {
          element.value = currentMode;
          // uiManager.showErrorMessage("Failed to update DNS Proxy setting");
        }
      } catch (error) {
        console.error("Error sending AT command:", error);
        element.value = currentMode;
        // uiManager.showErrorMessage("Error updating DNS Proxy setting");
      } finally {
        // uiManager.setElementLoading(element, false);
      }
    }
  },

  async handleIpPassthroughChange(e) {
    const element = e.target;
    const selectedMode = element.value;
    const currentMode = element.getAttribute("data-current-mode");
    const selectedDeviceMAC = uiManager.elements.connectedDevices().value;

    if (selectedMode !== currentMode) {
      const commands = {
        "Disabled": 'AT+QMAP="MPDN_rule",0;+QPOWD=1',
        "ETH Only": `AT+QMAP="MPDN_rule",0,1,0,1,1,"${selectedDeviceMAC}";+QPOWD=1`,
        "USB Only": `AT+QMAP="MPDN_rule",0,1,0,3,1,"${selectedDeviceMAC}";+QPOWD=1`
      };

      const command = commands[selectedMode];
      if (command) {
        uiManager.showLoadingContent();
        uiManager.startCountdown(90);
        try {
          await api.sendATCommand(command);
        } catch (error) {
          uiManager.showErrorMessage("Error updating IP Passthrough mode");
        }
      }
    }
  },

  async handleUsbModemProtocolChange(e) {
    const element = e.target;
    const selectedProtocol = element.value;
    const currentProtocol = element.getAttribute("data-current-protocol");

    if (selectedProtocol !== currentProtocol) {
      const commands = {
        "RMNET": 'AT+QCFG="usbnet",0;+CFUN=1,1',
        "ECM (Recommended)": 'AT+QCFG="usbnet",1;+CFUN=1,1',
        "MBIM": 'AT+QCFG="usbnet",2;+CFUN=1,1',
        "RNDIS": 'AT+QCFG="usbnet",3;+CFUN=1,1'
      };

      const command = commands[selectedProtocol];
      if (command) {
        uiManager.showLoadingContent();
        uiManager.startCountdown(90);
        try {
          await api.sendATCommand(command);
        } catch (error) {
          uiManager.showErrorMessage("Error updating USB Modem Protocol");
        }
      }
    }
  },

  handleDeviceSelection(e) {
    const selectedMAC = e.target.value;
    const selectedHostname = e.target.options[e.target.selectedIndex].text;
    console.log("Selected device:", { mac: selectedMAC, hostname: selectedHostname });

    const isDeviceSelected = selectedMAC !== "Select Device MAC";
    uiManager.updatePassthroughModeState(isDeviceSelected);
  }
};

// Application Initialization
async function init() {
  uiManager.showLoadingSpinners();

  try {
    const [settings, devices] = await Promise.all([
      api.fetchCurrentSettings(),
      api.fetchConnectedDevices()
    ]);

    if (settings) {
      const updateSuccess = await settingsManager.updateSettings(settings);
      if (updateSuccess) {
        // Set up event listeners
        const dnsProxyElement = uiManager.elements.dnsProxy();
        const ipPassthroughElement = uiManager.elements.ipPassthrough();
        const usbModemElement = uiManager.elements.usbModem();
        const connectedDevicesElement = uiManager.elements.connectedDevices();

        if (dnsProxyElement) {
          dnsProxyElement.addEventListener("change", eventHandlers.handleDnsProxyChange);
        }
        if (ipPassthroughElement) {
          ipPassthroughElement.addEventListener("change", eventHandlers.handleIpPassthroughChange);
        }
        if (usbModemElement) {
          usbModemElement.addEventListener("change", eventHandlers.handleUsbModemProtocolChange);
        }
        if (connectedDevicesElement) {
          connectedDevicesElement.addEventListener("change", eventHandlers.handleDeviceSelection);
        }
      }
    }

    if (devices) {
      uiManager.populateConnectedDevices(devices);
    }
  } catch (error) {
    console.error("Initialization error:", error);
    uiManager.showErrorMessage("Error initializing settings");
  } finally {
    uiManager.hideLoadingSpinners();
  }
}

// Initialize when DOM is ready
document.addEventListener("DOMContentLoaded", init);