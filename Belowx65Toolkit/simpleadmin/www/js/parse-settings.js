function parseCurrentSettings(rawdata) {
    const data = rawdata;

    const lines = data.split("\n");
    console.log(lines);

    // Remove QUIMSLOT and only take 1 or 2
    this.sim = lines[1].split(":")[1].trim();
    this.apn = lines[3].split(",")[2].replace(/\"/g, "");
    this.cellLock4GStatus = lines[5].split(",")[1].replace(/\"/g, "");
    this.cellLock5GStatus = lines[7].split(",")[1].replace(/\"/g, "");
    this.prefNetwork = lines[9].split(",")[1].replace(/\"/g, "");
    this.nrModeControlStatus = lines[11].split(",")[1].replace(/\"/g, "");


    let bands = [];

    // Append the values if there is separated by comma with a space.
    // i.e. LTE BAND 3, LTE BAND 1
    for (let i = 13; i < 17; i++) {
      if (lines[i].split(",").length > 1) {
        bands.push(lines[i].split(",")[3].replace(/\"/g, " "));
      }
    }

    this.bands = bands;
    

    if (this.cellLock4GStatus == 1 && this.cellLock5GStatus == 1) {
      this.cellLockStatus = "Locked to 4G and 5G";
    } else if (this.cellLock4GStatus == 1) {
      this.cellLockStatus = "Locked to 4G";
    }
    else if (this.cellLock5GStatus == 1) {
      this.cellLockStatus = "Locked to 5G";
    }
    else {
      this.cellLockStatus = "Not Locked";
    }

    if (this.nrModeControlStatus == 0) {
      this.nrModeControlStatus = "Not Disabled";
    }
    else if (this.nrModeControlStatus == 1) {
      this.nrModeControlStatus = "SA Disabled";
    }
    else {
      this.nrModeControlStatus = "NSA Disabled";
    }

    return {
      sim: sim,
      apn: apn,
      cellLockStatus: cellLockStatus,
      prefNetwork: prefNetwork,
      nrModeControl: nrModeControlStatus,
      bands: bands
    };
  }

