// api.js - API related functions
const api = {
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
      console.error("API Error:", error);
      throw error;
    }
  }
};

// bandManager.js - Band management functionality
const bandManager = {
  async fetchCurrentBands() {
    try {
      const data = await api.sendCommand("AT+QCAINFO");
      const lteBands = data.output.match(/LTE BAND ([0-9]+)/g) || [];
      const nrBands = data.output.match(/NR5G BAND ([0-9]+)/g) || [];
      
      const currentBandsElement = document.getElementById("currentBands");
      if (!currentBandsElement) return;

      if (lteBands.length === 0 && nrBands.length === 0) {
        currentBandsElement.textContent = "No active bands found";
      } else if (lteBands.length === 0) {
        currentBandsElement.textContent = nrBands.join(", ");
      } else if (nrBands.length === 0) {
        currentBandsElement.textContent = lteBands.join(", ");
      } else {
        currentBandsElement.textContent = [...lteBands, ...nrBands].join(", ");
      }
    } catch (error) {
      console.error("Error fetching current bands:", error);
    }
  },

  async fetchSupportedBands() {
    try {
      const data = await api.sendCommand('AT+QNWPREFCFG="policy_band"');
      
      const matches = {
        lte: data.output.match(/"lte_band",([0-9:]+)/),
        nsa: data.output.match(/"nsa_nr5g_band",([0-9:]+)/),
        saDc: data.output.match(/"nrdc_nr5g_band",([0-9:]+)/)
      };

      if (matches.lte) this.populateBands(matches.lte[1], "#lte_bands");
      if (matches.nsa) this.populateBands(matches.nsa[1], "#nsa_bands");
      if (matches.saDc) this.populateBands(matches.saDc[1], "#sanrdc_bands");

      await this.fetchActiveBands();
    } catch (error) {
      console.error("Error fetching supported bands:", error);
    }
  },

  async fetchActiveBands() {
    try {
      const command = 'AT+QNWPREFCFG="lte_band";+QNWPREFCFG="nsa_nr5g_band";+QNWPREFCFG="nr5g_band";+QNWPREFCFG="nrdc_nr5g_band"';
      const data = await api.sendCommand(command);

      const output = data.output.split("\n").slice(1).join("\n").replace("OK", "");

      const matches = {
        lte: output.match(/"lte_band",([0-9:]+)/),
        nsa: output.match(/"nsa_nr5g_band",([0-9:]+)/),
        saDc: output.split("\n")[6]?.match(/"nr5g_band",([0-9:]+)/)
      };

      if (matches.lte) this.markActiveBands(matches.lte[1].split(":"), "#lte_bands");
      if (matches.nsa) this.markActiveBands(matches.nsa[1].split(":"), "#nsa_bands");
      if (matches.saDc) this.markActiveBands(matches.saDc[1].split(":"), "#sanrdc_bands");

      await this.fetchCurrentBands();
    } catch (error) {
      console.error("Error fetching active bands:", error);
    }
  },

  populateBands(bandsString, targetId) {
    const container = document.querySelector(targetId);
    if (!container) return;

    const html = bandsString.split(":").map(band => `
      <div class="cell">
        <label class="checkbox">
          <input type="checkbox" value="${band}" /> B${band}
        </label>
      </div>
    `).join("");

    container.innerHTML = html;
  },

  markActiveBands(activeBands, targetId) {
    document.querySelectorAll(`${targetId} input[type="checkbox"]`).forEach(checkbox => {
      if (activeBands.includes(checkbox.value)) {
        checkbox.setAttribute("checked", "checked");
      }
    });
  },

  uncheckAll(targetId) {
    document.querySelectorAll(`${targetId} input[type="checkbox"]`).forEach(checkbox => {
      checkbox.removeAttribute("checked");
      checkbox.checked = false;
    });
  },

  async lockBands(targetId, commandType) {
    const checkboxes = document.querySelectorAll(`${targetId} input[type="checkbox"]:checked`);
    const checkedBands = Array.from(checkboxes)
      .map(cb => cb.value)
      .sort((a, b) => a - b);

    if (checkedBands.length === 0) {
      alert("Please select at least one band to lock.");
      return;
    }

    try {
      const command = `AT+QNWPREFCFG="${commandType}",${checkedBands.join(":")}`;
      await api.sendCommand(command);
      alert(`Successfully locked ${commandType.split("_")[0].toUpperCase()} bands`);
      await this.fetchActiveBands();
    } catch (error) {
      alert(`Failed to lock bands: ${error.message}`);
    }
  },

  async resetBands(targetId, bandType) {
    const checkboxes = document.querySelectorAll(`${targetId} input[type="checkbox"]`);
    const selectedBands = [];

    checkboxes.forEach(checkbox => {
      checkbox.setAttribute("checked", "checked");
      checkbox.checked = true;
      selectedBands.push(checkbox.value);
    });

    try {
      const command = `AT+QNWPREFCFG="${bandType}",${selectedBands.join(":")}`;
      await api.sendCommand(command);
      await this.fetchActiveBands();
    } catch (error) {
      console.error(`Error resetting ${bandType}:`, error);
    }
  }
};

// eventHandlers.js - Event handling setup
function setupEventListeners() {
  const handlers = {
    uncheck: {
      "uncheckLte": "#lte_bands",
      "uncheckNsa": "#nsa_bands",
      "uncheckSaDc": "#sanrdc_bands"
    },
    lock: {
      "lockLte": ["#lte_bands", "lte_band"],
      "lockNsa": ["#nsa_bands", "nsa_nr5g_band"],
      "lockSaDc": ["#sanrdc_bands", "nrdc_nr5g_band"]
    },
    reset: {
      "resetLte": ["#lte_bands", "lte_band"],
      "resetNsa": ["#nsa_bands", "nsa_nr5g_band"],
      "resetSaDc": ["#sanrdc_bands", "nrdc_nr5g_band"]
    }
  };

  // Setup uncheck handlers
  Object.entries(handlers.uncheck).forEach(([id, targetId]) => {
    const element = document.getElementById(id);
    if (element) {
      element.addEventListener("click", (e) => {
        e.preventDefault();
        bandManager.uncheckAll(targetId);
      });
    }
  });

  // Setup lock handlers
  Object.entries(handlers.lock).forEach(([id, [targetId, commandType]]) => {
    const element = document.getElementById(id);
    if (element) {
      element.addEventListener("click", () => bandManager.lockBands(targetId, commandType));
    }
  });

  // Setup reset handlers
  Object.entries(handlers.reset).forEach(([id, [targetId, bandType]]) => {
    const element = document.getElementById(id);
    if (element) {
      element.addEventListener("click", (e) => {
        e.preventDefault();
        bandManager.resetBands(targetId, bandType);
      });
    }
  });
}

// main.js - Application initialization
document.addEventListener("DOMContentLoaded", () => {
  setupEventListeners();
  bandManager.fetchSupportedBands();
});