// State variables to track current values
let currentIMEI = "";
let updatedIMEI = "";

// Constants
const REBOOT_COUNTDOWN_TIME = 80;
const MESSAGES = {
  DEFAULT_REBOOT: "Do not do any action while the modem is rebooting.",
  IMEI_REBOOT:
    "IMEI change requires a reboot.\nDo not perform any actions while the modem is rebooting.",
  INVALID_IMEI: "IMEI should be 15 digits and should only contain numbers.",
  NO_CHANGES: "No changes detected in the IMEI field.",
  ERROR_SAVING: "Error saving settings. Please try again.",
};

const DATA_MAP = {
  CGMI: {
    parse: (response) => response.split("\n")[1].trim(),
    elementId: "manufacturer",
  },
  CGMM: {
    parse: (response) => response.split("\n")[1].trim(),
    elementId: "model",
  },
  CGMR: {
    parse: (response) => response.split("\n")[1].trim(),
    elementId: "firmwareVersion",
  },
  CNUM: {
    parse: (response) =>
      response
        .split("\n")[1]
        .split(":")[1]
        .split(",")[1]
        .replace(/"/g, "")
        .trim(),
    elementId: "phoneNumber",
  },
  CIMI: {
    parse: (response) => response.split("\n")[1].trim(),
    elementId: "imsi",
  },
  ICCID: {
    parse: (response) => response.split("\n")[1].split(":")[1].trim(),
    elementId: "iccid",
  },
  CGSN: {
    parse: (response) => response.split("\n")[1].trim(),
    elementId: "imei",
    special: true,
  },
  LANIP: {
    parse: (response) =>
      response.split("\n")[1].split(":")[1].split(",")[3].trim(),
    elementId: "lanIP",
  },
  WWAN: {
    parse: (response) => ({
      IPv4: response
        .split("\n")[1]
        .split(":")[1]
        .split(",")[4]
        .replace(/"/g, "")
        .trim(),
      IPv6: response.split("\n")[2].split(",")[4].replace(/"/g, "").trim(),
    }),
    elementIds: ["IPv4", "IPv6"],
  },
};

// DOM Element Selectors
const selectors = {
  modal: "#reboot-modal",
  countdown: "#countdown",
  loadingContent: "#loading-content",
  modalButtons: "#modal-buttons",
  modalMessage: "#modal-message",
  imeiInput: "#imeiInput",
  changeButton: "#changeButton",
  powerButton: ".reboot-modal",
  alertButtons: ".delete",
  modalBackground: ".modal-background",
  cancelButton: ".cancel",
  rebootButton: "#rebootModem",
};

// Utility Functions
function getElement(selector) {
  return document.querySelector(selector);
}

function validateIMEI(imei) {
  return imei.length === 15 && !isNaN(imei);
}

function updateElementDisplay(element, display) {
  if (element) element.style.display = display;
}

// IMEI Management Functions
function haveIMEIChanged() {
  return currentIMEI !== updatedIMEI;
}

function resetIMEIInput() {
  const imeiInput = getElement(selectors.imeiInput);
  if (imeiInput) {
    imeiInput.value = currentIMEI;
    updatedIMEI = currentIMEI;
  }
}

// AT Command Functions
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
    return await response.json();
  } catch (error) {
    console.error("Error sending AT command:", error);
    throw error;
  }
}

// Modal Management Functions
function handleRebootCountdown() {
  const countdownElement = getElement(selectors.countdown);
  const loadingContent = getElement(selectors.loadingContent);
  const modalButtons = getElement(selectors.modalButtons);
  const modalMessage = getElement(selectors.modalMessage);

  updateElementDisplay(modalMessage, "none");
  updateElementDisplay(modalButtons, "none");
  updateElementDisplay(loadingContent, "block");

  let timeLeft = REBOOT_COUNTDOWN_TIME;

  const countdownInterval = setInterval(() => {
    timeLeft--;
    if (countdownElement) countdownElement.textContent = timeLeft;

    if (timeLeft <= 0) {
      clearInterval(countdownInterval);
      window.location.reload();
    }
  }, 1000);
}

function showRebootModal(isIMEIChange = false) {
  const modal = getElement(selectors.modal);
  const loadingContent = getElement(selectors.loadingContent);
  const modalButtons = getElement(selectors.modalButtons);
  const modalMessage = getElement(selectors.modalMessage);

  if (!modal) return;

  modal.classList.add("is-active");

  updateElementDisplay(loadingContent, "none");
  updateElementDisplay(modalButtons, "block");
  updateElementDisplay(modalMessage, "block");

  if (modalMessage) {
    modalMessage.textContent = isIMEIChange
      ? MESSAGES.IMEI_REBOOT
      : MESSAGES.DEFAULT_REBOOT;
    modalMessage.style.whiteSpace = "pre-line";
  }

  setupModalEventListeners(modal, isIMEIChange);
}

function setupModalEventListeners(modal, isIMEIChange) {
  const rebootButton = getElement(selectors.rebootButton);
  const cancelButton = modal.querySelector(selectors.cancelButton);
  const modalBackground = modal.querySelector(selectors.modalBackground);

  if (rebootButton) {
    rebootButton.onclick = async () => {
      handleRebootCountdown();
      if (isIMEIChange) {
        try {
          await sendATCommand("AT+QPOWD=1");
        } catch (error) {
          console.error("Error sending reboot command:", error);
        }
      }
    };
  }

  const closeModal = () => {
    modal.classList.remove("is-active");
    if (isIMEIChange) {
      resetIMEIInput();
    }
  };

  if (cancelButton) cancelButton.onclick = closeModal;
  if (modalBackground) modalBackground.onclick = closeModal;
}

// IMEI Settings Management
async function saveIMEISetting() {
  if (!haveIMEIChanged()) {
    alert(MESSAGES.NO_CHANGES);
    return;
  }

  if (!validateIMEI(updatedIMEI)) {
    alert(MESSAGES.INVALID_IMEI);
    return;
  }

  try {
    const atCommand = `AT+EGMR=1,7,"${updatedIMEI}"`;
    console.log("Sending AT command:", atCommand);

    const inputs = document.querySelectorAll("input, select");
    inputs.forEach((input) => (input.disabled = true));

    const response = await sendATCommand(atCommand);
    console.log("AT command response:", response);

    showRebootModal(true);
  } catch (error) {
    console.error("Error saving settings:", error);
    alert(MESSAGES.ERROR_SAVING);
    resetIMEIInput();

    const inputs = document.querySelectorAll("input, select");
    inputs.forEach((input) => (input.disabled = false));
  }
}

// Data Parsing Functions
function parseDeviceData(response, key) {
  const dataMap = {
    CGMI: (response) => response.split("\n")[1].trim(),
    CGMM: (response) => response.split("\n")[1].trim(),
    CGMR: (response) => response.split("\n")[1].trim(),
    CNUM: (response) =>
      response
        .split("\n")[1]
        .split(":")[1]
        .split(",")[1]
        .replace(/"/g, "")
        .trim(),
    CIMI: (response) => response.split("\n")[1].trim(),
    ICCID: (response) => response.split("\n")[1].split(":")[1].trim(),
    CGSN: (response) => response.split("\n")[1].trim(),
    LANIP: (response) =>
      response.split("\n")[1].split(":")[1].split(",")[3].trim(),
    WWAN: (response) => ({
      IPv4: response
        .split("\n")[1]
        .split(":")[1]
        .split(",")[4]
        .replace(/"/g, "")
        .trim(),
      IPv6: response.split("\n")[2].split(",")[4].replace(/"/g, "").trim(),
    }),
  };

  return dataMap[key]?.(response);
}

// Data Fetching and Display
// Data Parsing and Update Functions
function updateDeviceInfo(key, value) {
  const mapping = DATA_MAP[key];
  if (!mapping) return;

  if (mapping.elementIds) {
    // Handle WWAN case with multiple values
    mapping.elementIds.forEach((id) => {
      const element = document.getElementById(id);
      if (element) element.textContent = value[id];
    });
  } else {
    const element = document.getElementById(mapping.elementId);
    if (element) element.textContent = value;

    // Special handling for IMEI
    if (mapping.special) {
      currentIMEI = value;
      updatedIMEI = value;
      const imeiInput = getElement(selectors.imeiInput);
      if (imeiInput) {
        imeiInput.value = value;
        imeiInput.addEventListener("input", () => {
          updatedIMEI = imeiInput.value;
          console.log("Updated IMEI:", updatedIMEI);
        });
      }
    }
  }
}

// Data Fetching
async function fetchAboutData() {
  try {
    const response = await fetch("/cgi-bin/about/fetch-about.sh");
    if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);

    const data = await response.json();
    console.log("Full response:", data);

    data.forEach((item) => {
      Object.keys(DATA_MAP).forEach((key) => {
        if (item.response.includes(key)) {
          const value = DATA_MAP[key].parse(item.response);
          updateDeviceInfo(key, value);
        }
      });
    });
  } catch (error) {
    console.error("Error fetching about data:", error);
  }
}

// Initialize when DOM is loaded
document.addEventListener("DOMContentLoaded", () => {
  fetchAboutData();

  const changeButton = getElement(selectors.changeButton);
  if (changeButton) {
    changeButton.addEventListener("click", saveIMEISetting);
  }

  const powerButton = getElement(selectors.powerButton);
  if (powerButton) {
    powerButton.addEventListener("click", () => showRebootModal(false));
  }

  const alertButtons = document.querySelectorAll(selectors.alertButtons);
  alertButtons.forEach((button) => {
    button.addEventListener("click", fetchAboutData);
  });
});
