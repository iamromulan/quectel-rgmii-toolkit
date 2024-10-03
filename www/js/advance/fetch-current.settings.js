// api.js - API related functions
const api = {
  async fetch(endpoint, options = {}) {
    try {
      const response = await fetch(endpoint, options);
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      return await response.json();
    } catch (error) {
      console.error(`API Error (${endpoint}):`, error);
      return null;
    }
  },

  async fetchCurrentSettings() {
    const data = await this.fetch("/cgi-bin/advanced_settings.sh");
    console.log("Current settings:", data);
    return data;
  },

  async fetchConnectedDevices() {
    const data = await this.fetch("/cgi-bin/fetch_macs.sh");
    return data;
  },

  async sendATCommand(command) {
    return await this.fetch("/cgi-bin/atinout_handler.sh", {
      method: "POST",
      body: "command=" + encodeURIComponent(command)
    });
  }
};

// uiManager.js - UI related functions
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
  }
};

// settingsManager.js - Settings management
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
        elements.ipPassthrough.value = this.getPassthroughModeValue(mpdnRule);
      }

      // Update DNS Proxy
      const dnsProxyLine = data[1].response.split("\n")[1].split(":")[1].split(",")[1].trim();
      elements.dnsProxy.value = dnsProxyLine === '"disable"' ? "Disabled" : "Enabled";

      // Update USB Modem Protocol
      const usbModemProtocolLine = data[2].response.split("\n")[1].split(":")[1].split(",")[1].trim();
      elements.usbModem.value = this.getUsbModemProtocolValue(usbModemProtocolLine);

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

// eventHandlers.js - Event handling
const eventHandlers = {
  async handleDnsProxyChange(e) {
    const selectedMode = e.target.value;
    const currentMode = e.target.getAttribute("data-current-mode");

    if (selectedMode !== currentMode) {
      const command = selectedMode === "Enabled" 
        ? 'AT+QMAP="DHCPV4DNS","enable"'
        : 'AT+QMAP="DHCPV4DNS","disable"';
      await api.sendATCommand(command);
    }
  },

  async handleIpPassthroughChange(e) {
    const selectedMode = e.target.value;
    const currentMode = e.target.getAttribute("data-current-mode");
    const selectedDeviceMAC = uiManager.elements.connectedDevices().value;

    if (selectedMode !== currentMode) {
      const commands = {
        "Disabled": 'AT+QMPDN="MPDN_rule",0;+CFUN=1,1',
        "ETH Only": `AT+QMPDN="MPDN_rule",0,1,0,1,1,"${selectedDeviceMAC}"`,
        "USB Only": `AT+QMPDN="MPDN_rule",0,1,0,3,1,"${selectedDeviceMAC}"`
      };

      const command = commands[selectedMode];
      if (command) {
        uiManager.showLoadingContent();
        uiManager.startCountdown(80);
        await api.sendATCommand(command);
      }
    }
  },

  async handleUsbModemProtocolChange(e) {
    const selectedProtocol = e.target.value;
    const currentProtocol = e.target.getAttribute("data-current-protocol");

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
        uiManager.startCountdown(80);
        await api.sendATCommand(command);
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

// main.js - Application initialization
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
        uiManager.hideLoadingSpinners();
        
        // Set up event listeners
        uiManager.elements.dnsProxy().addEventListener("change", eventHandlers.handleDnsProxyChange);
        uiManager.elements.ipPassthrough().addEventListener("change", eventHandlers.handleIpPassthroughChange);
        uiManager.elements.usbModem().addEventListener("change", eventHandlers.handleUsbModemProtocolChange);
        uiManager.elements.connectedDevices().addEventListener("change", eventHandlers.handleDeviceSelection);
      }
    }

    if (devices) {
      uiManager.populateConnectedDevices(devices);
    }
  } catch (error) {
    console.error("Initialization error:", error);
  }
}

// Initialize when DOM is ready
document.addEventListener("DOMContentLoaded", init);