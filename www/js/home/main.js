// Constants
const ACCESS_TECH_MAP = {
  2: "UTRAN",
  4: "UTRAN W/ HSDPA",
  5: "UTRAN W/ HSUPA",
  6: "UTRAN W/ HSDPA & HSUPA",
  7: "E-UTRAN",
  10: "E-UTRAN connected to a 5GCN",
  11: "NR connected to a 5GCN",
  12: "NG-RAN",
  13: "E-UTRAN-NR dual",
};

const OPERATOR_STATE_MAP = {
  0: { label: "Not Registered", class: "is-danger" },
  1: { label: "Registered", class: "is-success" },
  2: { label: "Searching", class: "is-warning" },
  3: { label: "Denied", class: "is-danger" },
  4: { label: "Unknown", class: "is-warning" },
  5: { label: "Roaming", class: "is-success" },
};

const BANDWIDTH_MAP = {
  6: "1.4 MHz",
  15: "3 MHz",
  25: "5 MHz",
  50: "10 MHz",
  75: "15 MHz",
  100: "20 MHz",
};

const NR_BANDWIDTH_MAP = {
  0: "5 MHz",
  1: "10 MHz",
  2: "15 MHz",
  3: "20 MHz",
  4: "25 MHz",
  5: "30 MHz",
  6: "40 MHz",
  7: "50 MHz",
  8: "60 MHz",
  9: "70 MHz",
  10: "80 MHz",
  11: "90 MHz",
  12: "100 MHz",
  13: "200 MHz",
  14: "400 MHz",
  15: "35 MHz",
  16: "45 MHz",
};

// Global variables for intervals
let atCommandInterval;
let connectionStatusInterval;
let trafficStatsInterval;
const DEFAULT_REFRESH_RATE = 5000; // 5 seconds
const TRAFFIC_STATS_REFRESH_RATE = 1000; // 1 second
const CONNECTION_CHECK_MULTIPLIER = 6; // Will make connection check 6 times slower
const STORAGE_KEY = "modemRefreshRate";

// Utility functions
function setText(id, text) {
  const element = document.getElementById(id);
  if (element) {
    element.textContent = text;
  }
}

// Helper function to format bytes to human-readable format
function formatBytes(bytes, decimals = 2) {
  if (bytes === 0) return "0 Bytes";

  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ["Bytes", "KB", "MB", "GB", "TB"];

  const i = Math.floor(Math.log(bytes) / Math.log(k));

  return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + " " + sizes[i];
}

function createTag(classes, text) {
  const tag = document.createElement("span");
  tag.classList.add(...classes);
  tag.textContent = text;
  return tag;
}

// Refresh control functions
function handleRefreshClick() {
  const refreshButton = document.getElementById("handleRefreshClickButton");
  if (refreshButton) {
    refreshButton.disabled = true;
    const icon = refreshButton.querySelector("i");
    if (icon) {
      icon.classList.add("fa-spin");
    }
  }

  Promise.all([fetchATCommandData(), fetchConnectionStatus(), fetchTrafficStats]).finally(() => {
    if (refreshButton) {
      refreshButton.disabled = false;
      const icon = refreshButton.querySelector("i");
      if (icon) {
        icon.classList.remove("fa-spin");
      }
    }
  });
}

// Modified and new functions for refresh rate control with persistence
function setupRefreshControls() {
  const dropdownItems = document.querySelectorAll(
    ".dropdown-content .dropdown-item"
  );
  const dropdownButton = document.querySelector(
    ".dropdown-trigger button span"
  );

  // Get stored refresh rate or use default
  const storedRate = localStorage.getItem(STORAGE_KEY);
  const initialRate = storedRate ? parseInt(storedRate) : DEFAULT_REFRESH_RATE;

  dropdownItems.forEach((item) => {
    item.addEventListener("click", (e) => {
      e.preventDefault();
      const seconds = parseInt(e.target.textContent.trim().replace("s", ""));
      updateRefreshRate(seconds);

      // Update active state in dropdown
      dropdownItems.forEach((di) => di.classList.remove("is-active"));
      e.target.classList.add("is-active");

      // Update dropdown button text
      if (dropdownButton) {
        dropdownButton.textContent = `${seconds}s`;
      }

      // Store the selected rate
      localStorage.setItem(STORAGE_KEY, seconds * 1000);
    });
  });

  // Set initial active state and start refresh
  setInitialState(dropdownItems, dropdownButton, initialRate);
  startPeriodicRefresh(initialRate);
}

