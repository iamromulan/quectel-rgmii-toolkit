function parseCurrentSettings(rawdata) {
  const data = rawdata;

  const lines = data.split("\n");
  console.log(lines);

  // Remove QUIMSLOT and only take 1 or 2
  this.sim = lines
    .find(
      (line) => line.includes("QUIMSLOT: 1") || line.includes("QUIMSLOT: 2")
    )
    .split(":")[1]
    // remove spaces
    .replace(/\s/g, "");
  // .replace(/\"/g, "");

  try {
    this.apn = lines
      .find((line) => line.includes("+CGCONTRDP: 1"))
      .split(",")[2]
      .replace(/\"/g, "");
  } catch (error) {
    this.apn = "Failed fetching APN";
  }

  this.cellLock4GStatus = lines
    .find((line) => line.includes('+QNWLOCK: "common/4g"'))
    .split(",")[1]
    .replace(/\"/g, "");

  this.cellLock5GStatus = lines
    .find((line) => line.includes('+QNWLOCK: "common/5g"'))
    .split(",")[1]
    .replace(/\"/g, "");

  this.prefNetwork = lines
    .find((line) => line.includes('+QNWPREFCFG: "mode_pref"'))
    .split(",")[1]
    .replace(/\"/g, "");

  this.nrModeControlStatus = lines
    .find((line) => line.includes('+QNWPREFCFG: "nr5g_disable_mode"'))
    .split(",")[1]
    .replace(/\"/g, "");

  this.apnIP = lines
    .find((line) => line.includes("+CGDCONT: 1"))
    .split(",")[1]
    .replace(/\"/g, "");

  try {
    const PCCbands = lines
      .find((line) => line.includes('+QCAINFO: "PCC"'))
      .split(",")[3]
      .replace(/\"/g, "");
    
    // Loop over all QCAINFO: "SCC" lines and get the bands
    try {
      const SCCbands = lines
        .filter((line) => line.includes('+QCAINFO: "SCC"'))
        .map((line) => line.split(",")[3].replace(/\"/g, ""))
        .join(", ");
      this.bands = `${PCCbands}, ${SCCbands}`;
    } catch (error) {
      this.bands = PCCbands;
    }
    
  } catch (error) {
    this.bands = "Failed fetching bands";
  }

  if (this.cellLock4GStatus == 1 && this.cellLock5GStatus == 1) {
    this.cellLockStatus = "Locked to 4G and 5G";
  } else if (this.cellLock4GStatus == 1) {
    this.cellLockStatus = "Locked to 4G";
  } else if (this.cellLock5GStatus == 1) {
    this.cellLockStatus = "Locked to 5G";
  } else {
    this.cellLockStatus = "Not Locked";
  }

  if (this.nrModeControlStatus == 0) {
    this.nrModeControlStatus = "Not Disabled";
  } else if (this.nrModeControlStatus == 1) {
    this.nrModeControlStatus = "SA Disabled";
  } else {
    this.nrModeControlStatus = "NSA Disabled";
  }

  return {
    sim: sim,
    apn: apn,
    apnIP: apnIP,
    cellLockStatus: cellLockStatus,
    prefNetwork: prefNetwork,
    nrModeControl: nrModeControlStatus,
    bands: bands,
  };
}
