function populateCheckboxes(lte_band, nsa_nr5g_band, nr5g_band, locked_lte_bands, locked_nsa_bands, locked_sa_bands, cellLock) {
  var checkboxesForm = document.getElementById("checkboxForm");
  var selectedMode = document.getElementById("networkModeBand").value;
  var bands;
  var prefix;

  // Determine bands and prefix based on selected network mode
  if (selectedMode === "LTE") {
    bands = lte_band;
    prefix = "B";
  } else if (selectedMode === "NSA") {
    bands = nsa_nr5g_band;
    prefix = "N";
  } else if (selectedMode === "SA") {
    bands = nr5g_band;
    prefix = "N";
  }

  checkboxesForm.innerHTML = ""; // Clear existing checkboxes

  // Store the locked bands in arrays
  var locked_lte_bands_array = locked_lte_bands.split(":");
  var locked_nsa_bands_array = locked_nsa_bands.split(":");
  var locked_sa_bands_array = locked_sa_bands.split(":");

  var isBandLocked = function(band) {
    if (selectedMode === "LTE" && locked_lte_bands_array.includes(band)) {
      return true;
    }
    if (selectedMode === "NSA" && locked_nsa_bands_array.includes(band)) {
      return true;
    }
    if (selectedMode === "SA" && locked_sa_bands_array.includes(band)) {
      return true;
    }
    return false;
  };

  var fragment = document.createDocumentFragment();

  if (bands !== null && bands !== "0") {
    var bandsArray = bands.split(":");
    var currentRow;

    bandsArray.forEach(function(band, index) {
      if (index % 5 === 0) {
        currentRow = document.createElement("div");
        currentRow.className = "row mb-2 mx-auto"; // Add margin bottom for spacing
        fragment.appendChild(currentRow);
      }

      var checkboxDiv = document.createElement("div");
      checkboxDiv.className = "form-check form-check-reverse col-2"; // Each checkbox takes a column
      var checkboxInput = document.createElement("input");
      checkboxInput.className = "form-check-input";
      checkboxInput.type = "checkbox";
      checkboxInput.id = "inlineCheckbox" + band;
      checkboxInput.value = band;
      checkboxInput.autocomplete = "off";
      checkboxInput.checked = isBandLocked(band);

      var checkboxLabel = document.createElement("label");
      checkboxLabel.className = "form-check-label";
      checkboxLabel.htmlFor = "inlineCheckbox" + band;
      checkboxLabel.innerText = prefix + band;

      checkboxDiv.appendChild(checkboxInput);
      checkboxDiv.appendChild(checkboxLabel);
      currentRow.appendChild(checkboxDiv);
    });
  } else {
    // Create a text saying that no bands are available
    var noBandsText = document.createElement("p");
    noBandsText.className = "text-center";
    noBandsText.innerText = "No supported bands available";
    fragment.appendChild(noBandsText);
  }

  checkboxesForm.appendChild(fragment);
  addCheckboxListeners(cellLock);
}