function setInitialState(dropdownItems, dropdownButton, initialRate) {
  const seconds = initialRate / 1000;

  // Update dropdown button text
  if (dropdownButton) {
    dropdownButton.textContent = `${seconds}s`;
  }

  // Set active state in dropdown
  const activeItem = Array.from(dropdownItems).find(
    (item) => parseInt(item.textContent.trim().replace("s", "")) === seconds
  );
  if (activeItem) {
    dropdownItems.forEach((di) => di.classList.remove("is-active"));
    activeItem.classList.add("is-active");
  }
}

function updateRefreshRate(seconds) {
  const newRate = seconds * 1000; // Convert to milliseconds

  // Clear existing intervals
  clearInterval(atCommandInterval);
  clearInterval(connectionStatusInterval);
  clearInterval(trafficStatsInterval);

  // Start new intervals
  startPeriodicRefresh(newRate);
}

function startPeriodicRefresh(refreshRate = DEFAULT_REFRESH_RATE) {
  // Clear any existing intervals
  clearInterval(atCommandInterval);
  clearInterval(connectionStatusInterval);
  clearInterval(trafficStatsInterval);

  // Start new intervals
  atCommandInterval = setInterval(fetchATCommandData, refreshRate);
  trafficStatsInterval = setInterval(fetchTrafficStats, TRAFFIC_STATS_REFRESH_RATE);
  connectionStatusInterval = setInterval(
    fetchConnectionStatus,
    refreshRate * CONNECTION_CHECK_MULTIPLIER
  );
}

// AT Commands functions
async function fetchATCommandData() {
  try {
    const jsonData = await fetchAndParseData();
    processATCommandData(jsonData);
    console.log("Data fetched and processed successfully");
    console.log(jsonData);
  } catch (error) {
    console.error("There was a problem with the fetch operation:", error);
  }
}

async function fetchAndParseData() {
  const response = await fetch("/cgi-bin/home_data.sh", {
    method: "GET",
    headers: {
      "Content-Type": "application/json",
    },
  });

  const rawData = await response.text();

  if (!rawData || rawData.trim() === "") {
    throw new Error("Empty or malformed response");
  }

  return JSON.parse(rawData);
}

function processATCommandData(jsonData) {
  processSimData(jsonData);
  processNetworkData(jsonData);
  processModemData(jsonData);
  processBandwidthData(jsonData);
  processConnectedBands(jsonData);
  processSignalStrength(jsonData);
  processBandsTable(jsonData);
  processCellInfo(jsonData);
  processWANIPData(jsonData);
}

