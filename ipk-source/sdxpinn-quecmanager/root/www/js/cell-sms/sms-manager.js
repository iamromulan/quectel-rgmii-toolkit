class SMSManager {
  constructor() {
    this.initializeElements();
    this.bindEvents();
    this.init();
  }

  initializeElements() {
    this.smsContainer = document.getElementById("sms-container");
    this.refreshButton = document.getElementById("refresh-sms");
    this.deleteSelectedButton = document.getElementById("delete-selected-sms");
    this.phoneNumberInput = document.getElementById("phone-number-input");
    this.messageTextarea = document.getElementById("message-input");
    this.sendSMSButton = document.getElementById("send-sms");
    this.resetButton = document.getElementById("reset-form");

    const elements = {
      "SMS Container": this.smsContainer,
      "Refresh Button": this.refreshButton,
      "Delete Selected Button": this.deleteSelectedButton,
      "Phone Number Input": this.phoneNumberInput,
      "Message Textarea": this.messageTextarea,
      "Send SMS Button": this.sendSMSButton,
      "Reset Button": this.resetButton,
    };

    for (const [name, element] of Object.entries(elements)) {
      if (!element) {
        console.error(`${name} element not found!`);
      }
    }
  }

  bindEvents() {
    if (this.refreshButton) {
      this.refreshButton.addEventListener("click", (e) => {
        e.preventDefault();
        this.refreshSMS();
      });
    }

    if (this.deleteSelectedButton) {
      this.deleteSelectedButton.addEventListener("click", (e) => {
        e.preventDefault();
        this.deleteSelectedSMS();
      });
    }

    if (this.sendSMSButton) {
      this.sendSMSButton.addEventListener("click", (e) => {
        e.preventDefault();
        this.sendSMS();
      });
    }

    if (this.resetButton) {
      this.resetButton.addEventListener("click", (e) => {
        e.preventDefault();
        this.resetForm();
      });
    }
  }

  async sendCommand(command) {
    try {
      const response = await fetch("/cgi-bin/atinout_handler.sh", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: `command=${encodeURIComponent(command)}`,
      });
      return await response.json();
    } catch (error) {
      console.error("AT command failed:", error);
      throw error;
    }
  }

  async init() {
    try {
      await this.sendCommand("AT+CMGF=1");
      await this.refreshSMS();
    } catch (error) {
      console.error("Initialization failed:", error);
    }
  }

  showLoadingState() {
    this.smsContainer.innerHTML = `
      <div class="loading-container">
        <span class="icon is-large">
          <i class="fas fa-spinner fa-pulse fa-2x"></i>
        </span>
        <p class="mt-2">Fetching SMS...</p>
      </div>
    `;
  }

  async refreshSMS() {
    this.showLoadingState();
    try {
      const response = await this.sendCommand('AT+CMGL="ALL"');

      let rawData;
      if (typeof response === "string") {
        rawData = response;
      } else if (response && response.result) {
        rawData = response.result;
      } else if (response && response.output) {
        rawData = response.output;
      }

      if (!rawData) {
        console.error("No valid data received from AT command");
        this.displayMessages([]);
        return;
      }

      const messages = this.parseSMSData(rawData);
      this.displayMessages(messages);
    } catch (error) {
      console.error("Failed to refresh SMS:", error);
      this.displayMessages([]);
    }
  }

  parseSMSData(data) {
    const messages = [];
    const lines = data.split("\n");
    let currentMessage = null;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line || line === "OK" || line === 'AT+CMGL="ALL"') continue;

      if (line.startsWith("+CMGL:")) {
        if (currentMessage && currentMessage.message) {
          messages.push(currentMessage);
        }

        const headerMatch = line.match(
          /\+CMGL:\s*(\d+),"([^"]*?)","([^"]*?)",,"([^"]*?)"/
        );
        if (headerMatch) {
          currentMessage = {
            index: headerMatch[1],
            status: headerMatch[2],
            sender: headerMatch[3],
            date: headerMatch[4].replace("+32", ""),
            message: "",
          };
        }
      } else if (currentMessage) {
        currentMessage.message += (currentMessage.message ? "\n" : "") + line;
      }
    }

    if (currentMessage && currentMessage.message) {
      messages.push(currentMessage);
    }

    return messages;
  }

  createMessageElement(message, index) {
    const formattedDate = message.date.replace(
      /(\d{2})\/(\d{2})\/(\d{2}),(\d{2}:\d{2}:\d{2})/,
      "20$3-$2-$1 $4"
    );

    return `
      <div class="cell" id="sms-message-${index}">
        <div class="is-flex is-align-items-center">
          <div class="checkbox mr-6">
            <input type="checkbox" 
                   id="sms-checkbox-${index}" 
                   data-index="${message.index}" />
          </div>
          <div class="is-flex is-flex-direction-column is-align-items-start">
            <p class="has-text-weight-semibold" id="sms-sender-${index}">${message.sender}</p>
            <p id="sms-date-${index}">${formattedDate}</p>
            <p id="sms-content-${index}">${message.message}</p>
          </div>
        </div>
      </div>
    `;
  }

  displayMessages(messages) {
    if (!this.smsContainer) {
      console.error("SMS container not found!");
      return;
    }

    this.smsContainer.innerHTML =
      messages.length === 0
        ? '<div class="cell" id="no-messages">No messages found</div>'
        : messages
            .map((msg, index) => this.createMessageElement(msg, index))
            .join("");
  }

  async deleteSelectedSMS() {
    const selectedCheckboxes = document.querySelectorAll(
      'input[type="checkbox"]:checked'
    );
    const indices = Array.from(selectedCheckboxes).map(
      (cb) => cb.dataset.index
    );

    if (indices.length === 0) return;

    try {
      for (const index of indices) {
        await this.sendCommand(`AT+CMGD=${index}`);
      }
      await this.refreshSMS();
    } catch (error) {
      console.error("Failed to delete messages:", error);
    }
  }

  async sendSMS() {
    const phoneNumber = this.phoneNumberInput.value.trim();
    const message = this.messageTextarea.value.trim();

    if (!phoneNumber || !message) {
      alert("Please enter both phone number and message");
      return;
    }

    try {
      await this.sendCommand(`AT+CMGS="${phoneNumber}"`);
      await this.sendCommand(`${message}\x1A`);
      this.resetForm();
      await this.refreshSMS();
    } catch (error) {
      console.error("Failed to send SMS:", error);
    }
  }

  resetForm() {
    if (this.phoneNumberInput) this.phoneNumberInput.value = "";
    if (this.messageTextarea) this.messageTextarea.value = "";
  }
}

document.addEventListener("DOMContentLoaded", () => {
  window.smsManager = new SMSManager();
});