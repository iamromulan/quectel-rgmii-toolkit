document.addEventListener("DOMContentLoaded", function () {
  // Helper function to show notifications
  function showNotification(message, isError = false) {
    const existingNotification = document.querySelector(".notification");
    if (existingNotification) {
      existingNotification.remove();
    }

    const notification = document.createElement("div");
    notification.className = `notification ${
      isError ? "is-danger" : "is-success"
    } is-light`;
    notification.innerHTML = `
            <button class="delete"></button>
            ${message}
        `;

    document
      .querySelector(".column-margin")
      .insertAdjacentElement("beforebegin", notification);

    setTimeout(() => notification.remove(), 3000);
    notification
      .querySelector(".delete")
      .addEventListener("click", () => notification.remove());
  }

  // Function to validate numeric inputs
  function validateNumeric(value, fieldName) {
    if (value && !/^\d+$/.test(value)) {
      showNotification(`${fieldName} must be a numeric value`, true);
      return false;
    }
    return true;
  }

  // Function to validate LTE inputs
  function validateLTEInputs() {
    const earfcn1 = document.getElementById("earfcn1").value;
    const pci1 = document.getElementById("pci1").value;

    if (!earfcn1 && !pci1) {
      return true; // Skip validation if both are empty
    }

    if (!validateNumeric(earfcn1, "EARFCN 1")) return false;
    if (!validateNumeric(pci1, "PCI 1")) return false;

    if ((earfcn1 && !pci1) || (!earfcn1 && pci1)) {
      showNotification(
        "Both EARFCN and PCI must be provided for each pair",
        true
      );
      return false;
    }

    return true;
  }

  // Function to validate 5G-SA inputs
  function validate5GInputs() {
    const nrArfcn = document.getElementById("nr-arfcn").value;
    const nrPci = document.getElementById("nr-pci").value;
    const scs = document.getElementById("scs").value;
    const nrBand = document.getElementById("nr-band").value;

    if (!nrArfcn && !nrPci && scs === "Select SCS" && !nrBand) {
      return true; // Skip validation if all empty
    }

    if (!validateNumeric(nrArfcn, "NR ARFCN")) return false;
    if (!validateNumeric(nrPci, "NR PCI")) return false;
    if (!validateNumeric(nrBand, "NR Band")) return false;
    if (scs === "Select SCS") {
      showNotification("Please select an SCS value", true);
      return false;
    }

    return true;
  }

  // Function to handle LTE cell locking
  document.getElementById("saveLTE").addEventListener("click", function (e) {
    e.preventDefault();

    if (!validateLTEInputs()) {
      return;
    }

    const formData = {
      earfcn1: document.getElementById("earfcn1").value,
      pci1: document.getElementById("pci1").value,
      earfcn2: document.getElementById("earfcn2").value,
      pci2: document.getElementById("pci2").value,
      earfcn3: document.getElementById("earfcn3").value,
      pci3: document.getElementById("pci3").value,
    };

    // Disable all inputs once the form is submitted
    document.querySelectorAll("input").forEach((input) => {
      input.disabled = true;
    });

    // Change Lock LTE Cells button text to spinner icon with "Saving... Please wait"
    document.getElementById("saveLTE").innerHTML = `
            <span class="icon is-small">
                <i class="fas fa-spinner fa-pulse"></i>
            </span>
            <span class="ml-2">Saving... Please wait</span>
        `;
    document.getElementById("saveLTE").disabled = true;

    fetch("/cgi-bin/cell-locking/cell-lock.sh", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: Object.keys(formData)
        .map((key) => {
          return (
            encodeURIComponent(key) + "=" + encodeURIComponent(formData[key])
          );
        })
        .join("&"),
    })
      .then((response) => response.json())
      .then((data) => {
        if (data.status === "success") {
          // Change Lock LTE Cells button text back to normal
          document.getElementById("saveLTE").innerHTML = "Lock LTE Cells";
          document.getElementById("saveLTE").disabled = false;

          // Enable all inputs after successful submission
          document.querySelectorAll("input").forEach((input) => {
            input.disabled = false;
          });
          showNotification("LTE cell lock configured successfully");
        } else {
          // Change Lock LTE Cells button text back to normal
          document.getElementById("saveLTE").innerHTML = "Lock LTE Cells";
          document.getElementById("saveLTE").disabled = false;

          document.querySelectorAll("input").forEach((input) => {
            input.disabled = false;
          });
          showNotification(
            // Enable all inputs after failed submission
            data.message || "Error configuring LTE cell lock",
            true
          );
        }
      })
      .catch((error) => {
        showNotification(
          "Error configuring LTE cell lock: " + error.message,
          true
        );
      });
  });

  // Function to handle 5G-SA cell locking
  document.getElementById("saveSA").addEventListener("click", function (e) {
    e.preventDefault();

    if (!validate5GInputs()) {
      return;
    }

    const scsValue = document.getElementById("scs").value;
    const scsNumeric = scsValue === "Select SCS" ? "" : scsValue.split(" ")[0]; // Extract numeric value

    const formData = {
      nrarfcn: document.getElementById("nr-arfcn").value,
      nrpci: document.getElementById("nr-pci").value,
      scs: scsNumeric,
      band: document.getElementById("nr-band").value,
    };

    // Disable all inputs once the form is submitted
    document.querySelectorAll("input").forEach((input) => {
      input.disabled = true;
    });

    // Change Lock 5G-SA Cells button text to spinner icon with "Saving... Please wait"
    document.getElementById("saveSA").innerHTML = `
            <span class="icon is-small">
                <i class="fas fa-spinner fa-pulse"></i>
            </span>
            <span class="ml-2">Saving... Please wait</span>
        `;

    document.getElementById("saveSA").disabled = true;

    fetch("/cgi-bin/cell-locking/cell-lock.sh", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: Object.keys(formData)
        .map((key) => {
          return (
            encodeURIComponent(key) + "=" + encodeURIComponent(formData[key])
          );
        })
        .join("&"),
    })
      .then((response) => response.json())
      .then((data) => {
        if (data.status === "success") {
          // Change Lock 5G-SA Cells button text back to normal
          document.getElementById("saveSA").innerHTML = "Lock 5G-SA Cells";
          document.getElementById("saveSA").disabled = false;

          showNotification("5G-SA cell lock configured successfully");
        } else {
          // Change Lock 5G-SA Cells button text back to normal
          document.getElementById("saveSA").innerHTML = "Lock 5G-SA Cells";
          document.getElementById("saveSA").disabled = false;

          showNotification(
            data.message || "Error configuring 5G-SA cell lock",
            true
          );
        }
      })
      .catch((error) => {
        showNotification(
          "Error configuring 5G-SA cell lock: " + error.message,
          true
        );
      });
  });

  // Function to handle LTE reset
  document.getElementById("resetLTE").addEventListener("click", function (e) {
    e.preventDefault();

    // Disable the button once clicked
    document.getElementById("resetLTE").disabled = true;

    // Change button text to spinner icon with "Resetting... Please wait"
    document.getElementById("resetLTE").innerHTML = `
            <span class="icon is-small">
                <i class="fas fa-spinner fa-pulse"></i>
            </span>
            <span class="ml-2">Resetting... Please wait</span>
        `;

    fetch("/cgi-bin/cell-locking/cell-lock.sh", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "reset_lte=1",
    })
      .then((response) => response.json())
      .then((data) => {
        if (data.status === "success") {
          // Clear all LTE inputs
          document.getElementById("earfcn1").value = "";
          document.getElementById("pci1").value = "";
          document.getElementById("earfcn2").value = "";
          document.getElementById("pci2").value = "";
          document.getElementById("earfcn3").value = "";
          document.getElementById("pci3").value = "";

          // Change Reset LTE Cells button text back to normal
          document.getElementById("resetLTE").innerHTML = "Reset LTE Cells";
          document.getElementById("resetLTE").disabled = false;

          showNotification("LTE cell lock reset successfully");
        } else {
          // Change Reset LTE Cells button text back to normal
          document.getElementById("resetLTE").innerHTML = "Reset LTE Cells";
          document.getElementById("resetLTE").disabled = false;

          showNotification(
            data.message || "Error resetting LTE cell lock",
            true
          );
        }
      })
      .catch((error) => {
        showNotification(
          "Error resetting LTE cell lock: " + error.message,
          true
        );
      });
  });

  // Function to handle 5G-SA reset
  document.getElementById("resetSA").addEventListener("click", function (e) {
    e.preventDefault();

    // Change button text to spinner icon with "Resetting... Please wait"
    document.getElementById("resetSA").innerHTML = `
            <span class="icon is-small">
                <i class="fas fa-spinner fa-pulse"></i>
            </span>
            <span class="ml-2">Resetting... Please wait</span>
        `;
    document.getElementById("resetSA").disabled = true;

    fetch("/cgi-bin/cell-locking/cell-lock.sh", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "reset_5g=1",
    })
      .then((response) => response.json())
      .then((data) => {
        if (data.status === "success") {
          // Clear all 5G-SA inputs
          document.getElementById("nr-arfcn").value = "";
          document.getElementById("nr-pci").value = "";
          document.getElementById("scs").selectedIndex = 0;
          document.getElementById("nr-band").value = "";

          // Change Reset 5G-SA Cells button text back to normal
          document.getElementById("resetSA").innerHTML = "Reset 5G-SA Cells";
          document.getElementById("resetSA").disabled = false;

          showNotification("5G-SA cell lock reset successfully");
        } else {
          // Change Reset 5G-SA Cells button text back to normal
          document.getElementById("resetSA").innerHTML = "Reset 5G-SA Cells";
          document.getElementById("resetSA").disabled = false;

          showNotification(
            data.message || "Error resetting 5G-SA cell lock",
            true
          );
        }
      })
      .catch((error) => {
        showNotification(
          "Error resetting 5G-SA cell lock: " + error.message,
          true
        );
      });
  });

  // Function to fetch and display existing configurations
  function fetchConfigurations() {
    fetch("/cgi-bin/cell-locking/fetch-cell-lock.sh")
      .then((response) => response.json())
      .then((data) => {
        console.log("Fetched data:", data); // Debug log

        if (data.status === "success" && data.configurations) {
          // Fill LTE configurations
          const lte = data.configurations.lte;
          if (lte) {
            if (lte.earfcn1)
              document.getElementById("earfcn1").value = lte.earfcn1;
            if (lte.pci1) document.getElementById("pci1").value = lte.pci1;
            if (lte.earfcn2)
              document.getElementById("earfcn2").value = lte.earfcn2;
            if (lte.pci2) document.getElementById("pci2").value = lte.pci2;
            if (lte.earfcn3)
              document.getElementById("earfcn3").value = lte.earfcn3;
            if (lte.pci3) document.getElementById("pci3").value = lte.pci3;
          }

          // Fill 5G-SA configurations
          const sa = data.configurations.sa;
          if (sa) {
            if (sa.nrarfcn)
              document.getElementById("nr-arfcn").value = sa.nrarfcn;
            if (sa.nrpci) document.getElementById("nr-pci").value = sa.nrpci;
            if (sa.band) document.getElementById("nr-band").value = sa.band;

            // Handle SCS dropdown
            if (sa.scs) {
              const scsSelect = document.getElementById("scs");
              for (let i = 0; i < scsSelect.options.length; i++) {
                if (scsSelect.options[i].value === sa.scs) {
                  scsSelect.selectedIndex = i;
                  break;
                }
              }
            }
          }
        } else {
          console.log("No configurations found or error in response");
        }
      })
      .catch((error) => {
        console.error("Error fetching configurations:", error);
        showNotification(
          "Error fetching configurations: " + error.message,
          true
        );
      });
  }

  // Call fetchConfigurations when the page loads
  fetchConfigurations();

  // Optional: Add a refresh button if needed
  if (document.getElementById("refreshConfig")) {
    document
      .getElementById("refreshConfig")
      .addEventListener("click", function (e) {
        e.preventDefault();
        fetchConfigurations();
      });
  }
});