function processSimData(jsonData) {
  const [simSlotResponse, phoneResponse, providerResponse] = jsonData;

  // SIM Slot
  const simSlot = extractValue(simSlotResponse.response);
  setText("simSlot", simSlot);

  // Phone Number
  const phoneNumber = extractValue(phoneResponse.response).replace(
    /["\,]/g,
    ""
  );
  setText("phoneNumber", phoneNumber);

  // SIM Provider and Access Technology
  const providerData = extractValue(providerResponse.response).split(",");
  const simProvider = providerData[2].replace(/"/g, "").trim();
  const accessTech = providerData[3].replace(/"/g, "").trim();

  setText("simProvider", simProvider);
  setText("accessTech", ACCESS_TECH_MAP[accessTech] || "Unknown");

  // Additional SIM data
  setText("imsi", jsonData[3].response.split("\n")[1].trim());
  setText("iccid", extractValue(jsonData[4].response));
  setText("imei", jsonData[5].response.split("\n")[1].trim());
}

function processNetworkData(jsonData) {
  // SIM State
  const simState = extractValue(jsonData[6].response);
  const simStateElement = createTag(
    simState === "READY"
      ? ["tag", "is-success", "has-text-white"]
      : ["tag", "is-danger", "has-text-white"],
    simState === "READY" ? "Inserted" : "Missing!"
  );
  const simStateContainer = document.getElementById("simState");
  if (simStateContainer) {
    simStateContainer.innerHTML = "";
    simStateContainer.appendChild(simStateElement);
  }

  // APN
  const apnData = extractValue(jsonData[7].response).split(",");
  setText("apn", apnData[2].replace(/"/g, "").trim());

  // Operator State
  const operatorState = extractValue(jsonData[8].response).split(",")[1].trim();
  const { label, class: className } = OPERATOR_STATE_MAP[operatorState] || {
    label: "Unknown",
    class: "is-warning",
  };
  const operatorStateElement = createTag(
    ["tag", className, "has-text-white"],
    label
  );
  const operatorStateContainer = document.getElementById("operatorState");
  if (operatorStateContainer) {
    operatorStateContainer.innerHTML = "";
    operatorStateContainer.appendChild(operatorStateElement);
  }
}

function processModemData(jsonData) {
  // Functionality State
  const functionalityState = extractValue(jsonData[9].response);
  const functionalityStateElement = createTag(
    functionalityState === "1"
      ? ["tag", "is-success", "has-text-white"]
      : ["tag", "is-danger", "has-text-white"],
    functionalityState === "1" ? "Enabled" : "Disabled"
  );
  const functionalityStateContainer =
    document.getElementById("functionalityState");
  if (functionalityStateContainer) {
    functionalityStateContainer.innerHTML = "";
    functionalityStateContainer.appendChild(functionalityStateElement);
  }

  // Network Type
  const servingCell = jsonData[10].response;
  let networkType = determineNetworkType(servingCell);
  setText("networkType", networkType);

  // Modem Temperature
  processTemperature(jsonData[11].response);
}

function processBandwidthData(jsonData) {
  // Carrier Aggregation
  const caState = jsonData[13].response.includes("SCC") ? "Multi" : "Inactive";
  const caStateElement = createTag(
    caState === "Multi"
      ? ["tag", "is-success", "has-text-white"]
      : ["tag", "is-danger", "has-text-white"],
    caState
  );
  const caStateContainer = document.getElementById("caState");
  if (caStateContainer) {
    caStateContainer.innerHTML = "";
    caStateContainer.appendChild(caStateElement);
  }

  // Process bandwidth information
  const networkTypeElement = document.getElementById("networkType");
  if (networkTypeElement) {
    const networkType = networkTypeElement.textContent;
    if (networkType === "LTE" || networkType === "NR5G-NSA") {
      processBandwidth(jsonData[13].response, networkType);
    }
  }
}

// Helper functions
function extractValue(response) {
  return response.split("\n")[1].split(":")[1].trim();
}

function determineNetworkType(servingCell) {
  if (servingCell.includes("LTE")) {
    return servingCell.includes("NR5G-NSA") ? "NR5G-NSA" : "LTE";
  } else if (servingCell.includes("NR5G-SA")) {
    return "NR5G-SA";
  }
  return "Unknown / No Signal";
}

function processTemperature(tempResponse) {
  const temps = ["cpuss-0", "cpuss-1", "cpuss-2", "cpuss-3"].map((cpu) => {
    const line = tempResponse.split("\n").find((l) => l.includes(cpu));
    return parseInt(line.split(":")[1].split(",")[1].replace(/"/g, "").trim());
  });
  const avgTemp = temps.reduce((acc, t) => acc + t, 0) / temps.length;
  setText("temp", `${avgTemp} °C`);
}

function processBandwidth(response, networkType) {
  const sccLines = extractSCCData(response);
  const pccLine = response.split("\n").find((line) => line.includes("PCC"));
  const pccBW = pccLine.split(":")[1].split(",")[2].trim();
  const pccBWParsed = BANDWIDTH_MAP[pccBW] || "Unknown";

  if (networkType === "NR5G-NSA") {
    processNR5GBandwidth(sccLines, pccBWParsed);
  } else {
    processLTEBandwidth(sccLines, pccBWParsed);
  }
}

function extractSCCData(response) {
  return response
    .split("\n")
    .filter((line) => line.includes("SCC"))
    .map((line) => line.trim());
}

function processNR5GBandwidth(sccLines, pccBWParsed) {
  const nrBW = sccLines[sccLines.length - 1].split(":")[1].split(",")[2].trim();
  const nrBWParsed = NR_BANDWIDTH_MAP[nrBW] || "Unknown";

  const lteBW = sccLines.slice(0, sccLines.length - 1).map((line) => {
    const bw = line.split(":")[1].split(",")[2].trim();
    return BANDWIDTH_MAP[bw] || "Unknown";
  });

  if (lteBW.length === 0) {
    setText("allBW", `${pccBWParsed} + NR${nrBWParsed}`);
    return;
  }
  setText("allBW", `${pccBWParsed} + ${lteBW.join(" + ")} + NR${nrBWParsed}`);
}

function processLTEBandwidth(sccLines, pccBWParsed) {
  const allBW = sccLines.map((line) => {
    const bw = line.split(":")[1].split(",")[2].trim();
    return BANDWIDTH_MAP[bw] || "Unknown";
  });

  setText(
    "allBW",
    allBW.length === 0 ? pccBWParsed : `${pccBWParsed} + ${allBW.join(" + ")}`
  );
}

function processConnectedBands(jsonData) {
  let bandLines = [];
  // Get lines that contains either PCC or SCC and append to bandLines
  let pccBand = jsonData[13].response
    .split("\n")
    .find((line) => line.includes("PCC"))
    .split(":")[1]
    .split(",")[3]
    .replace(/"/g, "")
    .trim();

  // Loop through each line in the jsonData[13] response and get the lines with SCC and append it to bandLines
  jsonData[13].response.split("\n").forEach((line) => {
    if (line.includes("SCC")) {
      line = line.split(":")[1].split(",")[3].replace(/"/g, "");
      bandLines.push(line);
    }
  });

  // Parse the LTE band numbers from this: LTE BAND 1 to this B1
  bandLines = bandLines.map((band) => {
    return band.replace("LTE BAND ", "B").trim();
  });

  bandLines = bandLines.map((band) => {
    return band.replace("NR5G BAND ", "N").trim();
  });

  pccBand = pccBand.replace("LTE BAND ", "B").trim();
  pccBand = pccBand.replace("NR5G BAND ", "N").trim();

  // allBands
  if (bandLines.length === 0) {
    setText("allBands", pccBand);
    return;
  } else {
    setText("allBands", `${pccBand} + ${bandLines.join(" / ")}`);
  }
}

function processSignalStrength(jsonData) {
  const signalStrength = jsonData[14].response
    .split("\n")[1]
    .split(":")[1]
    .trim();
  // Signal Strength value
  let signalStrengthData = [];
  // Get the values separated by commas
  signalStrengthData = signalStrength.split(",");

  // Remove indexes that contains "LTE", "NR5G", "-140", or "-32768"
  signalStrengthData = signalStrengthData.filter((value) => {
    return (
      !value.includes("LTE") &&
      !value.includes("NR5G") &&
      !value.includes("-140") &&
      !value.includes("-32768")
    );
  });

  // Get the average of the signal strength values where -65 is 100% and -140 is 0%
  let signalStrengthAverage = 0;
  signalStrengthData.forEach((value) => {
    signalStrengthAverage += parseInt(value);
  });

  signalStrengthAverage = signalStrengthAverage / signalStrengthData.length;

  // Calculate the percentage
  let percentage = 0;
  if (signalStrengthAverage >= -65) {
    percentage = 100;
  } else if (signalStrengthAverage <= -140) {
    percentage = 0;
    assessment = "No Signal";
  } else {
    percentage = 100 - (signalStrengthAverage - -65) * (100 / (-140 - -65));
  }

  // Set the signal strength value in a span element where 0-40% is danger, 40-70% is warning, and 70-100% is success
  const signalStrengthElement = document.getElementById("signalStrength");
  const signalAssessmentElement = document.getElementById("signalAssessment");
  if (signalStrengthElement && signalAssessmentElement) {
    signalStrengthElement.innerHTML = "";
    signalAssessmentElement.innerHTML = "";
    const signalStrengthTag = document.createElement("span");
    signalStrengthTag.classList.add("tag", "has-text-white");

    const signalAssessmentTag = document.createElement("span");
    signalAssessmentTag.classList.add("tag", "has-text-white");

    if (percentage >= 80) {
      signalStrengthTag.classList.add("is-success");
      signalAssessmentTag.classList.add("is-success");
      assessment = "Excellent";
    } else if (percentage >= 50) {
      signalStrengthTag.classList.add("is-warning");
      signalAssessmentTag.classList.add("is-warning");
      assessment = "Fair";
    } else {
      signalStrengthTag.classList.add("is-danger");
      signalAssessmentTag.classList.add("is-danger");
      assessment = "Cell Edge";
    }
    signalStrengthTag.textContent = `${percentage.toFixed(2)}%`;
    signalAssessmentTag.textContent = assessment;

    signalStrengthElement.appendChild(signalStrengthTag);
    signalAssessmentElement.appendChild(signalAssessmentTag);
  }

  // Count the number of of remaining indexes and set as the number of MIMO layers
  setText("mimoLayers", signalStrengthData.length);
}

function createBandTableRow(bandData, networkType, servingCellJSON) {
  const row = document.createElement("tr");

  try {
    // Parse band data
    const [type, ...values] = bandData.split(",");
    const bandType = type.includes("PCC") ? "PCC" : "SCC";

    let earfcn, bandwidth, bandNumber, pci, rsrp, rsrq, sinr;

    // Different parsing logic based on network type and band type
    if (networkType === "NR5G-SA") {
      if (bandType === "PCC") {
        [earfcn, bandwidth, bandNumber, pci, rsrp, rsrq, sinr] = values;
        // Parse the bandwidth using NR_BANDWIDTH_MAP
        bandwidth = bandwidth?.trim();
        bandwidth = NR_BANDWIDTH_MAP[bandwidth] || "Unknown";
      } else {
        // SCC
        [earfcn, bandwidth, bandNumber, scell, pci, rsrp, rsrq, sinr] = values;
        // Parse the bandwidth using NR_BANDWIDTH_MAP
        bandwidth = bandwidth?.trim();
        bandwidth = NR_BANDWIDTH_MAP[bandwidth] || "Unknown";
      }
    } else {
      // NSA
      if (bandType === "PCC") {
        [earfcn, bandwidth, bandNumber, scell, pci, rsrp, rssi, rsrq, sinr] =
          values;
        bandwidth = bandwidth?.trim();
        // Convert bandwidth to MHz
        bandwidth = BANDWIDTH_MAP[bandwidth] || "Unknown";
      } else {
        // SCC
        // If band type is SCC with LTE BAND, use this parsing logic
        if (bandData.includes("LTE BAND")) {
          [earfcn, bandwidth, bandNumber, scell, pci, rsrp, rssi, rsrq, sinr] =
            values;
          bandwidth = bandwidth?.trim();
          // Convert bandwidth to MHz
          bandwidth = BANDWIDTH_MAP[bandwidth] || "Unknown";
        } else {
          // If band type is SCC with NR5G BAND, use this parsing logic
          [earfcn, bandwidth, bandNumber, pci] = values;
          // Parse the bandwidth using NR_BANDWIDTH_MAP
          bandwidth = bandwidth?.trim();
          bandwidth = NR_BANDWIDTH_MAP[bandwidth] || "Unknown";
          // Get the rsrp, rsrq, and sinr values using the serving cell values
          // "NR5G-NSA",<MCC>,<MNC>,<PCID>,<RSRP>,<SINR>,<RSRQ>,<ARFCN>,<band>,<NR_DL_bandwidth>,<scs></scs>
          const getNR5GNSALine = servingCellJSON.find((line) =>
            line.includes("NR5G-NSA")
          );
          if (getNR5GNSALine) {
            const servingCellValues = getNR5GNSALine.split(":")[1].split(",");
            rsrp = servingCellValues[4].trim();
            sinr = servingCellValues[5].trim();
            rsrq = servingCellValues[6].trim();
          }
        }
      }
    }

    // Clean up values
    bandNumber = bandNumber?.replace(/"/g, "").trim();
    pci = pci?.trim();
    rsrp = rsrp?.trim();
    rsrq = rsrq?.trim();
    sinr = sinr?.trim();

    // Format band number
    const formattedBandNumber = bandNumber
      ?.replace("LTE BAND ", "B")
      .replace("NR5G BAND ", "N");

    // Create row HTML
    row.innerHTML = `
      <td>${formattedBandNumber || "N/A"}</td>
      <td>${earfcn || "N/A"}</td>
      <td>${bandwidth || "N/A"}</td>
      <td>${pci || "N/A"}</td>
      <td class="is-hidden-mobile">
        ${rsrp ? createSignalTag(rsrp, "RSRP") : "N/A"}
      </td>
      <td class="is-hidden-mobile">
        ${rsrq ? createSignalTag(rsrq, "RSRQ") : "N/A"}
      </td>
      <td class="is-hidden-mobile">
        ${sinr ? createSignalTag(sinr, "SINR") : "N/A"}
      </td>
    `;
  } catch (error) {
    console.error("Error parsing band data:", error);
    row.innerHTML = '<td colspan="7">Error parsing band data</td>';
  }

  return row;
}

function createSignalTag(value, type) {
  const numValue = parseInt(value);
  let quality, colorClass;

  switch (type) {
    case "RSRP":
      if (numValue >= -60) {
        quality = "Excellent";
        colorClass = "is-success";
      } else if (numValue >= -80) {
        quality = "Good";
        colorClass = "is-info";
      } else if (numValue >= -100) {
        quality = "Fair";
        colorClass = "is-warning";
      } else {
        quality = "Poor";
        colorClass = "is-danger";
      }
      break;
    case "RSRQ":
      if (numValue >= -10) {
        quality = "Excellent";
        colorClass = "is-success";
      } else if (numValue >= -15) {
        quality = "Good";
        colorClass = "is-info";
      } else if (numValue >= -20) {
        quality = "Fair";
        colorClass = "is-warning";
      } else {
        quality = "Poor";
        colorClass = "is-danger";
      }
      break;
    case "SINR":
      if (numValue >= 25) {
        quality = "Excellent";
        colorClass = "is-success";
      } else if (numValue >= 13) {
        quality = "Good";
        colorClass = "is-info";
      } else if (numValue >= 6) {
        quality = "Fair";
        colorClass = "is-warning";
      } else {
        quality = "Poor";
        colorClass = "is-danger";
      }
      break;
  }

  return `
    <div class="tags has-addons">
      <span class="tag is-size-7">${value}</span>
      <span class="tag ${colorClass} is-size-7 has-text-white">${quality}</span>
    </div>
  `;
}

function processBandsTable(jsonData) {
  const servingCellJSON = jsonData[10].response.split("\n");
  const bands = jsonData[13].response.split("\n");
  const networkType = determineNetworkType(jsonData[10].response);
  const pccBand = bands.find((band) => band.includes("PCC"));
  const sccBands = bands.filter((band) => band.includes("SCC"));

  const tableBody = document.querySelector("#bandTable tbody");

  if (!tableBody) {
    console.error("Table body not found");
    return;
  }

  // Clear existing rows
  tableBody.innerHTML = "";

  // Process PCC band
  if (pccBand) {
    const pccRow = createBandTableRow(pccBand, networkType, servingCellJSON);
    tableBody.appendChild(pccRow);
  }

  // Process SCC bands
  sccBands.forEach((sccBand) => {
    const sccRow = createBandTableRow(sccBand, networkType, servingCellJSON);
    tableBody.appendChild(sccRow);
  });
}

function processCellInfo(jsonData) {
  const servingCell = jsonData[10].response.split("\n");
  const networkType = determineNetworkType(jsonData[10].response);
  if (networkType === "NR5G-SA") {
    const cellID = servingCell.find((line) => line.includes("NR5G-SA"));
    const cellIDValues = cellID.split(":")[1].split(",");
    const pcid = cellIDValues[6].trim();
    setText("cellID", pcid);

    const lac = cellIDValues[8].trim();
    setText("lac", lac);

    const mcc = cellIDValues[4].trim();
    setText("mcc", mcc);

    const mnc = cellIDValues[5].trim();
    setText("mnc", mnc);

    // Get all EARFCNs and PCIDs
    const caInfoLines = jsonData[13].response.split("\n");
    // Get the PCC line
    const pccLine = caInfoLines.find((line) => line.includes("PCC"));
    const pccEARFCN = pccLine.split(":")[1].split(",")[1].trim();
    const pccPCID = pccLine.split(":")[1].split(",")[4].trim();

    const sccLines = caInfoLines.filter((line) => line.includes("SCC"));

    const sccEARFCNs = sccLines.map((line) => {
      return line.split(":")[1].split(",")[1].trim();
    });

    const sccPCIDs = sccLines.map((line) => {
      return line.split(":")[1].split(",")[5].trim();
    });

    // Append all the EARFCN seperated by a comma
    if (sccEARFCNs.length === 0) {
      setText("allEARFCN", `${pccEARFCN}`);
    } else {
      setText("allEARFCN", `${pccEARFCN}, ${sccEARFCNs.join(", ")}`);
    }

    // Append all the PCID seperated by a comma
    if (sccPCIDs.length === 0) {
      setText("allPCID", `${pccPCID}`);
    } else {
      setText("allPCID", `${pccPCID}, ${sccPCIDs.join(", ")}`);
    }
  } else if (networkType === "NR5G-NSA") {
    const cellID = servingCell.find((line) => line.includes("LTE"));
    const cellIDValues = cellID.split(":")[1].split(",");
    const pcid = cellIDValues[4].trim();
    setText("cellID", pcid);

    const lac = cellIDValues[10].trim();
    setText("lac", lac);

    const mcc = cellIDValues[2].trim();
    setText("mcc", mcc);

    const mnc = cellIDValues[3].trim();
    setText("mnc", mnc);

    // Get all EARFCNs and PCIDs
    const caInfoLines = jsonData[13].response.split("\n");
    // Get the PCC line
    const pccLine = caInfoLines.find((line) => line.includes("PCC"));
    const pccEARFCN = pccLine.split(":")[1].split(",")[1].trim();
    const pccPCID = pccLine.split(":")[1].split(",")[5].trim();
    const sccLines = caInfoLines.filter((line) => line.includes("SCC"));

    const sccEARFCNs = sccLines.map((line) => {
      return line.split(":")[1].split(",")[1].trim();
    });

    const sccPCIDs = sccLines.map((line) => {
      if (line.includes("LTE")) {
        return line.split(":")[1].split(",")[5].trim();
      } else {
        return line.split(":")[1].split(",")[4].trim();
      }
    });

    // Append all the EARFCN seperated by a comma
    if (sccEARFCNs.length === 0) {
      setText("allEARFCN", `${pccEARFCN}`);
    } else {
      setText("allEARFCN", `${pccEARFCN}, ${sccEARFCNs.join(", ")}`);
    }

    // Append all the PCID seperated by a comma
    if (sccPCIDs.length === 0) {
      setText("allPCID", `${pccPCID}`);
    } else {
      setText("allPCID", `${pccPCID}, ${sccPCIDs.join(", ")}`);
    }
  } else {
    const cellID = servingCell.find((line) => line.includes("LTE"));
    const cellIDValues = cellID.split(":")[1].split(",");
    const pcid = cellIDValues[6].trim();
    setText("cellID", pcid);

    const lac = cellIDValues[12].trim();
    setText("lac", lac);

    const mcc = cellIDValues[4].trim();
    setText("mcc", mcc);

    const mnc = cellIDValues[5].trim();
    setText("mnc", mnc);

    // Get all EARFCNs and PCIDs
    const caInfoLines = jsonData[13].response.split("\n");
    // Get the PCC line
    const pccLine = caInfoLines.find((line) => line.includes("PCC"));
    const pccEARFCN = pccLine.split(":")[1].split(",")[1].trim();
    const pccPCID = pccLine.split(":")[1].split(",")[5].trim();

    const sccLines = caInfoLines.filter((line) => line.includes("SCC"));

    const sccEARFCNs = sccLines.map((line) => {
      return line.split(":")[1].split(",")[1].trim();
    });

    const sccPCIDs = sccLines.map((line) => {
      return line.split(":")[1].split(",")[5].trim();
    });

    // Append all the EARFCN seperated by a comma
    if (sccEARFCNs.length === 0) {
      setText("allEARFCN", `${pccEARFCN}`);
    } else {
      setText("allEARFCN", `${pccEARFCN}, ${sccEARFCNs.join(", ")}`);
    }

    // Append all the PCID seperated by a comma
    if (sccPCIDs.length === 0) {
      setText("allPCID", `${pccPCID}`);
    } else {
      setText("allPCID", `${pccPCID}, ${sccPCIDs.join(", ")}`);
    }
  }
}

function processWANIPData(jsonData) {
  const wanIP = jsonData[15].response.split("\n");
  const wanIPv4Line = wanIP
    .find((line) => line.includes("IPV4"))
    .split(":")[1]
    .split(",")[4]
    .replace(/"/g, "")
    .trim();
  setText("wanIPv4", wanIPv4Line);

  const wanIPv6Line = wanIP
    .find((line) => line.includes("IPV6"))
    .split(",")[4]
    .replace(/"/g, "")
    .trim();
  if (wanIPv6Line === "0:0:0:0:0:0:0:0") {
    setText("wanIPv6", "Not Available");
  } else {
    setText("wanIPv6", wanIPv6Line);
  }
}

async function fetchTrafficStats() {
  try {
    const response = await fetch("/cgi-bin/traffic_stats.sh", {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
      },
    });

    const rawData = await response.text();

    if (!rawData || rawData.trim() === "") {
      throw new Error("Empty or malformed response");
    }

    const jsonData = JSON.parse(rawData);

    console.log("Traffic stats fetched successfully");

    // Parse rx (download) and tx (upload) values
    const download = jsonData.download;
    const upload = jsonData.upload;

    // Convert to human-readable format
    const downloadFormatted = formatBytes(download);
    const uploadFormatted = formatBytes(upload);

    // Update the DOM
    setText("download", downloadFormatted);
    setText("upload", uploadFormatted);

  } catch (error) {
    console.error("There was a problem with the fetch operation:", error);
  }
}

async function fetchConnectionStatus() {
  // Get the container element
  const container = document.getElementById("dataConnState");
  if (!container) {
    console.error("Connection status container not found");
    return;
  }

  try {
    // Clear any existing status elements
    container.innerHTML = "";

    // Create and append the "Checking..." element
    const checkingElement = document.createElement("span");
    checkingElement.classList.add("tag", "is-warning", "has-text-white");
    checkingElement.textContent = "Checking...";
    container.appendChild(checkingElement);

    // Fetch the data
    const response = await fetch("/cgi-bin/check_net.sh", {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
      },
    });

    // Get the raw response
    const rawData = await response.text();

    // Check for empty or malformed response
    if (!rawData || rawData.trim() === "") {
      throw new Error("Empty or malformed response");
    }

    // Parse the JSON
    const jsonData = JSON.parse(rawData);

    // Clear the container again (removes "Checking..." element)
    container.innerHTML = "";

    // Create the status element
    const statusElement = document.createElement("span");
    statusElement.classList.add("tag", "has-text-white");

    if (jsonData.connection === "ACTIVE") {
      statusElement.classList.add("is-success");
      statusElement.textContent = "Connected";
    } else {
      statusElement.classList.add("is-danger");
      statusElement.textContent = "Disconnected";
    }

    // Append the status element
    container.appendChild(statusElement);
  } catch (error) {
    console.error("There was a problem with the fetch operation:", error);

    // Clear the container in case of error
    container.innerHTML = "";

    // Create and append an error element
    const errorElement = document.createElement("span");
    errorElement.classList.add("tag", "is-danger", "has-text-white");
    errorElement.textContent = "Error";
    container.appendChild(errorElement);
  }
}

// Event listener setup
function setupEventListeners() {
  // Bind refresh button
  const refreshButton = document.getElementById("handleRefreshClickButton");
  if (refreshButton) {
    refreshButton.addEventListener("click", handleRefreshClick);
  } else {
    console.warn("Refresh button not found in the DOM");
  }

  // Setup dropdown functionality
  const dropdownTrigger = document.querySelector(".dropdown-trigger");
  if (dropdownTrigger) {
    dropdownTrigger.addEventListener("click", (e) => {
      e.preventDefault();
      dropdownTrigger.parentElement.classList.toggle("is-active");
    });
  }

  // Close dropdown when clicking outside
  document.addEventListener("click", (e) => {
    const dropdowns = document.querySelectorAll(".dropdown");
    dropdowns.forEach((dropdown) => {
      if (!dropdown.contains(e.target)) {
        dropdown.classList.remove("is-active");
      }
    });
  });
}

// Main initialization
document.addEventListener("DOMContentLoaded", () => {
  // Initial data fetch
  fetchATCommandData();
  fetchConnectionStatus();
  fetchTrafficStats();

  // Setup controls and event listeners
  setupRefreshControls();
  setupEventListeners();
});
