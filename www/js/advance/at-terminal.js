document.addEventListener("DOMContentLoaded", function () {
    const form = document.getElementById("commandForm");
    const output = document.getElementById("output");
    const commandInput = document.getElementById("command");
    const sendButton = document.getElementById("sendButton");
    const commandHistory = document.getElementById("commandHistory");
    const noHistory = document.getElementById("noHistory");
    const clearHistoryButton = document.getElementById("clearHistory");
    const cooldownTimer = document.getElementById("cooldownTimer");

    const COOLDOWN_DURATION = 1000; // 1 second cooldown
    let isLoading = false;
    let cooldownActive = false;

    function setLoading(loading) {
      isLoading = loading;
      sendButton.classList.toggle("is-loading", loading);
      form.classList.toggle("loading", loading);
    }

    function setCooldown() {
      cooldownActive = true;
      sendButton.classList.add("cooldown");
      let timeLeft = COOLDOWN_DURATION;

      function updateTimer() {
        timeLeft -= 100;
        if (timeLeft <= 0) {
          cooldownActive = false;
          sendButton.classList.remove("cooldown");
          cooldownTimer.textContent = "";
          return;
        }
        cooldownTimer.textContent = `${(timeLeft / 1000).toFixed(1)}s`;
        setTimeout(updateTimer, 100);
      }

      updateTimer();
    }

    function updateHistoryVisibility() {
      const hasHistoryItems =
        commandHistory.querySelectorAll(".history-item").length > 0;
      noHistory.style.display = hasHistoryItems ? "none" : "block";
      clearHistoryButton.style.display = hasHistoryItems ? "block" : "none";
    }

    function addToHistory(command, response) {
      const historyItem = document.createElement("div");
      historyItem.className = "box mb-2 history-item";
      historyItem.innerHTML = `
        <button class="delete delete-history" aria-label="delete"></button>
        <strong class="command-text">${command}</strong>
        <pre style="margin-top: 0.5rem; font-size: 0.85em; white-space: pre-wrap;">${response}</pre>
      `;

      historyItem
        .querySelector(".command-text")
        .addEventListener("click", () => {
          commandInput.value = command;
          commandInput.focus();
        });

      historyItem
        .querySelector(".delete-history")
        .addEventListener("click", (e) => {
          e.stopPropagation();
          historyItem.classList.add("fade-out");
          setTimeout(() => {
            historyItem.remove();
            updateHistoryVisibility();
          }, 300);
        });

      commandHistory.insertBefore(historyItem, commandHistory.firstChild);
      updateHistoryVisibility();
    }

    clearHistoryButton.addEventListener("click", () => {
      const historyItems = commandHistory.querySelectorAll(".history-item");
      historyItems.forEach((item) => {
        item.classList.add("fade-out");
      });
      setTimeout(() => {
        commandHistory.innerHTML = "";
        commandHistory.appendChild(noHistory);
        updateHistoryVisibility();
      }, 300);
    });

    async function sendCommand(command) {
      try {
        setLoading(true);
        const response = await fetch("/cgi-bin/atinout_handler.sh", {
          method: "POST",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: `command=${encodeURIComponent(command)}`,
        });

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const data = await response.json();
        output.value = data.output || "No response received";
        addToHistory(command, data.output || "No response received");
        setCooldown();
      } catch (error) {
        const errorMessage = `Error: ${error.message}\n\nTroubleshooting steps:\n1. Check if the device is connected\n2. Verify AT port settings\n3. Ensure atinout utility is installed`;
        output.value = errorMessage;
        addToHistory(command, errorMessage);
      } finally {
        setLoading(false);
      }
    }

    form.addEventListener("submit", async function (e) {
      e.preventDefault();
      if (isLoading || cooldownActive) return;

      const command = commandInput.value.trim();
      if (!command) {
        output.value = "Please enter a command";
        return;
      }

      await sendCommand(command);
      commandInput.value = "";
    });

    // Initialize visibility
    updateHistoryVisibility();
  });