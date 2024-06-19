function populateCheckboxes(lte_band, nsa_nr5g_band, nr5g_band, locked_lte_bands, locked_nsa_bands, locked_sa_bands, cellLock) {
  var checkboxesForm = document.getElementById("checkboxForm");
  var selectedMode = document.getElementById("networkModeBand").value;
  var bands;

  // Determine bands based on selected network mode
  if (selectedMode === "LTE") {
    bands = lte_band;
  } else if (selectedMode === "NSA") {
    bands = nsa_nr5g_band;
  } else if (selectedMode === "SA") {
    bands = nr5g_band;
  }

  checkboxesForm.innerHTML = ""; // Clear existing checkboxes

  var bandsArray;
  if (bands !== null) {
    bandsArray = bands.split(":");
    bandsArray.forEach(function(band, index) {
      if (index % 5 === 0) {
        currentRow = document.createElement("div");
        currentRow.className = "row mb-2 mx-auto"; // Add margin bottom for spacing
        checkboxesForm.appendChild(currentRow);
      }

      var checkboxDiv = document.createElement("div");
      checkboxDiv.className = "form-check form-check-reverse col-2"; // Each checkbox takes a column
      var checkboxInput = document.createElement("input");
      checkboxInput.className = "form-check-input";
      checkboxInput.type = "checkbox";
      checkboxInput.id = "inlineCheckbox" + band;
      checkboxInput.value = band;
      checkboxInput.autocomplete = "off";

      // Store the locked bands in an array
      var locked_lte_bands_array = locked_lte_bands.split(":");
      var locked_nsa_bands_array = locked_nsa_bands.split(":");
      var locked_sa_bands_array = locked_sa_bands.split(":");

      // Check if the current band is locked
      var isLocked = false;
      if (selectedMode === "LTE") {
        if (locked_lte_bands_array.includes(band)) {
          isLocked = true;
        }
      } else if (selectedMode === "NSA") {
        if (locked_nsa_bands_array.includes(band)) {
          isLocked = true;
        }
      } else if (selectedMode === "SA") {
        if (locked_sa_bands_array.includes(band)) {
          isLocked = true;
        }
      }

      if (isLocked) {
        checkboxInput.checked = true;
      }

      var checkboxLabel = document.createElement("label");
      checkboxLabel.className = "form-check-label";
      checkboxLabel.htmlFor = "inlineCheckbox" + band;
      if (selectedMode === "LTE") {
        checkboxLabel.innerText = "B" + band;
      } else {
        checkboxLabel.innerText = "N" + band;
      }

      checkboxDiv.appendChild(checkboxInput);
      checkboxDiv.appendChild(checkboxLabel);
      currentRow.appendChild(checkboxDiv);
    });
  } else {
    // Do nothing
  }

  var currentRow;
  addCheckboxListeners(cellLock);
}
