const freqNumbersContainer = document.getElementById(
    "freqNumbersContainer"
  );

function generateFreqNumberInputs(num) {
    let html = "";
    const maxFields = Math.min(num, 10); // Limit to a maximum of 10 fields
    for (let i = 1; i <= maxFields; i++) {
      html += `
    <div class="input-group mb-3" x-show="cellNum >= ${i} && networkModeCell == 'LTE'">
      <input
        type="text"
        aria-label="EARFCN"
        placeholder="EARFCN"
        class="form-control"
        x-model="earfcn${i}"
      />
      <input
        type="text"
        aria-label="PCI"
        placeholder="PCI"
        class="form-control"
        x-model="pci${i}"
      />
    </div>
  `;
    }
    return html;
  }

  document.addEventListener("DOMContentLoaded", function () {
    const cellNumInput = document.querySelector("[aria-label='NumCells']");
    cellNumInput.addEventListener("input", function () {
      const cellNum = parseInt(this.value);
      freqNumbersContainer.innerHTML = generateFreqNumberInputs(cellNum);
    });
  });