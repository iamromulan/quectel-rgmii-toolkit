function parseCurrentSettings(rawdata) {
    const data = rawdata;

    const lines = data.split("\n");
    console.log(lines);

    // Remove QUIMSLOT and only take 1 or 2
    this.sim = lines[1].split(":")[1].trim();
    this.apn = lines[3].split(",")[2].replace(/\"/g, "");
    this.cellLock4GStatus = lines[5].split(",")[1].replace(/\"/g, "");
    this.prefNetwork = lines[4].split(",")[1]
    this.nrModeControlStatus = lines[5].split(",")[1].replace(/\"/g, "");


    let bands = [];



    this.bands = bands;
    

    if (this.cellLock4GStatus == 1 && this.cellLock5GStatus == 1) {
      this.cellLockStatus = "已锁定4G和5G";
    } else if (this.cellLock4GStatus == 1) {
      this.cellLockStatus = "已锁定4G";
    }
    else if (this.cellLock5GStatus == 1) {
      this.cellLockStatus = "已锁定5G";
    }
    else {
      this.cellLockStatus = "未锁定";
    }

    if (this.nrModeControlStatus == 0) {
      this.nrModeControlStatus = "未禁用";
    }
    else if (this.nrModeControlStatus == 1) {
      this.nrModeControlStatus = "禁用SA";
    }
    else {
      this.nrModeControlStatus = "禁用NSA";
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

