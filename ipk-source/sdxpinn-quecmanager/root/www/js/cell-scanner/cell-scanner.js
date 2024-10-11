class NeighbourCellScanner {
  constructor() {
    this.tableBody = document.getElementById("neighbourCellTableBody");
    this.tableHeaders = document.querySelector("#neighbourCellTable thead tr");
    this.lteScanBtn = document.getElementById("startLTEScanBtn");
    this.nr5gScanBtn = document.getElementById("startNR5GScanBtn");
    this.resetBtn = document.getElementById("resetScanBtn");

    this.bindEvents();
  }

  bindEvents() {
    this.lteScanBtn.addEventListener("click", () => this.startLTEScan());
    this.nr5gScanBtn.addEventListener("click", () => this.startNR5GScan());
    this.resetBtn.addEventListener("click", () => this.resetTable());
  }

  updateTableHeaders(mode) {
    if (mode === "LTE") {
      this.tableHeaders.innerHTML = `
          <th>Type</th>
          <th>EARFCN</th>
          <th>Physical ID</th>
          <th class="is-hidden-mobile">RSRP</th>
          <th class="is-hidden-mobile">RSRQ</th>
          <th class="is-hidden-mobile">RSSI</th>
        `;
    } else if (mode === "NR5G") {
      this.tableHeaders.innerHTML = `
          <th>Type</th>
          <th>ARFCN</th>
          <th>Physical ID</th>
          <th class="is-hidden-mobile">RSRP</th>
          <th class="is-hidden-mobile">RSSI</th>
          <th class="is-hidden-mobile">--</th>
        `;
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
      //   remove the initial table row
      this.tableBody.innerHTML = "";
      return await response.json();
    } catch (error) {
      console.error("API Error:", error);
      //   add the initial table row again
      this.addPlaceholderRow();
      throw error;
    }
  }

  getSignalQuality(value) {
    if (value > -90) return "is-success";
    if (value > -100) return "is-warning";
    return "is-danger";
  }

  getSignalText(value) {
    if (value > -90) return "Good";
    if (value > -100) return "Fair";
    return "Poor";
  }

  createSignalTag(value) {
    const quality = this.getSignalQuality(value);
    const text = this.getSignalText(value);
    return `
        <div class="tags has-addons">
          <span class="tag is-size-6">${value}</span>
          <span class="tag ${quality} is-size-6 has-text-white">${text}</span>
        </div>
      `;
  }

  parseLTEResponse(response) {
    const output = response.output;
    const lines = output.split("\n");
    const results = [];

    for (const line of lines) {
      if (line.startsWith("+QENG:")) {
        const match = line.match(
          /"([^"]+)","LTE",(\d+),(\d+),(-?\d+),(-?\d+),(-?\d+)/
        );
        if (match) {
          // Extract just 'intra' or 'inter' from the type
          const fullType = match[1];
          const type = fullType.includes("intra") ? "intra" : "inter";

          results.push({
            type: type,
            earfcn: match[2],
            pci: match[3],
            rsrq: parseInt(match[4]),
            rsrp: parseInt(match[5]),
            rssi: parseInt(match[6]),
          });
        }
      }
    }
    return results;
  }

  parseNR5GResponse(response) {
    const output = response.output;
    const lines = output.split("\n");
    const results = [];

    for (const line of lines) {
      if (line.startsWith("+QNWCFG:")) {
        const match = line.match(/\d+,(\d+),(\d+),(-?\d+),(-?\d+)/);
        if (match) {
          results.push({
            arfcn: match[1],
            pci: match[2],
            rsrp: parseInt(match[3]),
            rssi: parseInt(match[4]),
          });
        }
      }
    }
    return results;
  }

  addPlaceholderRow() {
    const row = document.createElement("tr");
    row.innerHTML = `
          <td>--</td>
          <td>--</td>
          <td>--</td>
          <td class="is-hidden-mobile">
            <div class="tags has-addons">
              <span class="tag is-size-6">--</span>
              <span class="tag is-light is-size-6">No Data</span>
            </div>
          </td>
          <td class="is-hidden-mobile">
            <div class="tags has-addons">
              <span class="tag is-size-6">--</span>
              <span class="tag is-light is-size-6">No Data</span>
            </div>
          </td>
          <td class="is-hidden-mobile">
            <div class="tags has-addons">
              <span class="tag is-size-6">--</span>
              <span class="tag is-light is-size-6">No Data</span>
            </div>
          </td>
        `;
    this.tableBody.appendChild(row);
  }

  async startLTEScan() {
    try {
      const response = await this.sendCommand('AT+QENG="neighbourcell"');
      const results = this.parseLTEResponse(response);

      // Clear the table and update headers first
      this.tableBody.innerHTML = "";
      this.updateTableHeaders("LTE");

      if (results.length === 0) {
        this.addPlaceholderRow();
      } else {
        results.forEach((result) => {
          const row = document.createElement("tr");
          row.innerHTML = `
            <td>${result.type}</td>
            <td>${result.earfcn}</td>
            <td>${result.pci}</td>
            <td class="is-hidden-mobile">${this.createSignalTag(
              result.rsrp
            )}</td>
            <td class="is-hidden-mobile">${this.createSignalTag(
              result.rsrq
            )}</td>
            <td class="is-hidden-mobile">${this.createSignalTag(
              result.rssi
            )}</td>
          `;
          this.tableBody.appendChild(row);
        });
      }
    } catch (error) {
      console.error("LTE Scan failed:", error);
      this.resetTable();
    }
  }

  async startNR5GScan() {
    try {
      const response = await this.sendCommand(
        'AT+QNWCFG="nr5g_meas_info",1;+QNWCFG="nr5g_meas_info"'
      );
      const results = this.parseNR5GResponse(response);

      // Clear the table and update headers first
      this.tableBody.innerHTML = "";
      this.updateTableHeaders("NR5G");

      if (results.length === 0) {
        this.addPlaceholderRow();
      } else {
        results.forEach((result) => {
          const row = document.createElement("tr");
          row.innerHTML = `
            <td>NR5G</td>
            <td>${result.arfcn}</td>
            <td>${result.pci}</td>
            <td class="is-hidden-mobile">${this.createSignalTag(
              result.rsrp
            )}</td>
            <td class="is-hidden-mobile">${this.createSignalTag(
              result.rssi
            )}</td>
            <td class="is-hidden-mobile">--</td>
          `;
          this.tableBody.appendChild(row);
        });
      }
    } catch (error) {
      console.error("NR5G Scan failed:", error);
      this.resetTable();
    }
  }

  resetTable() {
    this.tableBody.innerHTML = "";
    this.updateTableHeaders("LTE"); // Reset to default LTE headers
    this.addPlaceholderRow(); // Add placeholder row after reset
  }
}

// Initialize the scanner when the document is ready
document.addEventListener("DOMContentLoaded", () => {
  const scanner = new NeighbourCellScanner();
  scanner.resetTable(); // Show initial placeholder row
});
